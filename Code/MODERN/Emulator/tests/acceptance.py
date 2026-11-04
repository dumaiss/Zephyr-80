"""Acceptance cases of tests/run.py that the device cases do not hold: `hwtest`, `zsdos-drives`,
`zexdoc` and `zexall`.

`hwtest`: the production KonaOS image with a writable card (probes `image`, a FAT16 image, and
  `folder`, a host folder); `hwtest` typed on the USB keyboard at the shell; its stage lines and
  the verdict `hwtest: 4/4 PASS` read off the V9958 console and off the serial lane it mirrors
  them to (acceptance.lua).  Its file stage writes inside /fs/HWTEST and removes it, so after
  MAME exits the card must hold exactly what it held before (and fsck clean for the image).
`zsdos-drives`: ZSDOS's B: (the card's /CPM/B through FS2) and C: (the mounted CPM_1.DRV volume)
  written and read through BDOS, on an image and a folder.  Run 1: SDGET writes B:NOTE.TXT from
  /SHARED, MCOPY C:=B:NOTE.TXT reads B: and writes C: (with its verify).  The card is checked
  after MAME exits, then run 2, a new MAME on the same card: SDPUT reads B:NOTE.TXT back into
  /SHARED and MCOPY D:=C:NOTE.TXT reads C: back; the card is checked again.  One MCOPY per run,
  last (after MCOPY ends the next program loaded from /SYSTEM/A does not start; a guest-side
  fault, see card_backends.zsdos_steps).
`zexdoc`, `zexall`: a CP/M instruction exerciser on ZSDOS, loaded from B:, bounded by emulated
  time; every one of its 67 tests must print OK, none ERROR, and the program must print
  `Tests complete` and return to the shell.  `zexdoc` is Frank D. Cringle's ZEXDOC.COM
  (documented flags); `zexall` is the ZEXALL binary MAME's source carries in
  mame/src/zexall/zexall.h (all flags), extracted here."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import time

import card_backends as cb
import fat_fixture as fat
import guest_font
import mame_args

HERE = Path(__file__).resolve().parent
PROBES = {
    "hwtest": ("image", "folder"),
    "zsdos-drives": ("image", "folder"),
    "zexdoc": ("run",),
    "zexall": ("run",),
}

EXERCISER_TESTS = 67
EXERCISER_DEADLINE = 9000     # emulated seconds
EXERCISER_WALL = 5400         # host seconds


def sha(data):
    return hashlib.sha256(data).hexdigest()


def card(case_dir, kind, tree, mib=16, cluster=4):
    """A disposable card of `kind` (image or folder) holding `tree`: (path, MAME options)."""
    if kind == "folder":
        root = case_dir / "card"
        if root.exists():
            shutil.rmtree(root)
        cb.fill_folder(root, tree)
        return root, ["-carddir", str(root)]
    image = case_dir / "card.img"
    fat.make_image(image, mib, 16, cluster)
    cb.fill_image(image, tree)
    return image, ["-card", str(image)]


def read_card(media, kind):
    return fat.folder_tree(media) if kind == "folder" else cb.image_tree(media)


def fsck_errors(media, kind, notes):
    if kind == "folder":
        return []
    ok, out = fat.fsck(media)
    notes.append("fsck: " + out.strip().splitlines()[-1])
    return [] if ok else ["fsck: " + out.strip()]


# hwtest ----------------------------------------------------------------------

HWTEST_TREE = {"/NOTE.TXT": b"a file the exerciser must leave alone\n", "/DOCS/": None,
               "/DOCS/A.TXT": cb.pattern(1500, 5)}


def mame_konaos(mame, image, case_dir, body, media_args, deadline, wall):
    """The production image with the serial pty (the lane hwtest mirrors to), the guest font and the card."""
    import run as runner
    case_dir.mkdir(parents=True, exist_ok=True)
    command = [str(mame.resolve()), "zephyr80", "-noreadconfig", "-skip_gameinfo", "-video", "none", "-sound", "none",
               "-nothrottle", "-seconds_to_run", str(deadline + 2),
               "-cfg_directory", str(case_dir / "cfg"), "-nvram_directory", str(case_dir / "nvram"),
               "-state_directory", str(case_dir / "sta"), "-snapshot_directory", str(case_dir / "snap"),
               "-flash", str(image), "-autoboot_script", str(HERE / "harness.lua"), "-autoboot_delay", "0",
               "-sio0b_rs232", "pty", *mame_args.EXTRA, *media_args]
    font = guest_font.write("konaos", Path(image), case_dir / "font.bin")
    environment = {"HARNESS_CASE": body, "HARNESS_SCRIPT": str(HERE / "acceptance.lua"), "HARNESS_DIR": str(case_dir),
                   "HARNESS_DEADLINE": str(deadline), "HARNESS_TTY_FILE": str(case_dir / "serial.tty"),
                   "HARNESS_FONT": str(case_dir / "font.bin")}
    manifest = {"body": body, "command": command, "environment": environment, "font": font,
                "flash": {"path": str(image), "sha256": sha(Path(image).read_bytes())},
                "limits": {"emulated_seconds": deadline, "wall_seconds": wall}}
    (case_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    start = time.monotonic()
    code, log, _ = runner.launch(command, dict(os.environ, **environment), wall, case_dir, {"pty": True}, "")
    log += f"RUN wall {time.monotonic() - start:.3f} s\n"
    (case_dir / "mame.log").write_text(log)
    verdicts = [line for line in log.splitlines() if re.match(rf"(PASS|FAIL) harness {re.escape(body)}: ", line)]
    return code == 0 and len(verdicts) == 1 and verdicts[0].startswith("PASS"), code, log, command


def run_hwtest(mame, inputs, case_dir, kind):
    media, args = card(case_dir, kind, HWTEST_TREE)
    before = read_card(media, kind)
    ok, code, log, command = mame_konaos(mame, inputs["konaos"], case_dir / "run", "hwtest", args, 240, 400)
    notes = []
    found = read_card(media, kind)
    errors = cb.compare_tree(found, before, "card after hwtest (its file stage must leave no trace)")
    errors += fsck_errors(media, kind, notes)
    log += "".join(f"VERIFY {n}\n" for n in notes) + ("".join(f"VERIFY FAIL {e}\n" for e in errors) or
                                                      "VERIFY the card holds exactly what it held before hwtest\n")
    transcript = case_dir / "run" / "transcript.txt"
    info = {"media": str(media), "hwtest_sha256": sha(inputs["hwtest"].read_bytes()),
            "console": transcript.read_text(encoding="latin-1").splitlines() if transcript.is_file() else [], "errors": errors}
    return ok and not errors, code, log, command, info


# ZSDOS drives ----------------------------------------------------------------

def mcopy(src, dst, name):
    base, ext = name.split(".")
    return (f"MCOPY {dst}:={src}:{name}",
            [f"Copy {src}  0: {base:<8}.{ext:<3} to {dst}  0:", "Verify Complete", "1 File Copied     0 Copy Errors"])


DRIVES_RUN1 = [
    ("cd /SYSTEM/A", []),
    ("SDGET NOTE.TXT", ["SDGET: 300 bytes", "done"]),
    ("ls", ["NOTE.TXT"]),
    ("cd /SYSTEM/A", []),
    mcopy("B", "C", "NOTE.TXT"),
]
DRIVES_RUN2 = [
    ("cd /SYSTEM/A", []),
    ("SDPUT NOTE.TXT", ["SDPUT: ", "384 bytes"]),
    ("cd /SYSTEM/A", []),
    mcopy("C", "D", "NOTE.TXT"),
]


def run_drives(mame, inputs, case_dir, kind):
    case_dir.mkdir(parents=True, exist_ok=True)
    text = b"".join(b"Line %03d of the C: volume test file.\r\n" % i for i in range(60)) + b"\x1a"
    note = cb.pattern(300, 9)
    c_volume = cb.cpm_volume([("HELLO.TXT", text)])
    tree = {"/CPM/": None, "/CPM/B/": None, "/SHARED/": None, "/SHARED/NOTE.TXT": note,
            "/CPM/CPM_1.DRV": c_volume, "/CPM/CPM_2.DRV": cb.cpm_volume()}
    media, args = card(case_dir, kind, tree, mib=24, cluster=8)
    errors, notes = [], []

    ok1, code1, log1, command, traces1 = cb.mame_run(mame, inputs["zsdos"], case_dir / "run1", "card-zsdos", args,
                                                    120, 300, DRIVES_RUN1, "$ ")
    found = read_card(media, kind)
    errors += fsck_errors(media, kind, notes)
    b_note = found.get("/CPM/B/NOTE.TXT")
    if b_note is None or len(b_note) != 384 or b_note[:300] != note:
        errors.append(f"run 1: B:NOTE.TXT (/CPM/B/NOTE.TXT) is not /SHARED/NOTE.TXT in three records "
                      f"({len(b_note or b'')} bytes)")
    c_after = found.get("/CPM/CPM_1.DRV") or b""
    c_note = cb.cpm_file(c_after, "NOTE.TXT")
    if c_note is None:
        errors.append("run 1: C:NOTE.TXT is not in CPM_1.DRV's directory")
    elif c_note != b_note:
        errors.append(f"run 1: C:NOTE.TXT ({len(c_note)} bytes) differs from B:NOTE.TXT")
    if cb.cpm_file(c_after, "HELLO.TXT") != cb.cpm_file(c_volume, "HELLO.TXT"):
        errors.append("run 1: C:HELLO.TXT changed")
    if found.get("/CPM/CPM_2.DRV") != tree["/CPM/CPM_2.DRV"]:
        errors.append("run 1: D: (CPM_2.DRV) changed")
    if found.get("/SHARED/NOTE.TXT") != note:
        errors.append("run 1: /SHARED/NOTE.TXT changed")
    if not errors:
        notes.append("run 1: B:NOTE.TXT holds /SHARED/NOTE.TXT in 3 records; C:NOTE.TXT equals it record for record "
                     "in CPM_1.DRV's own directory; C:HELLO.TXT, D: and /SHARED unchanged")
    after1 = dict(found)

    ok2, code2, log2, _, traces2 = cb.mame_run(mame, inputs["zsdos"], case_dir / "run2", "card-zsdos", args,
                                              120, 300, DRIVES_RUN2, "$ ")
    found = read_card(media, kind)
    errors += fsck_errors(media, kind, notes)
    shared = found.get("/SHARED/NOTE.TXT")
    if shared != b_note:
        errors.append(f"run 2: /SHARED/NOTE.TXT ({len(shared or b'')} bytes) is not B:NOTE.TXT as SDPUT read it back")
    d_note = cb.cpm_file(found.get("/CPM/CPM_2.DRV") or b"", "NOTE.TXT")
    if d_note is None:
        errors.append("run 2: D:NOTE.TXT is not in CPM_2.DRV's directory")
    elif d_note != c_note:
        errors.append(f"run 2: D:NOTE.TXT ({len(d_note)} bytes) differs from C:NOTE.TXT")
    for path in ("/CPM/CPM_1.DRV", "/CPM/B/NOTE.TXT"):
        if found.get(path) != after1.get(path):
            errors.append(f"run 2: {path} changed")
    if len(notes) >= 2 and not any(e.startswith("run 2") for e in errors):
        notes.append("run 2 (a new MAME on the same card): /SHARED/NOTE.TXT is B:NOTE.TXT's 384 bytes as SDPUT read "
                     "them; D:NOTE.TXT equals C:NOTE.TXT; C: and B: unchanged")
    log = "== run 1\n" + log1 + "== run 2 (the same card, a new MAME)\n" + log2
    log += "".join(f"VERIFY {n}\n" for n in notes) + "".join(f"VERIFY FAIL {e}\n" for e in errors)
    info = {"media": str(media), "traces": traces1 + traces2, "verify": notes, "errors": errors,
            "note_sha256": sha(b_note or b""), "media_sha256": None if kind == "folder" else sha(media.read_bytes())}
    return ok1 and ok2 and not errors, code1 or code2, log, command, info


# CPU exercisers --------------------------------------------------------------

def zexall_binary(header):
    """The CP/M binary in mame/src/zexall/zexall.h's `zexall_binary[...]` array."""
    text = re.sub(r"//[^\n]*", "", Path(header).read_text())
    size = int(re.search(r"zexall_binary\[(0x[0-9a-fA-F]+)\]", text).group(1), 16)
    data = bytes(int(x, 16) for x in re.findall(r"0x([0-9a-fA-F]{2})", text.split("{", 1)[1].split("}", 1)[0]))
    if len(data) != size:
        raise ValueError(f"{header}: {len(data)} bytes, the array says {size}")
    return data


