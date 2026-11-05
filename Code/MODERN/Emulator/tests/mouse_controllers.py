"""Mouse and controller cases of tests/run.py: `mouse-controllers`.

  host         builds tests/controllers/controllers_test.cpp with the HID module and the protocol core
               and runs it: the mouse's report decode, accumulation, saturation and take/clear, the
               F310 report to latch bytes, the keyboard's keypad mirror, pad slots and HID_STATUS pages 6
               and 7, every expected byte from the firmware source.
  mouse        the probe program (sio1_lanes.asm) on the real SIO1/B lane, MAME mouse input through
               the USB mouse device: HID_MOUSE replies, both directions, wheel, saturation, clicks
               between reads, held buttons, keyboard beside the mouse, removal, reset
               (mouse_controllers.lua mouse-lane).
  controllers  the same program reading E0h-FFh with IN: gamepad bytes from MAME input, two pads,
               keypad priority and overlap, the keyboard's digits, mirrors, sound writes beside the
               reads, mode-select writes, removal, mount order, reset (controllers-lane).
  state        a state saved with motion owed, a click unread, pads held and a keypad key held,
               restored in a second process (mouse-state-save, mouse-state-load).
  shell        the production KonaOS image's own `mouse` and `joy` programs on the V9958 console,
               driven by MAME mouse and pad input; the pointer sprite read from VRAM.
  apps         KonaEdit and KonaCommander from a card image, driven by the mouse; the pointer
               without a mouse attached.
  gfx          the libgfx pointer example (gfx_mouse) from a card image.

The manifests and input logs are those of keyboard.py (mame_run)."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import time

import card_backends
import fat_fixture as fat
import keyboard

HERE = Path(__file__).resolve().parent
EMULATOR = HERE.parent
PBITZ = EMULATOR / "mame/src/mame/pbitz"
SCRIPT = "mouse_controllers.lua"
PROBES = {"mouse-controllers": ("host", "mouse", "controllers", "latency", "state", "shell", "apps", "gfx")}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def run_host(case_dir):
    case_dir.mkdir(parents=True, exist_ok=True)
    binary = case_dir / "controllers_test"
    build = ["c++", "-std=c++17", "-O1", "-g", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function",
             "-I", str(HERE / "ioc_core"), "-I", str(EMULATOR / "mame/src/osd"), "-I", str(PBITZ),
             str(HERE / "controllers/controllers_test.cpp"), str(PBITZ / "zephyr80_ioc_core.cpp"),
             str(PBITZ / "zephyr80_ioc_hid.cpp"), "-o", str(binary)]
    built = subprocess.run(build, capture_output=True, text=True)
    log = "$ " + " ".join(build) + "\n" + built.stdout + built.stderr
    if built.returncode:
        return False, built.returncode, log, build, {}
    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=120)
    log += f"$ {binary}\n" + result.stdout + result.stderr
    verdict = re.search(r"^RESULT (\d+) passed, (\d+) failed", result.stdout, re.M)
    return result.returncode == 0 and verdict is not None and verdict.group(2) == "0", result.returncode, log, build, {}


def run_lane(mame, case_dir, body, deadline=60, wall=240):
    import sio1_lanes
    image = sio1_lanes.assemble(case_dir)
    ok, code, log, command = keyboard.mame_run(mame, image, case_dir / "run", body, deadline, wall, script=SCRIPT)
    return ok, code, log, command, {"probe_image": str(image), "probe_sha256": sha(image.read_bytes())}


def run_state(mame, case_dir):
    import sio1_lanes
    image = sio1_lanes.assemble(case_dir)
    state_file = case_dir / "mc-state.tsv"
    env = {"HARNESS_STATE_FILE": str(state_file)}
    ok, code, log, command = keyboard.mame_run(mame, image, case_dir / "save", "mouse-state-save", 8, 60, env=env, script=SCRIPT)
    log = "== save\n" + log
    if ok:
        saved_dir = case_dir / "save" / "sta"
        ok2, code2, more, _ = keyboard.mame_run(mame, image, case_dir / "load", "mouse-state-load", 8, 60, extra=("-state", "mc"),
                                                env=env, state_dir=saved_dir, script=SCRIPT)
        log += "== load\n" + more
        ok, code = ok and ok2, code or code2
    return ok, code, log, command, {"probe_sha256": sha(image.read_bytes())}


def run_shell(mame, inputs, case_dir):
    """The store's `mouse` and `joy` on the production image, no card."""
    ok, code, log, command = keyboard.mame_run(mame, inputs["konaos"], case_dir / "run", "clients-shell", 90, 300,
                                               font="konaos", script=SCRIPT)
    return ok, code, log, command, {}


