"""Memory-flash probes: the `memory-flash` case of tests/run.py."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

HERE = Path(__file__).resolve().parent
CASES = ("one", "partial", "full", "empty", "oversized", "absent", "missing", "unreadable", "decoder", "reload", "konaos", "zsdos")


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(mame, konaos_image, zsdos_image, output, cases=None):
    """Run the probes (all of CASES by default) into `output`; returns one record per probe."""
    output.mkdir(parents=True, exist_ok=True)
    full = bytes(((a >> 16) * 17 + (a >> 8) + (a & 255) * 7) & 255 for a in range(524288))
    for name, data in (("one", b"\x76"), ("partial", full[:65537]), ("full", full), ("empty", b""), ("oversized", full + b"\x00")):
        (output / f"{name}.bin").write_bytes(data)
    (output / "unreadable.bin").mkdir(exist_ok=True)
    cases = cases or CASES
    results = []
    for case in cases:
        image = {"konaos": konaos_image.resolve(), "zsdos": zsdos_image.resolve(), "decoder": output / "full.bin", "reload": output / "full.bin"}.get(case, output / f"{case}.bin")
        command = [str(mame.resolve()), "zephyr80", "-noreadconfig", "-video", "none", "-sound", "none", "-nothrottle", "-skip_gameinfo", "-seconds_to_run", "2", "-cfg_directory", str(output / "cfg"), "-nvram_directory", str(output / "nvram"), "-state_directory", str(output / "sta"), "-snapshot_directory", str(output / "snap")]
        if case != "missing":
            command += ["-flash", str(image)]
        invalid = case in {"empty", "oversized", "absent", "missing", "unreadable"}
        if not invalid:
            command += ["-autoboot_script", str(HERE / "memory_flash.lua"), "-autoboot_delay", "0"]
        environment = dict(os.environ, MEMFLASH_CASE=case, MEMFLASH_OUTPUT=str(output), MEMFLASH_IMAGE=str(image), MEMFLASH_FIXTURE=str(HERE / "fixtures/rev13.txt"), MEMFLASH_OS_PAGE="1" if case == "konaos" else "7")
        start = time.monotonic()
        try:
            result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=60)
        except subprocess.TimeoutExpired as exc:
            result = subprocess.CompletedProcess(command, 124, (exc.stdout or b"").decode(), (exc.stderr or b"").decode() + "\nWALL TIMEOUT after 60 seconds\n")
        log = result.stdout + result.stderr
        (output / f"{case}.log").write_text(log)
        if invalid:
            expected = {"empty": "1 to 524288", "oversized": "1 to 524288", "absent": "No such file", "missing": "flash", "unreadable": "Is a directory"}[case]
            ok = result.returncode == (3 if case == "missing" else 4) and expected.lower() in log.lower()
        else:
            ok = result.returncode == 0 and f"PASS memory-flash {case}:" in log and "FAIL memory-flash" not in log
        record = {"case": case, "pass": ok, "exit": result.returncode, "wall_seconds": round(time.monotonic() - start, 3), "log": str(output / f"{case}.log"), "command": command, "image": str(image), "sha256": sha(image) if image.is_file() else None}
        results.append(record)
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    return results
