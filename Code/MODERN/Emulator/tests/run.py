#!/usr/bin/env python3
"""Zephyr-80 MAME test runner.

Runs bounded cases against the zephyr80 machine and writes, per case, a
disposable directory with its manifest (command, inputs and hashes, source
revisions, limits), MAME log, serial capture and result record.  A case
passes only on MAME exit 0 with the harness's explicit PASS line; timeouts,
failed expectations, missing inputs, crashes and Lua errors fail it.

Run from Code/MODERN/Emulator:

    python3 tests/run.py --mame ./mame/mamepbitzd --case serial-boot \\
        --konaos-root /path/to/ZephyrOS --zephyr-root /path/to/Zephyr-80
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import select
import shutil
import subprocess
import sys
import termios
import time
import tty

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import card_backends  # noqa: E402
import clocks_irqs  # noqa: E402
import ioc_core  # noqa: E402
import memory_flash  # noqa: E402
import sio1_lanes  # noqa: E402

# Guest inputs: (root, path under it, the existing target that builds it).
INPUTS = {
    "konaos": ("konaos", "build/konaos.bin", "make -C {root} build/konaos.bin"),
    "zsdos": ("zephyr", "Code/HOST/CPM2.2/build/zephyr80.bin",
              "make -C {root}/Code/HOST/CPM2.2 CCP=zshell BDOS=zsdos CONSOLE=v9958 STORAGE_A=rom build/zephyr80.bin"),
    "serial": ("konaos", "build-console-serial-selftest/konaos-console-serial-selftest.bin",
               "make -C {root} console-serial-selftest"),
}

# kind "suite": a probe module's run(); kind "lua": harness.lua with `script`.
# deadline: emulated seconds (Lua); wall: host watchdog seconds.
CASES = {
    "memory-flash": dict(kind="suite", module=memory_flash, inputs=("konaos", "zsdos"),
                         about="Rev 13 decode, flash image device and both guests' reset copies (12 probes)"),
    "clocks-irqs": dict(kind="suite", module=clocks_irqs, inputs=("konaos", "zsdos"),
                        about="CTC selection and clocks, baud, /INT composition, daisy, V9958 latch/NMI (11 probes)"),
    "serial-boot": dict(kind="lua", script="serial.lua", inputs=("serial",), deadline=120, wall=240, pty=True,
                        about="console-serial image to the shell prompt over SIO0/B, then `pwd` and the prompt again"),
    "timer": dict(kind="lua", script="serial.lua", inputs=("serial",), deadline=200, wall=360, pty=True,
                  about="/system/timer.exe: `timer stage` and the 60-second run on the guest's 156.25 Hz CTC tick"),
    "serial-pty": dict(kind="lua", script="serial.lua", inputs=("serial",), deadline=150, wall=180, pty=True,
                       throttle=True, host="session",
                       about="real-time pty: the runner syncs, waits for the prompt and types `pwd` as a host terminal"),
    "sio1-lanes": dict(kind="suite", module=sio1_lanes, inputs=(),
                       about="SIO1 lanes against the probe program: exchanges, Hunt, underrun, READY, drain, overrun, reset, no IRQ, save state (8 probes)"),
    "sio1-konaos": dict(kind="lua", script="sio1_lanes.lua", inputs=("serial",), deadline=60, wall=120, pty=True,
                        about="KonaOS IOC driver over SIO1: LINK_SYNC, the shell's PING, every reply; machine resets idle and mid-reply"),
    "sio1-zsdos": dict(kind="lua", script="sio1_lanes.lua", inputs=("zsdos",), deadline=8, wall=60,
                       about="ZSDOS IOC transport over SIO1: LINK_SYNC bring-up and every boot request answered"),
    "ioc-core": dict(kind="suite", module=ioc_core, inputs=("konaos", "zsdos"),
                     about="IOC protocol core: frames, bulk and media effects (host test); both guests' replies from the empty card socket (3 probes)"),
    "card-image": dict(kind="suite", module=card_backends, inputs=("serial",), probes=card_backends.PROBES["image"],
                       call=lambda mame, inputs, out, sub: card_backends.run("image", mame, inputs, out, sub),
                       about="-card: FAT16/FAT32/MBR images through FatFs (host workload, read-only, full, raw, coherence, media change), the KonaOS shell, option errors (3 probes)"),
    "card-directory": dict(kind="suite", module=card_backends, inputs=("serial",), probes=card_backends.PROBES["directory"],
                           call=lambda mame, inputs, out, sub: card_backends.run("directory", mame, inputs, out, sub),
                           about="-carddir: a host folder as the card (host workload, names, collisions, links, read-only, full, no raw unit), the KonaOS shell, option errors (3 probes)"),
    "cpm-volumes": dict(kind="suite", module=card_backends, inputs=("zsdos",), probes=card_backends.PROBES["volumes"],
                        call=lambda mame, inputs, out, sub: card_backends.run("volumes", mame, inputs, out, sub),
                        about="CP/M volume files on both backends (mount, extents, records, bounds, coherence), ZSDOS C:/D: on an image and a folder (3 probes)"),
    "vdp-text": dict(kind="lua", script="vdp_text.lua", inputs=(), deadline=5, wall=60,
                     about="VDP observations: TEXT1/TEXT2/GRAPHIC1 text from VRAM, rendered pixels, a snapshot, bitmap refusal"),
}

DEFAULT_PROMPT = "/system> "
BANNER = b"KonaOS 0.0\r\nplatform: Zephyr-80\r\nkernel entry: OK\r\nserial: OK\r\n"


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def revision(path):
    """HEAD and whether the tree has changes, or None outside a checkout."""
    try:
        head = subprocess.run(["git", "-C", str(path), "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
        status = subprocess.run(["git", "-C", str(path), "status", "--porcelain"], capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    return {"path": str(path), "head": head, "changed": [line for line in status.splitlines() if line]}


def resolve_inputs(names, args):
    """Map input names to existing files; returns (paths, errors)."""
    paths, errors = {}, []
    for name in names:
        root_name, relative, build = INPUTS[name]
        root = getattr(args, f"{root_name}_root")
        if root is None:
            errors.append(f"input {name}: pass --{root_name}-root")
            continue
        path = (root / relative).resolve()
        if not path.is_file():
            errors.append(f"input {name}: {path} is missing; build it with: {build.format(root=root.resolve())}")
            continue
        paths[name] = path
    return paths, errors


def open_raw(path):
    """Open a pty slave raw at 115200 8N1 with non-blocking reads (VMIN=VTIME=0)."""
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
    tty.setraw(fd)
    attrs = termios.tcgetattr(fd)
    attrs[2] = (attrs[2] & ~(termios.CSIZE | termios.PARENB | termios.CSTOPB | termios.CRTSCTS)) | termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[4] = attrs[5] = termios.B115200
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    return fd


class HostSession:
    """`serial-pty`: a host terminal on the real pty, paced by the host clock.

    Sends the AAh 55h host sync every 0.25 s until the first byte, waits for
    the prompt, types `pwd` one byte per echo (the guest's receiver is
    polled, one byte deep) and checks the answer and the prompt after it."""

    def __init__(self, prompt, verdict_file):
        self.prompt = prompt.encode()
        self.verdict_file = verdict_file
        self.data = b""
        self.state = "sync"
        self.next_send = 0.0
        self.line = b"pwd"
        self.index = 0
        self.mark = 0
        self.deadline = 0.0
        self.times = {}
        self.verdict = None

    def decide(self, ok, detail):
        self.verdict = (ok, detail)
        tmp = self.verdict_file.with_suffix(".tmp")
        tmp.write_text(f"{'PASS' if ok else 'FAIL'} {detail}\n")
        tmp.rename(self.verdict_file)
        self.state = "done"

    def step(self, fd, now, start):
        if self.state == "done":
            return
        if self.state == "sync":
            if self.data:
                self.state, self.deadline = "prompt", now + 120
                self.times["first byte"] = now - start
            elif now >= self.next_send:
                os.write(fd, b"\xaa\x55")
                self.next_send = now + 0.25
        elif self.state == "prompt":
            if self.prompt in self.data:
                self.times["prompt"] = now - start
                self.state, self.mark = "type", len(self.data)
                os.write(fd, self.line[:1])
                self.deadline = now + 2
            elif now > self.deadline:
                self.decide(False, "no prompt within 120 s of the first byte")
        elif self.state == "type":
            if self.line[self.index:self.index + 1] in self.data[self.mark:]:
                self.index += 1
                self.mark = len(self.data)
                os.write(fd, self.line[self.index:self.index + 1] if self.index < len(self.line) else b"\r")
                self.deadline = now + 2
                if self.index == len(self.line):
                    self.state, self.deadline = "answer", now + 5
            elif now > self.deadline:
                self.decide(False, f"no echo of byte {self.index + 1} of {self.line!r}")
        elif self.state == "answer":
            answer = self.data[self.mark:]
            row = answer.find(b"\r\n/system\r\n")
            if row >= 0 and self.prompt in answer[row:]:
                ok = BANNER in self.data and b"PANIC" not in self.data
                self.decide(ok, "host read the banner, the prompt %.1f s after start, typed pwd, read /system and the prompt" % self.times["prompt"]
                            if ok else "the transcript lacks the banner or reports PANIC")
            elif now > self.deadline:
                self.decide(False, f"no /system answer to pwd: {answer[-120:]!r}")


def launch(command, environment, wall, case_dir, spec, prompt):
    """Run MAME; attach the pty for Lua or the host session; enforce the wall watchdog.

    Returns (exit code, log text, {trace line: wall seconds})."""
    process = subprocess.Popen(["stdbuf", "-oL", "-eL"] + command, env=environment, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT)
    start = time.monotonic()
    deadline = start + wall
    log, slave, host = b"", None, None
    trace_wall = {}
    pending = b""
    if spec.get("host") == "session":
        host = HostSession(prompt, case_dir / "host.verdict")
    capture = open(case_dir / "serial.bin", "wb") if host else None
    try:
        while True:
            now = time.monotonic()
            if now > deadline:
                process.kill()
                process.wait()
                log += f"\nWALL TIMEOUT after {wall} s; MAME killed\n".encode()
                return 124, log.decode(errors="replace"), trace_wall
            streams = [process.stdout] + ([slave] if host and slave is not None else [])
            ready, _, _ = select.select(streams, [], [], 0.05)
            if process.stdout in ready:
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    break
                log += chunk
                pending += chunk
                *lines, pending = pending.split(b"\n")
                for line in lines:
                    text = line.decode(errors="replace").rstrip("\r")
                    if text.startswith(("TRACE ", "PASS harness", "FAIL harness")):
                        trace_wall[text] = round(now - start, 3)
                    match = re.search(r"pseudo terminal slave (\S+)", text)
                    if match and slave is None and spec.get("pty"):
                        slave = open_raw(match.group(1))
                        if not host:
                            path_file = case_dir / "serial.tty"
                            (case_dir / "serial.tty.tmp").write_text(match.group(1) + "\n")
                            (case_dir / "serial.tty.tmp").rename(path_file)
            if host and slave is not None:
                if slave in ready:
                    data = os.read(slave, 4096)
                    host.data += data
                    capture.write(data)
                host.step(slave, now, start)
        code = process.wait(timeout=max(1, deadline - time.monotonic()))
    except subprocess.TimeoutExpired:
        code = 124
        log += b"\nWALL TIMEOUT waiting for MAME to exit\n"
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        if slave is not None:
            os.close(slave)
        if capture:
            capture.close()
    return code, log.decode(errors="replace"), trace_wall


def mame_command(mame, image, case_dir, spec, deadline):
    command = [str(mame), "zephyr80", "-noreadconfig", "-skip_gameinfo", "-video", "none", "-sound", "none",
               "-seconds_to_run", str(deadline + 2),
               "-cfg_directory", str(case_dir / "cfg"), "-nvram_directory", str(case_dir / "nvram"),
               "-state_directory", str(case_dir / "sta"), "-snapshot_directory", str(case_dir / "snap"),
               "-flash", str(image), "-autoboot_script", str(HERE / "harness.lua"), "-autoboot_delay", "0"]
    if not spec.get("throttle"):
        command.append("-nothrottle")
    if spec.get("pty"):
        command += ["-sio0b_rs232", "pty"]
    return command + list(spec.get("mame_args", ()))


def run_lua(name, spec, mame, inputs, case_dir, prompt):
    if inputs:
        image = inputs[spec["inputs"][0]]
    else:
        image = case_dir / "halt.bin"
        image.write_bytes(b"\xf3\x76")  # DI; HALT
    deadline = spec["deadline"]
    command = mame_command(mame, image, case_dir, spec, deadline)
    harness_env = {"HARNESS_CASE": name, "HARNESS_SCRIPT": str(HERE / spec["script"]), "HARNESS_DIR": str(case_dir),
                   "HARNESS_DEADLINE": str(deadline), "HARNESS_PROMPT": prompt,
                   "HARNESS_TTY_FILE": str(case_dir / "serial.tty"), "HARNESS_HOST_FILE": str(case_dir / "host.verdict")}
    manifest = {"case": name, "about": spec["about"], "command": command, "environment": harness_env,
                "limits": {"emulated_seconds": deadline, "wall_seconds": spec["wall"], "mame_seconds_to_run": deadline + 2},
                "flash": {"path": str(image), "bytes": image.stat().st_size, "sha256": sha(image)}}
    (case_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    start = time.monotonic()
    code, log, trace_wall = launch(command, dict(os.environ, **harness_env), spec["wall"], case_dir, spec, prompt)
    wall = time.monotonic() - start
    (case_dir / "mame.log").write_text(log)
    lines = log.splitlines()
    verdicts = [line for line in lines if re.match(rf"(PASS|FAIL) harness {re.escape(name)}: ", line)]
    ok = code == 0 and len(verdicts) == 1 and verdicts[0].startswith("PASS") and not any(
        line.startswith("FAIL harness") for line in lines)
    emulated = re.search(r"^TRACE emulated ([0-9.]+) s", log, re.M)
    serial = case_dir / "serial.bin"
    record = {"case": name, "pass": ok, "exit": code, "wall_seconds": round(wall, 3),
              "emulated_seconds": float(emulated.group(1)) if emulated else None,
              "verdict": verdicts[0] if verdicts else None,
              "traces": [{"line": line, "wall_seconds": trace_wall.get(line)} for line in lines if line.startswith("TRACE ")],
              "diagnostics": [line for line in lines if line.startswith("DIAG ")],
              "serial_bytes": serial.stat().st_size if serial.is_file() else 0,
              "log": str(case_dir / "mame.log")}
    if not ok and not verdicts:
        record["diagnostics"].append(f"DIAG no harness verdict; MAME exit {code}; log tail: {log[-600:]!r}")
    return record


def run_suite(name, spec, mame, inputs, case_dir, subcases):
    if "call" in spec:
        records = spec["call"](mame, inputs, case_dir, subcases or None)
    else:
        records = spec["module"].run(mame, inputs.get("konaos"), inputs.get("zsdos"), case_dir, subcases or None)
    passed = sum(r["pass"] for r in records)
    return {"case": name, "pass": passed == len(records) and bool(records),
            "probes": {"passed": passed, "failed": len(records) - passed, "skipped": 0},
            "wall_seconds": round(sum(r["wall_seconds"] for r in records), 3), "results": records}


def parse_case(text):
    name, _, sub = text.partition(":")
    if name not in CASES:
        raise argparse.ArgumentTypeError(f"unknown case {name!r}; --list shows the cases")
    if sub:
        spec = CASES[name]
        if spec["kind"] != "suite" or sub not in spec.get("probes", getattr(spec["module"], "CASES", ())):
            raise argparse.ArgumentTypeError(f"case {name} has no probe {sub!r}")
    return name, sub


def interactive(args):
    """Boot the serial image in real time for a person at a terminal."""
    inputs, errors = resolve_inputs(("serial",), args)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 2
    session = args.output.resolve() / "interactive"
    command = [str(args.mame), "zephyr80", "-noreadconfig", "-skip_gameinfo", "-video", "none", "-sound", "none",
               "-cfg_directory", str(session / "cfg"), "-nvram_directory", str(session / "nvram"),
               "-state_directory", str(session / "sta"), "-snapshot_directory", str(session / "snap"),
               "-flash", str(inputs["serial"]), "-sio0b_rs232", "pty", "-seconds_to_run", "3600"]
    print("run.py: " + " ".join(command))
    process = subprocess.Popen(["stdbuf", "-oL"] + command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    slave, log = None, b""
    try:
        while slave is None:
            chunk = os.read(process.stdout.fileno(), 4096)
            if not chunk:
                return 1
            log += chunk
            match = re.search(rb"pseudo terminal slave (\S+)", log)
            if match:
                path = match.group(1).decode()
                slave = open_raw(path)
        # The image waits for the host sync before its banner; send it until the first byte.
        first, limit = b"", time.monotonic() + 30
        while not first and time.monotonic() < limit:
            os.write(slave, b"\xaa\x55")
            time.sleep(0.25)
            first = os.read(slave, 4096)
        print(f"run.py: first bytes {first!r}")
        print(f"run.py: attach a terminal, for example: picocom -b 115200 {path}")
        print("run.py: the shell prompt follows in a few seconds; close MAME or press Ctrl-C to end")
        while process.poll() is None:
            chunk = os.read(process.stdout.fileno(), 4096)
            if not chunk:
                break
            sys.stdout.write(chunk.decode(errors="replace"))
    except KeyboardInterrupt:
        pass
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        if slave is not None:
            os.close(slave)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--mame", type=Path, help="MAME binary (mame/mamepbitzd or mame/mamepbitz)")
    parser.add_argument("--case", action="append", type=parse_case, default=[],
                        help="case to run, repeatable; CASE:PROBE runs one probe of a suite")
    parser.add_argument("--list", action="store_true", help="list the cases and exit")
    parser.add_argument("--konaos-root", type=Path, help="ZephyrOS checkout")
    parser.add_argument("--zephyr-root", type=Path, help="Zephyr-80 checkout")
    parser.add_argument("--output", type=Path, default=HERE / "output" / "run", help="result directory (default tests/output/run)")
    parser.add_argument("--prompt", default=DEFAULT_PROMPT, help=f"serial shell prompt (default {DEFAULT_PROMPT!r})")
    parser.add_argument("--interactive", action="store_true",
                        help="boot the serial image in real time on a pty for a terminal (no verdict)")
    args = parser.parse_args()

    if args.list:
        for name, spec in CASES.items():
            needs = ", ".join(spec["inputs"]) or "none"
            print(f"{name:13} {spec['about']} [inputs: {needs}]")
        return 0
    if args.mame is None or not args.mame.is_file():
        print(f"run.py: MAME binary {args.mame} is missing; build it in mame/ with: make SUBTARGET=pbitz DEBUG=1 -j2",
              file=sys.stderr)
        return 2
    args.mame = args.mame.resolve()
    if args.interactive:
        return interactive(args)
    if not args.case:
        parser.error("no --case given; --list shows the cases")

    # Group CASE:PROBE selections; a repeated plain case runs again.
    runs = []
    for name, sub in args.case:
        if sub and runs and runs[-1][0] == name and runs[-1][1]:
            runs[-1][1].append(sub)
        else:
            runs.append((name, [sub] if sub else []))
    needed = sorted({i for name, _ in runs for i in CASES[name]["inputs"]})
    inputs, errors = resolve_inputs(needed, args)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if errors:
        for error in errors:
            print(f"run.py: {error}", file=sys.stderr)
        (output / "results.json").write_text(json.dumps({"error": "missing input", "details": errors}, indent=2) + "\n")
        print(f"RESULT 0 passed, {len(runs)} failed, 0 skipped (missing input)")
        return 2

    mame_sha = sha(args.mame)
    revisions = {"mame": revision(args.mame.parent),
                 "zephyr": revision(args.zephyr_root) if args.zephyr_root else None,
                 "konaos": revision(args.konaos_root) if args.konaos_root else None}
    results, seen = [], {}
    for name, subcases in runs:
        seen[name] = seen.get(name, 0) + 1
        label = name if seen[name] == 1 else f"{name}-{seen[name]}"
        case_dir = output / label
        if case_dir.exists():
            shutil.rmtree(case_dir)
        case_dir.mkdir(parents=True)
        spec = CASES[name]
        case_inputs = {k: inputs[k] for k in spec["inputs"]}
        (case_dir / "inputs.json").write_text(json.dumps({
            "mame": {"path": str(args.mame), "sha256": mame_sha}, "revisions": revisions,
            "inputs": {k: {"path": str(p), "bytes": p.stat().st_size, "sha256": sha(p)} for k, p in case_inputs.items()},
        }, indent=2) + "\n")
        print(f"run.py: {label}: {spec['about']}", flush=True)
        if spec["kind"] == "suite":
            record = run_suite(name, spec, args.mame, case_inputs, case_dir, subcases)
        else:
            record = run_lua(name, spec, args.mame, case_inputs, case_dir, args.prompt)
        record["label"] = label
        record["inputs"] = {k: sha(p) for k, p in case_inputs.items()}
        (case_dir / "result.json").write_text(json.dumps(record, indent=2) + "\n")
        results.append(record)
        status = "PASS" if record["pass"] else "FAIL"
        if spec["kind"] == "suite":
            p = record["probes"]
            print(f"{status} {label}: {p['passed']} passed, {p['failed']} failed, {p['skipped']} skipped ({record['wall_seconds']} s)")
            for r in record["results"]:
                if not r["pass"]:
                    print(f"  FAIL {r['case']}: exit {r['exit']}; log {r['log']}")
        else:
            emulated = record["emulated_seconds"]
            print(f"{status} {label}: {record['verdict'] or 'no verdict'} (exit {record['exit']}, "
                  f"{record['wall_seconds']} s wall, {emulated if emulated is not None else '?'} s emulated)")
            for line in record["diagnostics"]:
                print(f"  {line}")
        sys.stdout.flush()
    passed = sum(r["pass"] for r in results)
    summary = {"mame": {"path": str(args.mame), "sha256": mame_sha}, "revisions": revisions,
               "passed": passed, "failed": len(results) - passed, "skipped": 0, "results": results}
    (output / "results.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"RESULT {passed} passed, {len(results) - passed} failed, 0 skipped")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
