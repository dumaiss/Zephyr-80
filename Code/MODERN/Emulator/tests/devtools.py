"""Developer-tool cases of tests/run.py: `debug-symbols`, `sdk-run`, `save-restore`.

Every case unpacks the KonaOS SDK tarball (`make sdk` in the KonaOS checkout)
into its own directory and builds the fixtures with it: tests/sdk/bankbp (a
placed program whose home zone and far segment 1 both start at 8000h) and
tests/sdk/savework (card reads and writes, the timer, the console, PSG writes).

`debug-symbols`: the konaos plugin (mame/plugins/konaos) under `-debug
-debugger none`.  `banks` loads konaos.map, bankbp's and the template hello's
maps, checks the diagnostics and ambiguity rules, sets bank-aware breakpoints
on home_step and far_step and runs bankbp from a card folder: the stops come
home/far three times each, at 8000h, in two banks, the far ones with the
mode-10 aperture open; a plain breakpoint at 8000h stops six times; the SRAM
share, the debugger's `dump` of it and VRAM read other banks without moving
the latch or the VDP status.  `timing` runs the same program without the
debugger, with it, and with the two breakpoints, for the debugger's cost.

`sdk-run`: the SDK's `make run` from a directory whose path holds spaces,
with the MAME binary, the image and the card folder at paths with spaces:
`run` (the template), `names` (examples/files with arguments and an asset),
`no-mame` (an ordinary build with no emulator anywhere, and the run target's
errors for a missing binary, image and plugin).

`save-restore`: savework on the production image from a card image (`image`)
and a card folder (`folder`).  One run saves five states (idle at the prompt;
mid-command; mid-bulk, loading the program; mid-write, a block on its way to
the open OUTPUT.BIN; active: timer, console and PSG) and copies the card at
each save instant (the pre-save notifier); then every state is restored in a
fresh process onto a copy of its card and must finish exactly as the saving
run did: the line state at the first frame after the save, every PSG write,
VRAM, the VDP registers, the screen, the end time and the card's final
contents.  The image case also restores onto a changed card and with a changed
flash image, the folder case onto a changed folder: each must be refused."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

import card_backends
import fat_fixture as fat
import mame_args

HERE = Path(__file__).resolve().parent
PROBES = {
    "debug-symbols": ("banks", "timing"),
    "sdk-run": ("run", "names", "no-mame"),
    "save-restore": ("image", "folder"),
}
POINTS = ("idle", "command", "bulk", "write", "active")
INPUT = bytes((i * 13 + 5) & 255 for i in range(8192))


def sha(data):
    return hashlib.sha256(data).hexdigest()


def sdk_version(konaos_root):
    text = (konaos_root / "config/sdk.mk").read_text()
    return re.search(r"^KOS_SDK_VERSION\s*:=\s*(\S+)", text, re.M).group(1)


def unpack_sdk(tarball, dest):
    """The SDK tree unpacked under `dest`; returns its root."""
    dest.mkdir(parents=True, exist_ok=True)
    subprocess.run(["tar", "-xzf", str(tarball), "-C", str(dest)], check=True)
    return next(dest.glob("kos-sdk-*"))


def clean_env(path=None):
    """A minimal environment: no MAME on PATH unless `path` says so."""
    return {"PATH": path or "/usr/bin:/bin", "HOME": os.environ.get("HOME", "/tmp"), "LANG": "C"}


def make(cwd, *targets, env=None, timeout=600):
    result = subprocess.run(["make", "--no-print-directory", *targets], cwd=cwd, env=env or clean_env(),
                            capture_output=True, text=True, timeout=timeout)
    return result.returncode, result.stdout + result.stderr


def build_fixture(name, sdk):
    """tests/sdk/<name> built beside the SDK tree; returns its object directory."""
    work = sdk.parent / name
    if work.exists():
        shutil.rmtree(work)
    shutil.copytree(HERE / "sdk" / name, work)
    code, log = make(work, f"KOS_SDK_ROOT=../{sdk.name}")
    if code:
        raise RuntimeError(f"building {name} with the SDK failed:\n{log}")
    return work / "build/user" / name


def mame_run(mame, image, case_dir, body, deadline, wall, extra=(), env=None, state_dir=None, debug=False):
    """One MAME process running devtools.lua's `body` with the konaos plugin; returns (ok, exit, log, command, wall)."""
    case_dir.mkdir(parents=True, exist_ok=True)
    command = [str(mame), "zephyr80", "-noreadconfig", "-skip_gameinfo", "-video", "none", "-sound", "none",
               "-nothrottle", "-seconds_to_run", str(deadline + 2),
               "-cfg_directory", str(case_dir / "cfg"), "-nvram_directory", str(case_dir / "nvram"),
               "-state_directory", str(state_dir or case_dir / "sta"), "-snapshot_directory", str(case_dir / "snap"),
               "-flash", str(image), "-pluginspath", str(Path(mame).parent / "plugins"), "-plugin", "konaos",
               "-autoboot_script", str(HERE / "harness.lua"), "-autoboot_delay", "0",
               *mame_args.EXTRA, *extra]
    if debug:
        command += ["-debug", "-debugger", "none"]
    environment = dict(os.environ, HARNESS_CASE=body, HARNESS_SCRIPT=str(HERE / "devtools.lua"),
                       HARNESS_DIR=str(case_dir), HARNESS_DEADLINE=str(deadline), **(env or {}))
    (case_dir / "manifest.json").write_text(json.dumps({
        "body": body, "command": command, "flash": {"path": str(image), "sha256": sha(Path(image).read_bytes())},
        "environment": {k: v for k, v in environment.items() if k.startswith(("HARNESS_", "DEV_"))},
        "limits": {"emulated_seconds": deadline, "wall_seconds": wall}}, indent=2) + "\n")
    start = time.monotonic()
    try:
        result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=wall)
        code, log = result.returncode, result.stdout + result.stderr
    except subprocess.TimeoutExpired as exc:
        code = 124
        log = (exc.stdout or b"").decode(errors="replace") + f"\nWALL TIMEOUT after {wall} seconds\n"
    elapsed = time.monotonic() - start
    log += f"RUN wall {elapsed:.3f} s\n"
    (case_dir / "mame.log").write_text(log)
    verdicts = [line for line in log.splitlines() if re.match(rf"(PASS|FAIL) harness {re.escape(body)}: ", line)]
    ok = code == 0 and len(verdicts) == 1 and verdicts[0].startswith("PASS")
    return ok, code, log, command, elapsed