def run_exerciser(mame, inputs, case_dir, name):
    case_dir.mkdir(parents=True, exist_ok=True)
    if name == "zexall":
        program = zexall_binary(inputs["zexall"])
        provenance = {"source": str(inputs["zexall"]), "source_sha256": sha(Path(inputs["zexall"]).read_bytes())}
    else:
        program = Path(inputs["zexdoc"]).read_bytes()
        provenance = {"source": str(inputs["zexdoc"])}
    command_name = name.upper()
    provenance.update({"card_path": f"/CPM/B/{command_name}.COM", "bytes": len(program), "sha256": sha(program)})
    (case_dir / f"{command_name}.COM").write_bytes(program)
    tree = {"/CPM/": None, "/CPM/B/": None, f"/CPM/B/{command_name}.COM": program}
    media, args = card(case_dir, "folder", tree)
    steps = [(command_name, ["Z80", "instruction exerciser", "Tests complete"])]
    os.environ["HARNESS_STEP_TIMEOUT"] = str(EXERCISER_DEADLINE - 30)
    try:
        ok, code, log, command, traces = cb.mame_run(mame, inputs["zsdos"], case_dir / "run", "card-zsdos", args,
                                                    EXERCISER_DEADLINE, EXERCISER_WALL, steps, "$ ")
    finally:
        del os.environ["HARNESS_STEP_TIMEOUT"]
    serial = case_dir / "run" / "serial.bin"
    transcript = serial.read_bytes().decode("latin-1") if serial.is_file() else ""
    start = transcript.find("instruction exerciser")
    body = transcript[transcript.rfind("\n", 0, start) + 1:] if start >= 0 else ""
    oks = len(re.findall(r"  OK\r?\n", body))
    failures = re.findall(r"[^\r\n]*ERROR \*\*\*\*[^\r\n]*", body)
    errors = []
    if start < 0:
        errors.append("the exerciser's banner is not in the serial transcript")
    if oks != EXERCISER_TESTS:
        errors.append(f"{oks} of {EXERCISER_TESTS} tests printed OK")
    if failures:
        errors.append(f"{len(failures)} tests printed ERROR: " + "; ".join(failures[:5]))
    if "Tests complete" not in body:
        errors.append("no `Tests complete`")
    lines = [line for line in body.replace("\r", "").split("\n") if line.strip()]
    (case_dir / "exerciser.txt").write_text("\n".join(lines) + "\n")
    elapsed = [float(m.group(1)) for line in traces if (m := re.search(r'step "' + command_name + r'" ([0-9.]+) s', line))]
    log += "".join(f"VERIFY FAIL {e}\n" for e in errors) or f"VERIFY {oks}/{EXERCISER_TESTS} tests OK, no ERROR, Tests complete\n"
    info = {"program": provenance, "tests_ok": oks, "errors": errors, "failures": failures,
            "exerciser_emulated_seconds": elapsed[0] if elapsed else None, "traces": traces, "transcript": lines}
    return ok and not errors, code, log, command, info


