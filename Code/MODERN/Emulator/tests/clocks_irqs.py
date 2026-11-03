#!/usr/bin/env python3
"""Bounded standalone clock/interrupt probes, for integration with the shared runner."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import select
import subprocess
import time
import tty

HERE = Path(__file__).resolve().parent
PROBES = ("channels", "timer", "baud", "overlap", "daisy", "pty", "latch", "nmi", "nested")
GUESTS = ("konaos", "zsdos")
# Emulated-second verdict limit per case; MAME's own bound is one second later.
LIMITS = {"channels": 2, "timer": 6, "baud": 2, "overlap": 2, "daisy": 2, "pty": 5, "latch": 4, "nmi": 3, "nested": 2, "konaos": 6, "zsdos": 6}
BANNER = b"ZEPHYR80 SIO0B PTY 115200\r\n"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def assemble(output):
    """Build the probe flash image from clocks_irqs.asm with the SDCC tools."""
    build = output / "clocks_irqs"
    build.mkdir(parents=True, exist_ok=True)
    rel, ihx, image = build / "clocks_irqs.rel", build / "clocks_irqs.ihx", build / "clocks_irqs.bin"
    for command in (["sdasz80", "-o", "-l", "-s", str(rel), str(HERE / "clocks_irqs.asm")],
                    ["sdldz80", "-n", "-i", str(ihx), str(rel)],
                    ["makebin", str(ihx), str(image)]):
        subprocess.run(command, check=True, capture_output=True, text=True)
    return image


def pty_session(command, environment, wall):
    """Run MAME with SIO0/B on a pty and read what the guest transmits."""
    process = subprocess.Popen(["stdbuf", "-oL"] + command, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log, received, slave, deadline = b"", b"", None, time.monotonic() + wall
    try:
        while time.monotonic() < deadline:
            streams = [process.stdout] + ([slave] if slave is not None else [])
            ready, _, _ = select.select(streams, [], [], 0.1)
            if process.stdout in ready:
                chunk = os.read(process.stdout.fileno(), 4096)
                if not chunk:
                    break
                log += chunk
                match = re.search(rb"pseudo terminal slave (\S+)", log)
                if match and slave is None:
                    slave = os.open(match.group(1).decode(), os.O_RDWR | os.O_NOCTTY)
                    tty.setraw(slave)
            if slave is not None and slave in ready:
                received += os.read(slave, 4096)
        process.wait(timeout=max(1, deadline - time.monotonic()))
        code = process.returncode
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
        code = 124
        log += b"\nWALL TIMEOUT\n"
    finally:
        if slave is not None:
            os.close(slave)
    rest = process.stdout.read() if process.stdout else b""
    return code, (log + rest).decode(errors="replace"), received


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mame", required=True, type=Path)
    parser.add_argument("--konaos-image", required=True, type=Path)
    parser.add_argument("--zsdos-image", required=True, type=Path)
    parser.add_argument("--case", action="append", choices=PROBES + GUESTS)
    parser.add_argument("--output", type=Path, default=HERE / "output")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    probe = assemble(output)
    cases = args.case or list(PROBES + GUESTS)
    results = []
    for case in cases:
        image = {"konaos": args.konaos_image, "zsdos": args.zsdos_image}.get(case, probe).resolve()
        limit = LIMITS[case]
        command = [str(args.mame.resolve()), "zephyr80", "-noreadconfig", "-video", "none", "-sound", "none",
                   "-skip_gameinfo", "-seconds_to_run", str(limit + 1), "-cfg_directory", str(output / "cfg"),
                   "-nvram_directory", str(output / "nvram"), "-state_directory", str(output / "sta"),
                   "-snapshot_directory", str(output / "snap"), "-flash", str(image),
                   "-autoboot_script", str(HERE / "clocks_irqs.lua"), "-autoboot_delay", "0"]
        if case != "pty":
            command.append("-nothrottle")
        if case == "baud":
            command += ["-sio0a_rs232", "loopback"]
        if case == "pty":
            command += ["-sio0b_rs232", "pty"]
        environment = dict(os.environ, CLKIRQ_CASE=case, CLKIRQ_LIMIT=str(limit))
        start = time.monotonic()
        if case == "pty":
            code, log, received = pty_session(command, environment, 60)
            lines = received.count(BANNER)
            ok = code == 0 and lines >= 2 and received in BANNER * (lines + 2)
            log += f"\nPTY received {len(received)} bytes, {lines} complete banner lines: {received[:120]!r}\n"
            log += f"{'PASS' if ok else 'FAIL'} clocks-irqs pty: host pty read {lines} banner lines at 115200 8N1\n"
        else:
            try:
                result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=120)
            except subprocess.TimeoutExpired as exc:
                result = subprocess.CompletedProcess(command, 124, (exc.stdout or b"").decode(), (exc.stderr or b"").decode() + "\nWALL TIMEOUT after 120 seconds\n")
            code, log = result.returncode, result.stdout + result.stderr
            ok = code == 0 and f"PASS clocks-irqs {case}:" in log and "FAIL clocks-irqs" not in log
        wall = time.monotonic() - start
        (output / f"{case}.log").write_text(log)
        emulated = re.search(r"TRACE emulated ([0-9.]+) s", log)
        emulated = float(emulated.group(1)) if emulated else None
        verdict = next((line for line in log.splitlines() if re.match(r"(PASS|FAIL) clocks-irqs ", line)), None)
        record = {"case": case, "pass": ok, "exit": code, "wall_seconds": round(wall, 3), "emulated_seconds": emulated,
                  "speed_percent": round(100 * emulated / wall, 1) if emulated and case != "pty" else None,
                  "verdict": verdict, "command": command, "image": str(image), "sha256": sha(image)}
        results.append(record)
        print(json.dumps(record), flush=True)
        if not ok:
            print(log, flush=True)
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    passed = sum(r["pass"] for r in results)
    print(f"RESULT {passed}/{len(results)} passed, {len(results) - passed} failed, 0 skipped")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