def record(case, ok, code, log, command, start, info=None):
    return {"case": case, "pass": ok, "exit": code, "wall_seconds": round(time.monotonic() - start, 3),
            "log": log, "command": command, **(info or {})}


# debug-symbols ----------------------------------------------------------------------

def setup_debug(inputs, case_dir):
    sdk = unpack_sdk(inputs["sdk"], case_dir / "sdk tree")
    bankbp = build_fixture("bankbp", sdk)
    code, log = make(sdk / "template")
    if code:
        raise RuntimeError("building the SDK template failed:\n" + log)
    card = case_dir / "card"
    card.mkdir(exist_ok=True)
    shutil.copyfile(bankbp.parent / "bankbp.exe", card / "BANKBP.EXE")
    # A placement naming a home area the map lacks.
    bad = case_dir / "badplace"
    if bad.exists():
        shutil.rmtree(bad)
    shutil.copytree(bankbp, bad / "badplace")
    (bad / "badplace/bankbp.map").rename(bad / "badplace/badplace.map")
    (bad / "badplace/bankbp.json").rename(bad / "badplace/badplace.json")
    placement = json.loads((bad / "badplace/place/placement.json").read_text())
    placement["home_area"] = "_ZMISSING"
    (bad / "badplace/place/placement.json").write_text(json.dumps(placement))
    env = {"DEV_OSMAP": str(inputs["konaos"].parent / "konaos.map"), "DEV_BANKBP_MAP": str(bankbp / "bankbp.map"),
           "DEV_HELLO_MAP": str(sdk / "template/build/user/hello/hello.map"),
           "DEV_BAD_MAP": str(bad / "badplace/badplace.map")}
    return env, card, bankbp


