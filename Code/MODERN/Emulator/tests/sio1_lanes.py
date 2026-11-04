"""SIO1 lane probes: the `sio1-lanes` case of tests/run.py.

Each probe boots the probe program (sio1_lanes.asm, assembled here) and runs
one sio1_lanes.lua case body under harness.lua in its own MAME process."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

HERE = Path(__file__).resolve().parent
CASES = ("exchange", "hunt", "underrun", "early", "overrun", "reset", "irq", "state")
DEADLINE = 3   # emulated seconds per probe; MAME's own bound is two seconds later
WALL = 60


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def assemble(output):
    """Build the probe flash image from sio1_lanes.asm with the SDCC tools."""
    build = output / "sio1_lanes"
    build.mkdir(parents=True, exist_ok=True)
    rel, ihx, image = build / "sio1_lanes.rel", build / "sio1_lanes.ihx", build / "sio1_lanes.bin"
    for command in (["sdasz80", "-o", "-l", "-s", str(rel), str(HERE / "sio1_lanes.asm")],
                    ["sdldz80", "-n", "-i", str(ihx), str(rel)],
                    ["makebin", str(ihx), str(image)]):
        subprocess.run(command, check=True, capture_output=True, text=True)
    return image


def run_body(mame, image, case_dir, body, extra=()):
    """One MAME process running case body `body`; returns (ok, exit code, log, command)."""
    command = [str(mame.resolve()), "zephyr80", "-noreadconfig", "-skip_gameinfo", "-video", "none", "-sound", "none",
               "-nothrottle", "-seconds_to_run", str(DEADLINE + 2),
               "-cfg_directory", str(case_dir / "cfg"), "-nvram_directory", str(case_dir / "nvram"),
               "-state_directory", str(case_dir / "sta"), "-snapshot_directory", str(case_dir / "snap"),
               "-flash", str(image), "-autoboot_script", str(HERE / "harness.lua"), "-autoboot_delay", "0", *extra]
    environment = dict(os.environ, HARNESS_CASE=body, HARNESS_SCRIPT=str(HERE / "sio1_lanes.lua"),
                       HARNESS_DIR=str(case_dir), HARNESS_DEADLINE=str(DEADLINE))
    try:
        result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=WALL)
        code, log = result.returncode, result.stdout + result.stderr
    except subprocess.TimeoutExpired as exc:
        code = 124
        log = (exc.stdout or b"").decode(errors="replace") + f"\nWALL TIMEOUT after {WALL} seconds\n"
    verdicts = [line for line in log.splitlines() if re.match(rf"(PASS|FAIL) harness {re.escape(body)}: ", line)]
    return code == 0 and len(verdicts) == 1 and verdicts[0].startswith("PASS"), code, log, command


def run(mame, konaos_image, zsdos_image, output, cases=None):
    """Run the probes (all of CASES by default) into `output`; returns one record per probe.

    `state` is two processes: one saves a synchronised lane, the next starts
    from that state."""
    output.mkdir(parents=True, exist_ok=True)
    image = assemble(output)
    results = []
    for case in cases or CASES:
        case_dir = output / case
        case_dir.mkdir(parents=True, exist_ok=True)
        start = time.monotonic()
        if case == "state":
            ok, code, log, command = run_body(mame, image, case_dir, "state-save")
            if ok:
                ok, code, more, command = run_body(mame, image, case_dir, "state-load", ("-state", "synced"))
                log += more
        else:
            ok, code, log, command = run_body(mame, image, case_dir, case)
        wall = time.monotonic() - start
        (output / f"{case}.log").write_text(log)
        lines = log.splitlines()
        emulated = re.search(r"^TRACE emulated ([0-9.]+) s", log, re.M)
        results.append({"case": case, "pass": ok, "exit": code, "wall_seconds": round(wall, 3),
                        "emulated_seconds": float(emulated.group(1)) if emulated else None,
                        "verdict": " / ".join(line for line in lines if re.match(r"(PASS|FAIL) harness ", line)) or None,
                        "traces": [line for line in lines if line.startswith("TRACE ")],
                        "log": str(output / f"{case}.log"), "command": command, "image": str(image), "sha256": sha(image)})
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    return results
