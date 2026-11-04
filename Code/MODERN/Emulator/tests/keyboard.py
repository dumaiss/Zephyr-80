"""Keyboard cases of tests/run.py: `keyboard`, `konaos-video-boot`, `zsdos-boot`, `terminal-apps`.

`keyboard`:
  host    builds tests/keyboard/hid_test.cpp with the IO controller's HID module
          (mame/src/mame/pbitz/zephyr80_ioc_hid.cpp) and the protocol core, and runs it:
          the firmware's translation, report edges, locks, repeat, queue and HID_STATUS.
  lane    the probe program (sio1_lanes.asm) on the real SIO1/B lane, keys pressed through
          MAME's input path: HID_INPUT bytes, partial dequeue, /CTSB, repeat, overflow,
          machine reset, Ctrl+Alt+Esc (keyboard.lua kbd-lane).
  state   a state saved with keys queued and one held mid-repeat, restored twice: with the
          key held (the same bytes as the continuous run) and released (no stuck repeat).
`konaos-video-boot`: the production KonaOS image to its shell on the V9958/HID console, typed
  commands and their answers read off the GRAPHIC6 screen (keyboard.lua konaos-shell).
`zsdos-boot`: ZSDOS to ZephyrShell's prompt on its V9958/HID console, two commands.
`terminal-apps`: KonaEdit and KonaCommander loaded from a card image and a card folder,
  driven by keys; the edited file read back from the card.

Every MAME run gets the guest's console font from its flash image (guest_font.py), a
manifest (command, environment, font provenance, media) and the input log the harness
writes (inputs.tsv)."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

import card_backends
import fat_fixture as fat
import guest_font
import mame_args

HERE = Path(__file__).resolve().parent
EMULATOR = HERE.parent
PBITZ = EMULATOR / "mame/src/mame/pbitz"
PROBES = {
    "keyboard": ("host", "lane", "state"),
    "konaos-video-boot": ("shell",),
    "zsdos-boot": ("shell",),
    "terminal-apps": ("image", "folder"),
}

NOTE = b"line one\nline two\n"
NOTE_EDITED = b"line one\nline twoXY\nnew\n"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def mame_run(mame, image, case_dir, body, deadline, wall, extra=(), font=None, env=None, state_dir=None):
    """One MAME process running keyboard.lua's `body`; returns (ok, exit code, log, command)."""
    case_dir.mkdir(parents=True, exist_ok=True)
    command = [str(mame.resolve()), "zephyr80", "-noreadconfig", "-skip_gameinfo", "-video", "none", "-sound", "none",
               "-nothrottle", "-seconds_to_run", str(deadline + 2),
               "-cfg_directory", str(case_dir / "cfg"), "-nvram_directory", str(case_dir / "nvram"),
               "-state_directory", str(state_dir or case_dir / "sta"), "-snapshot_directory", str(case_dir / "snap"),
               "-flash", str(image), "-autoboot_script", str(HERE / "harness.lua"), "-autoboot_delay", "0",
               *mame_args.EXTRA, *extra]
    environment = dict(os.environ, HARNESS_CASE=body, HARNESS_SCRIPT=str(HERE / "keyboard.lua"),
                       HARNESS_DIR=str(case_dir), HARNESS_DEADLINE=str(deadline), **(env or {}))
    manifest = {"body": body, "command": command, "flash": {"path": str(image), "sha256": sha(Path(image).read_bytes())},
                "limits": {"emulated_seconds": deadline, "wall_seconds": wall}}
    if font:
        manifest["font"] = guest_font.write(font, Path(image), case_dir / "font.bin")
        environment["HARNESS_FONT"] = str(case_dir / "font.bin")
    manifest["environment"] = {k: v for k, v in environment.items() if k.startswith("HARNESS_")}
    (case_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    start = time.monotonic()
    try:
        result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=wall)
        code, log = result.returncode, result.stdout + result.stderr
    except subprocess.TimeoutExpired as exc:
        code = 124
        log = (exc.stdout or b"").decode(errors="replace") + f"\nWALL TIMEOUT after {wall} seconds\n"
    log += f"RUN wall {time.monotonic() - start:.3f} s\n"
    (case_dir / "mame.log").write_text(log)
    verdicts = [line for line in log.splitlines() if re.match(rf"(PASS|FAIL) harness {re.escape(body)}: ", line)]
    return code == 0 and len(verdicts) == 1 and verdicts[0].startswith("PASS"), code, log, command


def run_host(case_dir):
    case_dir.mkdir(parents=True, exist_ok=True)
    binary = case_dir / "hid_test"
    build = ["c++", "-std=c++17", "-O1", "-g", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function",
             "-I", str(HERE / "ioc_core"), "-I", str(EMULATOR / "mame/src/osd"), "-I", str(PBITZ),
             str(HERE / "keyboard/hid_test.cpp"), str(PBITZ / "zephyr80_ioc_core.cpp"), str(PBITZ / "zephyr80_ioc_hid.cpp"),
             "-o", str(binary)]
    built = subprocess.run(build, capture_output=True, text=True)
    log = "$ " + " ".join(build) + "\n" + built.stdout + built.stderr
    if built.returncode:
        return False, built.returncode, log, build, {}
    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=120)
    log += f"$ {binary}\n" + result.stdout + result.stderr
    verdict = re.search(r"^RESULT (\d+) passed, (\d+) failed", result.stdout, re.M)
    return result.returncode == 0 and verdict is not None and verdict.group(2) == "0", result.returncode, log, build, {}


def run_lanes(mame, case_dir):
    import sio1_lanes
    image = sio1_lanes.assemble(case_dir)
    ok, code, log, command = mame_run(mame, image, case_dir / "run", "kbd-lane", 40, 180)
    return ok, code, log, command, {"probe_image": str(image), "probe_sha256": sha(image.read_bytes())}