def run_debug(probe, mame, inputs, case_dir):
    start = time.monotonic()
    env, card, bankbp = setup_debug(inputs, case_dir)
    exe = (bankbp.parent / "bankbp.exe").read_bytes()
    info = {"bankbp_sha256": sha(exe)}
    if probe == "banks":
        ok, code, log, command, _ = mame_run(mame, inputs["konaos"], case_dir / "run", "debug-banks", 60, 300,
                                             extra=("-carddir", str(card)), env=env, debug=True)
        return record(probe, ok, code, log, command, start, info)
    # timing: no debugger, the debugger, the debugger with two breakpoints.
    rows, logs, ok_all, code_all = [], "", True, 0
    for label, debug, breaks in (("plain", False, "0"), ("debug", True, "0"), ("breaks", True, "1")):
        ok, code, log, command, wall = mame_run(mame, inputs["konaos"], case_dir / label, "debug-timing", 60, 300,
                                                extra=("-carddir", str(card)), env=dict(env, DEV_BREAKS=breaks), debug=debug)
        logs += f"== {label}\n{log}"
        ok_all, code_all = ok_all and ok, code_all or code
        m = re.search(r"OUT TIMING debug=(\d) breaks=(\d) emulated=([\d.]+) wall=([\d.]+) stops=(\d+)", log)
        if m:
            rows.append({"run": label, "emulated": float(m.group(3)), "wall": float(m.group(4)), "stops": int(m.group(5)),
                         "process_wall": round(wall, 3)})
        else:
            ok_all = False
    if len(rows) == 3:
        base = rows[0]["wall"] / rows[0]["emulated"]
        for r in rows:
            r["wall_per_emulated"] = round(r["wall"] / r["emulated"], 4)
            r["relative"] = round(r["wall_per_emulated"] / base, 3)
        ok_all = ok_all and rows[2]["stops"] == 6 and rows[1]["stops"] == 0
        logs += "TIMING " + json.dumps(rows) + "\n"
    info["timing"] = rows
    return record(probe, ok_all, code_all, logs, None, start, info)


# sdk-run ----------------------------------------------------------------------------

