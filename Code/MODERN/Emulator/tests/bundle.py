"""Emulator bundle case of tests/run.py: `bundle`.

The archive is packed from the release binary (tools/bundle.py) and extracted
to a path with spaces, with no variable naming a source tree and no emulator on
PATH; the runs start from another directory with spaces.

`launch`: the manifest lists exactly the extracted files, with their hashes and
modes; `start.sh` boots KonaOS with the starter card to the `/> ` prompt
(tests/bundle.lua), the process maps every library the bundle ships from the
bundle, and the `konaos` plugin loads from the bundle's `plugins/`.

`sdk-run`: the standalone SDK, unpacked at a path with spaces, runs its template
with `make run KOS_MAME=<bundle>` and nothing else naming the emulator: the
image, the plugin and the map are the bundle's; `KOS_BREAK=main` stops in the
program through the plugin's bank-aware breakpoint."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

import devtools

HERE = Path(__file__).resolve().parent
PROBES = ("launch", "sdk-run")
ARCHIVE = "zephyr80-mame-linux-x86_64.tar.xz"
# Variables that would let a run find a source tree or another emulator.
STRIP = ("KONAOS_ROOT", "ZEPHYR_ROOT", "KONAOS_SESSION", "LD_LIBRARY_PATH", "QT_PLUGIN_PATH", "QT_QPA_PLATFORM")


def clean_env(home):
    env = {k: v for k, v in os.environ.items()
           if k not in STRIP and not k.startswith(("KOS_", "ZEPHYR80_", "HARNESS_"))}
    env.update(PATH="/usr/bin:/bin", HOME=str(home), LANG="C")
    return env


def pack(mame, inputs, output):
    """The archive for `mame`, packed once per run of the case."""
    archive = output / "archive" / ARCHIVE
    if archive.is_file():
        return archive, ""
    if Path(mame).read_bytes()[:4] != b"\x7fELF":
        raise RuntimeError(f"{mame} is not the release binary (the bundle's own script); pass mame/mamepbitz")
    root = inputs["konaos"].parents[1]
    result = subprocess.run(["python3", str(HERE.parent / "tools/bundle.py"), "--mame", str(mame), "--konaos-root", str(root),
                             "--output", str(archive.parent)], capture_output=True, text=True, timeout=900)
    log = result.stdout + result.stderr
    if result.returncode:
        raise RuntimeError("tools/bundle.py failed:\n" + log)
    return archive, log


def extract(archive, tmp):
    target = tmp / "extracted bundle"
    target.mkdir()
    subprocess.run(["tar", "-xf", str(archive), "-C", str(target)], check=True)
    return target / "zephyr80-mame"


def check_manifest(bundle):
    """The manifest names every file but itself, with its size, hash and mode."""
    manifest = json.loads((bundle / "MANIFEST.json").read_text())
    listed = manifest["files"]
    present = {p.relative_to(bundle).as_posix() for p in bundle.rglob("*") if p.is_file()} - {"MANIFEST.json"}
    problems = []
    if present != set(listed):
        problems.append(f"files differ: only extracted {sorted(present - set(listed))[:5]}, only listed {sorted(set(listed) - present)[:5]}")
    for path in sorted(present & set(listed)):
        data = (bundle / path).read_bytes()
        info = listed[path]
        if hashlib.sha256(data).hexdigest() != info["sha256"] or len(data) != info["bytes"]:
            problems.append(f"{path} differs from the manifest")
        if oct((bundle / path).stat().st_mode & 0o777) != info["mode"]:
            problems.append(f"{path} has mode {oct((bundle / path).stat().st_mode & 0o777)}, listed {info['mode']}")
    return manifest, problems


def run_launch(mame, inputs, output, case_dir):
    start = time.monotonic()
    archive, log = pack(mame, inputs, output)
    tmp = Path(tempfile.mkdtemp(prefix="zephyr80 launch "))
    try:
        bundle = extract(archive, tmp)
        manifest, problems = check_manifest(bundle)
        log += f"manifest: {len(manifest['files'])} files, {len(problems)} problems\n" + "".join(p + "\n" for p in problems)
        elsewhere = tmp / "another directory"
        elsewhere.mkdir()
        command = [str(bundle / "start.sh"), "-plugin", "konaos", "-video", "none", "-sound", "none", "-nothrottle",
                   "-seconds_to_run", "30", "-autoboot_script", str(HERE / "bundle.lua"), "-autoboot_delay", "0"]
        env = clean_env(tmp / "home")
        env.update(BUNDLE_DIR=str(bundle), BUNDLE_LIBS=":".join(sorted(p.name for p in (bundle / "lib").iterdir())))
        result = subprocess.run(command, cwd=elsewhere, env=env, capture_output=True, text=True, timeout=300)
        log += "$ " + " ".join(command) + "\n" + result.stdout + result.stderr
        verdicts = [line for line in result.stdout.splitlines() if line.startswith(("PASS bundle:", "FAIL bundle:"))]
        ok = not problems and result.returncode == 0 and len(verdicts) == 1 and verdicts[0].startswith("PASS")
        info = {"archive": str(archive), "archive_sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
                "archive_bytes": archive.stat().st_size, "files": len(manifest["files"]), "extracted_to": str(bundle),
                "verdict": verdicts[0] if verdicts else None}
        return devtools.record("launch", ok, result.returncode, log, command, start, info)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def run_sdk(mame, inputs, output, case_dir):
    start = time.monotonic()
    archive, log = pack(mame, inputs, output)
    tmp = Path(tempfile.mkdtemp(prefix="zephyr80 sdk "))
    try:
        bundle = extract(archive, tmp)
        sdk = devtools.unpack_sdk(inputs["sdk"], tmp / "my sdk")
        env = clean_env(tmp / "home")
        options = "-noreadconfig -video none -sound none -nothrottle -seconds_to_run 120 -debug -debugger none"
        result = subprocess.run(["make", "--no-print-directory", "run", f"KOS_MAME={bundle}", "KOS_RUN_EXIT=1", "KOS_BREAK=main",
                                 f"KOS_MAME_ARGS={options}"], cwd=sdk / "template", env=env, capture_output=True, text=True,
                                timeout=600)
        log += result.stdout + result.stderr
        text = (sdk / "template/build/run/result.txt")
        text = text.read_text() if text.is_file() else ""
        ok = (result.returncode == 0 and text.startswith("ran\n") and "hello from a KonaOS program" in text
              and "stopped at hello:_main" in log and "breakpoint hello:main" in log)
        return devtools.record("sdk-run", ok, result.returncode, log, None, start, {"result": text, "bundle": str(bundle)})
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def run(mame, inputs, output, cases=None):
    output.mkdir(parents=True, exist_ok=True)
    results = []
    for probe in cases or PROBES:
        case_dir = output / probe
        if case_dir.exists():
            shutil.rmtree(case_dir)
        case_dir.mkdir(parents=True)
        try:
            r = (run_launch if probe == "launch" else run_sdk)(mame, inputs, output, case_dir)
        except Exception as exc:
            r = {"case": probe, "pass": False, "exit": 1, "wall_seconds": 0, "log": f"ERROR {exc}\n", "command": None}
        log_path = case_dir / "probe.log"
        log_path.write_text(r.pop("log"))
        r["log"] = str(log_path)
        results.append(r)
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    return results