def run_state(mame, case_dir):
    import sio1_lanes
    image = sio1_lanes.assemble(case_dir)
    state_file = case_dir / "kbd-state.tsv"
    env = {"HARNESS_STATE_FILE": str(state_file)}
    ok, code, log, command = mame_run(mame, image, case_dir / "save", "kbd-state-save", 5, 60, env=env)
    log = "== save\n" + log
    if ok:
        saved_dir = case_dir / "save" / "sta"
        for body, sub in (("kbd-state-load", "load"), ("kbd-state-release", "release")):
            ok2, code2, more, _ = mame_run(mame, image, case_dir / sub, body, 6, 60, extra=("-state", "kbd"), env=env,
                                           state_dir=saved_dir)
            log += f"== {sub}\n" + more
            ok, code = ok and ok2, code or code2
    return ok, code, log, command, {"probe_sha256": sha(image.read_bytes())}


def run_shell(mame, image, case_dir, body, guest, deadline, media_args=(), media=None):
    ok, code, log, command = mame_run(mame, image, case_dir / "run", body, deadline, 300, extra=media_args, font=guest)
    return ok, code, log, command, {"media": media}


def app_tree(kedit, kc):
    return {"/BIN/": None, "/BIN/KEDIT.EXE": kedit, "/BIN/KC.EXE": kc, "/NOTE.TXT": NOTE,
            "/DOCS/": None, "/DOCS/A.TXT": b"alpha\n"}


def run_apps(mame, inputs, case_dir, kind):
    """KonaEdit and KonaCommander from a disposable card of `kind` (image or folder)."""
    tree = app_tree(inputs["kedit"].read_bytes(), inputs["kc"].read_bytes())
    case_dir.mkdir(parents=True, exist_ok=True)
    if kind == "folder":
        media = case_dir / "card"
        if media.exists():
            shutil.rmtree(media)
        card_backends.fill_folder(media, tree)
        args = ["-carddir", str(media)]
    else:
        media = case_dir / "card.img"
        fat.make_image(media, 16, 16, 4)
        card_backends.fill_image(media, tree)
        args = ["-card", str(media)]
    ok, code, log, command = mame_run(mame, inputs["konaos"], case_dir / "run", "terminal-apps", 150, 400, extra=args,
                                      font="konaos")
    want = dict(tree)
    want["/NOTE.TXT"] = NOTE_EDITED
    found = fat.folder_tree(media) if kind == "folder" else card_backends.image_tree(media)
    errors = card_backends.compare_tree(found, want, "card after KonaEdit and KonaCommander")
    if kind == "image":
        fsck_ok, out = fat.fsck(media)
        log += "VERIFY fsck: " + out.strip().splitlines()[-1] + "\n"
        if not fsck_ok:
            errors.append("fsck: " + out.strip())
    log += "".join(f"VERIFY FAIL {e}\n" for e in errors) or "VERIFY NOTE.TXT on the card is KonaEdit's saved text; nothing else changed\n"
    info = {"media": str(media), "kedit_sha256": sha(tree["/BIN/KEDIT.EXE"]), "kc_sha256": sha(tree["/BIN/KC.EXE"]),
            "note_after": (found.get("/NOTE.TXT") or b"").decode("latin-1"), "errors": errors}
    return ok and not errors, code, log, command, info


def zsdos_card(case_dir):
    """ZephyrShell's B: is the card's /CPM/B (an FS2 directory): without it ZSDOS stops at
    'ZSDOS error on B: No Drive' before its prompt, with or without a keyboard."""
    root = case_dir / "card"
    if root.exists():
        shutil.rmtree(root)
    card_backends.fill_folder(root, {"/CPM/": None, "/CPM/B/": None})
    return root


def run(case, mame, inputs, output, cases=None):
    output.mkdir(parents=True, exist_ok=True)
    results = []
    for probe in cases or PROBES[case]:
        case_dir = output / probe
        if case_dir.exists():
            shutil.rmtree(case_dir)
        start = time.monotonic()
        if case == "keyboard":
            ok, code, log, command, info = {"host": lambda: run_host(case_dir), "lane": lambda: run_lanes(mame, case_dir),
                                            "state": lambda: run_state(mame, case_dir)}[probe]()
        elif case == "konaos-video-boot":
            ok, code, log, command, info = run_shell(mame, inputs["konaos"], case_dir, "konaos-shell", "konaos", 60)
        elif case == "zsdos-boot":
            card = zsdos_card(case_dir)
            ok, code, log, command, info = run_shell(mame, inputs["zsdos"], case_dir, "zsdos-shell", "zsdos", 40,
                                                     ("-carddir", str(card)), str(card))
        else:
            ok, code, log, command, info = run_apps(mame, inputs, case_dir, probe)
        wall = time.monotonic() - start
        (output / f"{probe}.log").write_text(log)
        lines = log.splitlines()
        emulated = [float(m) for m in re.findall(r"^TRACE emulated ([0-9.]+) s", log, re.M)]
        results.append({"case": probe, "pass": ok, "exit": code, "wall_seconds": round(wall, 3),
                        "emulated_seconds": round(sum(emulated), 6) if emulated else None,
                        "verdict": " / ".join(line for line in lines if re.match(r"(PASS|FAIL|RESULT)( harness)? ", line)) or None,
                        "traces": [line for line in lines if line.startswith(("TRACE ", "VERIFY", "RUN wall", "Average speed"))],
                        "diagnostics": [line for line in lines if line.startswith("DIAG ")],
                        "log": str(output / f"{probe}.log"), "command": command, **info})
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    return results