def run_sdk(probe, mame, inputs, case_dir):
    start = time.monotonic()
    tmp = Path(tempfile.mkdtemp(prefix="kos sdk run "))
    log, ok, info = "", True, {"tmp": str(tmp)}
    try:
        sdk = unpack_sdk(inputs["sdk"], tmp / "my sdk")
        # The emulator, the image and the card at paths with spaces.
        bindir = tmp / "emulator bin"
        bindir.mkdir()
        mame_link = bindir / "mame pbitz"
        mame_link.symlink_to(Path(mame).resolve())
        flashdir = tmp / "flash image"
        flashdir.mkdir()
        flash = flashdir / "kona os.bin"
        shutil.copyfile(inputs["konaos"], flash)
        shutil.copyfile(inputs["konaos"].parent / "konaos.map", flashdir / "konaos.map")
        card = tmp / "the card"
        mame_options = "-noreadconfig -video none -sound none -nothrottle -seconds_to_run 120"
        run_vars = [f"KOS_MAME={mame_link}", f"KOS_FLASH={flash}", f"KOS_CARD={card}", "KOS_RUN_EXIT=1"]
        if probe == "run":
            code, out = make(sdk / "template", "run", *run_vars, "KOS_BREAK=main",
                             f"KOS_MAME_ARGS={mame_options} -debug -debugger none")
            log += f"== make run (template, KOS_BREAK=main)\n{out}"
            result = (sdk / "template/build/run/result.txt")
            text = result.read_text() if result.is_file() else ""
            ok = (code == 0 and text.startswith("ran\n") and "hello from a KonaOS program" in text
                  and (card / "HELLO.EXE").is_file()
                  and (card / "HELLO.EXE").read_bytes() == (sdk / "template/build/user/hello.exe").read_bytes()
                  and "breakpoint hello:main" in out and "stopped at hello:_main" in out)
            info.update(result=text, staged=sorted(p.name for p in card.iterdir()) if card.is_dir() else [])
        elif probe == "names":
            notes = sdk / "examples/notes.txt"
            notes.write_text("notes for the files example\n")
            run_vars.append(f"KOS_MAME_ARGS={mame_options}")
            # The example reads argv[1] and lists argv[2].
            code, out = make(sdk / "examples", "run", *run_vars, "KOS_RUN=files",
                             "KOS_RUN_ARGS=files /fs/NOTES.TXT /fs", "KOS_ASSETS=notes.txt hello.c=HELLOSRC.C")
            log += f"== make run KOS_RUN=files\n{out}"
            result = sdk / "examples/build/run/result.txt"
            text = result.read_text() if result.is_file() else ""
            staged = sorted(p.name for p in card.iterdir()) if card.is_dir() else []
            ok = (code == 0 and text.startswith("ran\n") and "files: read 16 bytes of /fs/NOTES.TXT" in text
                  and "HELLOSRC.C" in text and "files: PASS" in text
                  and staged == ["FILES.EXE", "HELLOSRC.C", "NOTES.TXT"])
            code2, out2 = make(sdk / "examples", "run", *run_vars)
            log += f"== make run with several programs and no KOS_RUN\n{out2}"
            ok = ok and code2 != 0 and "choose the program with KOS_RUN=" in out2
            code3, out3 = make(sdk / "examples", "run", *run_vars, "KOS_RUN=files", "KOS_ASSETS=notes.txt=notes-long.txt")
            log += f"== make run with an invalid asset name\n{out3}"
            ok = ok and code3 != 0 and "not a valid 8.3 name" in out3
            info.update(result=text, staged=staged)
        else:
            # An ordinary build with no emulator anywhere: PATH holds none and
            # no variable names one.
            code, out = make(sdk / "template", "clean")
            code, out = make(sdk / "template", env=clean_env("/usr/bin:/bin"))
            log += f"== make (no emulator)\n{out}"
            built = (sdk / "template/build/user/hello.exe").is_file()
            no_mame = shutil.which("mamepbitz", path="/usr/bin:/bin") is None and "mame" not in out.lower()
            ok = code == 0 and built and no_mame
            checks = {
                "binary": (["run", f"KOS_FLASH={flash}", "KOS_MAME=/nonexistent dir/mamepbitz"], "set KOS_MAME"),
                "on PATH": (["run", f"KOS_FLASH={flash}"], "the emulator 'mamepbitz' is not found"),
                "image": (["run", f"KOS_MAME={mame_link}"], "set KOS_FLASH"),
                "plugin": (["run", f"KOS_MAME={mame_link}", f"KOS_FLASH={flash}", f"KOS_MAME_PLUGINS={tmp}"],
                           "konaos MAME plugin is not in"),
            }
            errors = {}
            for name, (args, want) in checks.items():
                c, o = make(sdk / "template", *args)
                log += f"== make {' '.join(args)}\n{o}"
                errors[name] = c
                ok = ok and c != 0 and want in o
            info.update(built=built, errors=errors)
    except Exception as exc:  # a setup failure fails the probe with its reason
        ok = False
        log += f"ERROR {exc}\n"
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    (case_dir / f"{probe}.log").write_text(log)
    return record(probe, ok, 0 if ok else 1, log, None, start, info)


# save-restore -------------------------------------------------------------------------

def card_tree(savework):
    return {"/SAVEWORK.EXE": savework, "/INPUT.BIN": INPUT}


def media_bytes(kind, path):
    """The card's contents as one comparable value."""
    if kind == "image":
        return sha(Path(path).read_bytes())
    tree = fat.folder_tree(path)
    return sha(json.dumps({k: (sha(v) if v is not None else None) for k, v in sorted(tree.items())}).encode())


