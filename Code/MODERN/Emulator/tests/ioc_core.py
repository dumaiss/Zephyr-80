"""IOC core probes: the `ioc-core` case of tests/run.py.

`core` builds tests/ioc_core/ioc_core_test.cpp with the protocol core
(mame/src/mame/pbitz/zephyr80_ioc_core.cpp) and an in-memory card, and runs
it: real frames against firmware-derived replies, bulk transfers, media
effects.  `konaos` and `zsdos` boot each guest against the machine's empty
card socket and check every reply (sio1_lanes.lua ioc-konaos, ioc-zsdos)."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time

import sio1_lanes

HERE = Path(__file__).resolve().parent
EMULATOR = HERE.parent
CASES = ("core", "konaos", "zsdos")
DEADLINES = {"konaos": 10, "zsdos": 8}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run_core(case_dir):
    """Build and run the host test; returns (ok, exit code, log, command)."""
    binary = case_dir / "ioc_core_test"
    build = ["c++", "-std=c++17", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
             "-I", str(HERE / "ioc_core"), "-I", str(EMULATOR / "mame/src/osd"), "-I", str(EMULATOR / "mame/src/mame/pbitz"),
             str(HERE / "ioc_core/ioc_core_test.cpp"), str(EMULATOR / "mame/src/mame/pbitz/zephyr80_ioc_core.cpp"),
             "-o", str(binary)]
    built = subprocess.run(build, capture_output=True, text=True)
    log = "$ " + " ".join(build) + "\n" + built.stdout + built.stderr
    if built.returncode != 0:
        return False, built.returncode, log, build
    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=120)
    log += f"$ {binary}\n" + result.stdout + result.stderr
    verdict = re.search(r"^RESULT (\d+) passed, (\d+) failed", result.stdout, re.M)
    ok = result.returncode == 0 and verdict is not None and verdict.group(2) == "0"
    return ok, result.returncode, log, build


def run(mame, konaos_image, zsdos_image, output, cases=None):
    output.mkdir(parents=True, exist_ok=True)
    images = {"konaos": konaos_image, "zsdos": zsdos_image}
    results = []
    for case in cases or CASES:
        case_dir = output / case
        case_dir.mkdir(parents=True, exist_ok=True)
        start = time.monotonic()
        if case == "core":
            ok, code, log, command = run_core(case_dir)
            image = None
        else:
            image = images[case]
            ok, code, log, command = sio1_lanes.run_body(mame, image, case_dir, "ioc-" + case, deadline=DEADLINES[case])
        wall = time.monotonic() - start
        (output / f"{case}.log").write_text(log)
        lines = log.splitlines()
        emulated = re.search(r"^TRACE emulated ([0-9.]+) s", log, re.M)
        record = {"case": case, "pass": ok, "exit": code, "wall_seconds": round(wall, 3),
                  "emulated_seconds": float(emulated.group(1)) if emulated else None,
                  "verdict": " / ".join(line for line in lines if re.match(r"(PASS|FAIL|RESULT)( harness)? ", line)) or None,
                  "log": str(output / f"{case}.log"), "command": command}
        if image is not None:
            record.update(image=str(image), sha256=sha(image))
        results.append(record)
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    return results