LONG = b"".join(b"line %02d\n" % n for n in range(1, 61))


def app_tree(kedit, kc):
    tree = keyboard.app_tree(kedit, kc)
    tree["/LONG.TXT"] = LONG
    return tree


def run_apps(mame, inputs, case_dir):
    """KonaEdit and KonaCommander from a disposable FAT16 image, driven by the mouse; the card is unchanged after."""
    tree = app_tree(inputs["kedit"].read_bytes(), inputs["kc"].read_bytes())
    case_dir.mkdir(parents=True, exist_ok=True)
    media = case_dir / "card.img"
    fat.make_image(media, 16, 16, 4)
    card_backends.fill_image(media, tree)
    before = sha(media.read_bytes())
    ok, code, log, command = keyboard.mame_run(mame, inputs["konaos"], case_dir / "run", "clients-apps", 200, 500,
                                               extra=["-card", str(media)], font="konaos", script=SCRIPT)
    errors = card_backends.compare_tree(card_backends.image_tree(media), tree, "card after the mouse sessions")
    fsck_ok, out = fat.fsck(media)
    log += "VERIFY fsck: " + out.strip().splitlines()[-1] + "\n"
    if not fsck_ok:
        errors.append("fsck: " + out.strip())
    log += "".join(f"VERIFY FAIL {e}\n" for e in errors) or "VERIFY the card holds exactly what it held before; nothing was saved\n"
    info = {"media": str(media), "card_sha256_before": before, "card_sha256_after": sha(media.read_bytes()),
            "kedit_sha256": sha(tree["/BIN/KEDIT.EXE"]), "kc_sha256": sha(tree["/BIN/KC.EXE"]), "errors": errors}
    return ok and not errors, code, log, command, info


def run_gfx(mame, inputs, case_dir):
    """The libgfx pointer example from a disposable FAT16 image (the card name GFXMOUSE.EXE: 8.3)."""
    tree = {"/BIN/": None, "/BIN/GFXMOUSE.EXE": inputs["gfxmouse"].read_bytes()}
    case_dir.mkdir(parents=True, exist_ok=True)
    media = case_dir / "card.img"
    fat.make_image(media, 16, 16, 4)
    card_backends.fill_image(media, tree)
    ok, code, log, command = keyboard.mame_run(mame, inputs["konaos"], case_dir / "run", "clients-gfx", 120, 400,
                                               extra=["-card", str(media)], font="konaos", script=SCRIPT)
    return ok, code, log, command, {"media": str(media), "gfxmouse_sha256": sha(tree["/BIN/GFXMOUSE.EXE"])}


def run(case, mame, inputs, output, cases=None):
    output.mkdir(parents=True, exist_ok=True)
    results = []
    for probe in cases or PROBES[case]:
        case_dir = output / probe
        if case_dir.exists():
            shutil.rmtree(case_dir)
        start = time.monotonic()
        if probe == "host":
            ok, code, log, command, info = run_host(case_dir)
        elif probe == "mouse":
            ok, code, log, command, info = run_lane(mame, case_dir, "mouse-lane")
        elif probe == "controllers":
            ok, code, log, command, info = run_lane(mame, case_dir, "controllers-lane")
        elif probe == "latency":
            ok, code, log, command, info = run_lane(mame, case_dir, "input-latency")
        elif probe == "gfx":
            ok, code, log, command, info = run_gfx(mame, inputs, case_dir)
        elif probe == "apps":
            ok, code, log, command, info = run_apps(mame, inputs, case_dir)
        elif probe == "shell":
            ok, code, log, command, info = run_shell(mame, inputs, case_dir)
        elif probe == "state":
            ok, code, log, command, info = run_state(mame, case_dir)
        else:
            raise SystemExit(f"mouse-controllers: no probe {probe}")
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