def parse_final(path):
    lines = Path(path).read_text().split("\n")
    out = {"regs": None, "ports": None, "sound": [], "screen": None}
    for i, line in enumerate(lines):
        if line.startswith("regs "):
            out["regs"] = line[5:]
        elif line.startswith("ports "):
            out["ports"] = line[6:]
        elif line.startswith("sound "):
            out["sound"].append(line[6:])
        elif line == "screen":
            out["screen"] = "\n".join(lines[i + 1:]).rstrip("\n")
            break
    out["vram"] = sha(Path(str(path) + ".vram").read_bytes())
    return out


def parse_after(path):
    out = {}
    for line in Path(path).read_text().splitlines():
        key, _, value = line.partition("\t")
        out[key] = value
    return out


def changed_copy(kind, src, dest):
    """A copy of a saved card with one byte of INPUT.BIN changed."""
    if dest.exists():
        shutil.rmtree(dest) if dest.is_dir() else dest.unlink()
    if kind == "image":
        shutil.copyfile(src, dest)
        v = fat.Volume(dest, write=True)
        try:
            data = bytearray(INPUT)
            data[100] ^= 0xff
            v.write_file("/INPUT.BIN", bytes(data), 1)
        finally:
            v.close()
    else:
        shutil.copytree(src, dest)
        data = bytearray((dest / "INPUT.BIN").read_bytes())
        data[100] ^= 0xff
        (dest / "INPUT.BIN").write_bytes(bytes(data))