def run(case, mame, inputs, output, cases=None):
    output.mkdir(parents=True, exist_ok=True)
    results = []
    for probe in cases or PROBES[case]:
        case_dir = output / probe
        if case_dir.exists():
            cb.writable(case_dir)
            shutil.rmtree(case_dir)
        start = time.monotonic()
        if case == "hwtest":
            ok, code, log, command, info = run_hwtest(mame, inputs, case_dir, probe)
        elif case == "zsdos-drives":
            ok, code, log, command, info = run_drives(mame, inputs, case_dir, probe)
        else:
            ok, code, log, command, info = run_exerciser(mame, inputs, case_dir, case)
        wall = time.monotonic() - start
        (output / f"{probe}.log").write_text(log)
        lines = log.splitlines()
        emulated = [float(m) for m in re.findall(r"^TRACE emulated ([0-9.]+) s", log, re.M)]
        results.append({"case": probe, "pass": ok, "exit": code, "wall_seconds": round(wall, 3),
                        "emulated_seconds": round(sum(emulated), 6) if emulated else None,
                        "verdict": " / ".join(line for line in lines if re.match(r"(PASS|FAIL)( harness)? ", line)) or None,
                        "traces": [line for line in lines if line.startswith(("TRACE ", "VERIFY", "RUN wall", "Average speed"))],
                        "diagnostics": [line for line in lines if line.startswith("DIAG ")],
                        "log": str(output / f"{probe}.log"), "command": command, **info})
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    return results