def run_save(kind, mame, inputs, case_dir):
    start = time.monotonic()
    sdk = unpack_sdk(inputs["sdk"], case_dir / "sdk tree")
    savework = (build_fixture("savework", sdk).parent / "savework.exe").read_bytes()
    tree = card_tree(savework)
    if kind == "folder":
        media = case_dir / "card"
        if media.exists():
            shutil.rmtree(media)
        card_backends.fill_folder(media, tree)
        media_arg = "-carddir"
    else:
        media = case_dir / "card.img"
        fat.make_image(media, 16, 16, 4)
        card_backends.fill_image(media, tree)
        media_arg = "-card"
    snaps = case_dir / "snaps"
    if snaps.exists():
        shutil.rmtree(snaps)
    snaps.mkdir()
    image = inputs["konaos"]
    log = ""
    ok, code, run_log, command, wall_a = mame_run(
        mame, image, case_dir / "save", "save-run", 60, 300, extra=(media_arg, str(media)),
        env={"DEV_MEDIA": str(media), "DEV_MEDIA_KIND": kind, "DEV_SNAPS": str(snaps)})
    log += "== save-run\n" + run_log
    info = {"media": str(media), "savework_sha256": sha(savework), "points": {}, "loads": {}}
    if not ok:
        return record(kind, False, code, log, command, start, info)
    points = {}
    for line in (case_dir / "save/points.tsv").read_text().splitlines():
        name, t, phase, bulk = line.split("\t")
        points[name] = {"t": float(t), "phase": phase, "bulk": int(bulk)}
    info["points"] = points
    sta = case_dir / "save/sta"
    after_a = parse_after(case_dir / "save/after.tsv")
    final_media = media_bytes(kind, media)
    errors = []
    for name, want_phase in (("idle", ("IDLE",)), ("command", ("WINDOW", "RELEASE", "GUARD", "REPLY")),
                             ("bulk", ("BULK_SEND",)), ("write", ("BULK_RECEIVE",)), ("active", None)):
        if name not in points:
            errors.append(f"{name}: never saved")
            continue
        if want_phase and points[name]["phase"] not in want_phase:
            errors.append(f"{name}: saved in phase {points[name]['phase']}")
    for name in POINTS:
        state = sta / "zephyr80" / f"{name}.sta"
        load_dir = case_dir / f"load-{name}"
        if load_dir.exists():
            shutil.rmtree(load_dir)
        load_dir.mkdir()
        snap = snaps / name / ("card.img" if kind == "image" else "card")
        copy = load_dir / snap.name
        shutil.copytree(snap, copy) if kind == "folder" else shutil.copyfile(snap, copy)
        t0 = time.monotonic()
        ok_b, code_b, log_b, _, wall_b = mame_run(
            mame, image, load_dir / "run", "save-load", 60, 300, extra=(media_arg, str(copy), "-state", name),
            env={"DEV_RESTORE": name}, state_dir=sta)
        log += f"== save-load {name}\n" + log_b
        load = {"state_bytes": state.stat().st_size if state.is_file() else None, "wall": round(wall_b, 3)}
        if not ok_b:
            errors.append(f"{name}: the restored run failed (exit {code_b})")
            info["loads"][name] = load
            continue
        a = parse_final(case_dir / f"save/final-{name}.txt")
        b = parse_final(load_dir / f"run/final-{name}.txt")
        after_b = parse_after(load_dir / "run/after.tsv")
        compare = {
            "line state": (after_a[name], after_b[name]),
            "input state at the save and after the restore": (after_a["input:" + name], after_b["input:" + name]),
            "controller ports at the end": (a["ports"], b["ports"]),
            "end time": (after_a["done"], after_b["done"]),
            "PSG/DAC writes": (a["sound"], b["sound"]),
            "VDP registers": (a["regs"], b["regs"]),
            "VRAM": (a["vram"], b["vram"]),
            "screen": (a["screen"], b["screen"]),
            "card contents": (final_media, media_bytes(kind, copy)),
        }
        for what, (x, y) in compare.items():
            if x != y:
                errors.append(f"{name}: {what} differs: {str(x)[:200]!r} vs {str(y)[:200]!r}")
        load.update(sound_writes=len(b["sound"]), line_state=after_b[name], done=after_b["done"])
        info["loads"][name] = load
    # Refusals: a changed card, and (image) a changed flash image.
    refusals = {}
    snap = snaps / "bulk" / ("card.img" if kind == "image" else "card")
    changed = case_dir / ("changed.img" if kind == "image" else "changed")
    changed_copy(kind, snap, changed)
    tries = [("changed card", image, changed, "card socket: the state was saved with")]
    if kind == "image":
        flash = bytearray(image.read_bytes())
        flash[-1] ^= 0x01
        other = case_dir / "changed-flash.bin"
        other.write_bytes(bytes(flash))
        copy = case_dir / "flash-card.img"
        shutil.copyfile(snap, copy)
        tries.append(("changed flash", other, copy, "the state was saved with other flash contents"))
    for what, flash_image, card, want in tries:
        ok_c, code_c, log_c, _, _ = mame_run(mame, flash_image, case_dir / what.replace(" ", "-"), "save-load", 60, 120,
                                             extra=(media_arg, str(card), "-state", "bulk"), env={"DEV_RESTORE": "bulk"},
                                             state_dir=sta)
        log += f"== {what}\n" + log_c
        refused = code_c not in (0, 124) and want in log_c and "PASS harness" not in log_c
        refusals[what] = {"exit": code_c, "message": next((l for l in log_c.splitlines() if want in l), None)}
        if not refused:
            errors.append(f"{what}: not refused (exit {code_c})")
    info["refusals"] = refusals
    info["errors"] = errors
    log += "".join(f"VERIFY FAIL {e}\n" for e in errors) or "VERIFY every restored run matched the saving run; changed media refused\n"
    (case_dir / "save-restore.json").write_text(json.dumps(info, indent=2) + "\n")
    return record(kind, ok and not errors, code, log, command, start, info)


def run(case, mame, inputs, output, cases=None):
    output.mkdir(parents=True, exist_ok=True)
    results = []
    for probe in cases or PROBES[case]:
        case_dir = output / probe
        if case_dir.exists():
            shutil.rmtree(case_dir)
        case_dir.mkdir(parents=True)
        try:
            if case == "debug-symbols":
                r = run_debug(probe, mame, inputs, case_dir)
            elif case == "sdk-run":
                r = run_sdk(probe, mame, inputs, case_dir)
            else:
                r = run_save(probe, mame, inputs, case_dir)
        except Exception as exc:
            r = {"case": probe, "pass": False, "exit": 1, "wall_seconds": 0, "log": f"ERROR {exc}\n", "command": None}
        log_path = case_dir / "probe.log"
        log_path.write_text(r.pop("log"))
        r["log"] = str(log_path)
        results.append(r)
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    return results
