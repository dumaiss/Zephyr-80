"""Card socket probes: the `card-image`, `card-directory` and `cpm-volumes` cases.

`host` builds tests/card/card_test.cpp with the protocol core and the
production card socket (zephyr80_card.cpp, FatFs) and runs its tests on
disposable media made here: FAT16, FAT32 and MBR-partitioned FAT32 images
(mkfs.fat, filled by fat_fixture.py) and host folders.  What the tests wrote
is then read back independently: images with fat_fixture.Volume and
fsck.fat -n, folders from the host filesystem, volume records at their file
offsets.  The guest probes boot MAME with `-card` or `-carddir` on copies of
such media and drive the KonaOS shell (FS2) or ZSDOS (CP/M volumes) over the
serial console; their media are checked the same way after MAME exits."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import time

import fat_fixture as fat
import mame_args

HERE = Path(__file__).resolve().parent
EMULATOR = HERE.parent
PBITZ = EMULATOR / "mame/src/mame/pbitz"
FATFS = EMULATOR / "mame/3rdparty/fatfs"

PROBES = {
    "image": ("host", "konaos", "options"),
    "directory": ("host", "konaos", "options"),
    "volumes": ("host", "zsdos-image", "zsdos-folder"),
}
HOST_TESTS = {
    "image": ("workload-fat16", "workload-fat32", "workload-mbr32", "read-only-image", "full-image", "raw-card",
              "raw-coherence", "media-change", "controller-reset"),
    "directory": ("workload-folder", "read-only-folder", "full-folder", "folder-names", "folder-raw"),
    "volumes": ("volumes-image", "volumes-folder", "read-only-volume"),
}

MIB = 1 << 20
VOLUME = 8 * MIB  # VOL_IMAGE_BYTES


def pattern(n, seed):
    """card_test.cpp's pattern(n, seed)."""
    return bytes((seed + i * 7 + (i >> 8)) & 0xff for i in range(n))


HELLO = b"Hello, card!\n"
SEED = {"/HELLO.TXT": HELLO, "/DOCS/": None, "/DOCS/BIG.TXT": pattern(5000, 3), "/SHARED/": None,
        "/SHARED/NOTE.TXT": pattern(300, 9)}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def fill_image(path, tree, runs=None):
    v = fat.Volume(path, write=True)
    for name, data in tree.items():
        if data is None:
            v.mkdir(name.rstrip("/"))
        else:
            v.write_file(name, data, (runs or {}).get(name, 1))
    v.close()


def fill_folder(root, tree):
    root.mkdir(parents=True, exist_ok=True)
    for name, data in tree.items():
        target = root / name.strip("/")
        if data is None:
            target.mkdir(parents=True, exist_ok=True)
        else:
            target.write_bytes(data)


def writable(path):
    """Undo the read-only fixtures so the output directory can be removed."""
    for p in [path] + (list(path.rglob("*")) if path.is_dir() else []):
        if not p.is_symlink():
            p.chmod(p.stat().st_mode | stat.S_IWUSR)


def make_media(media, kind):
    """The disposable media for one case's host tests; returns their SHA-256 by name."""
    if media.exists():
        writable(media)
        shutil.rmtree(media)
    media.mkdir(parents=True)
    if kind == "image":
        for name, fs_type, mib, spc, part in (("fat16", 16, 16, 4, False), ("fat32", 32, 40, 1, False),
                                               ("mbr32", 32, 40, 1, True), ("coherent", 16, 16, 4, False),
                                               ("ro", 16, 16, 4, False)):
            fat.make_image(media / f"{name}.img", mib, fs_type, spc, part)
            fill_image(media / f"{name}.img", SEED)
        (media / "ro.img").chmod(0o444)
        fat.make_image(media / "small16.img", 4, 16, 1)
        raw = bytearray(pattern(8 * MIB, 0x21))
        raw[510:512] = b"\0\0"  # no boot signature: a raw CP/M card
        (media / "raw.img").write_bytes(bytes(raw))
        (media / "raw_small.img").write_bytes(pattern(4 * MIB, 0x22))
        for name, fill in (("change_a", b"a"), ("change_b", b"b")):
            fat.make_image(media / f"{name}.img", 4, 16, 1)
            fill_image(media / f"{name}.img", {"/HELLO.TXT": fill * 13})
        shutil.copy(media / "change_a.img", media / "change_a.orig")
    elif kind == "directory":
        fill_folder(media / "folder", SEED)
        fill_folder(media / "ro_folder", SEED)
        for p in (media / "ro_folder" / "SHARED", media / "ro_folder"):
            p.chmod(0o555)
        (media / "full_folder").mkdir()
        names = media / "names"
        fill_folder(media / "outside", {"/OUTSIDE.TXT": b"keep me\n"})
        fill_folder(names, {"/readme.txt": b"r", "/Mixed.Txt": b"m", "/UPPER.TXT": b"u", "/SUB/": None,
                            "/SUB/INNER.TXT": b"inner", "/SUB/long name.txt": b"L", "/long name.txt": b"L",
                            "/toolongname.txt": b"T", "/.hidden": b"h", "/a.b.c": b"c", "/trailing.": b"t",
                            "/dup.txt": b"d1", "/DUP.TXT": b"d2"})
        (names / "ünï.txt").write_bytes(b"n")
        (names / "LINK.TXT").symlink_to("../outside/OUTSIDE.TXT")
        (names / "LINKDIR").symlink_to("../outside")
    else:
        image = media / "vol.img"
        fat.make_image(image, 48, 16, 8)
        fill_image(image, {"/CPM/": None, "/CPM/CPM_1.DRV": bytes(VOLUME), "/CPM/CPM_2.DRV": bytes(VOLUME),
                           "/CPM/BAD.DRV": bytes(4 * MIB), "/CPM/FRAG.DRV": bytes(VOLUME)},
                   runs={"/CPM/CPM_2.DRV": 3, "/CPM/FRAG.DRV": 17})
        v = fat.Volume(image)
        layout = {name: v.extents("/CPM/" + name) for name in ("CPM_1.DRV", "CPM_2.DRV", "FRAG.DRV")}
        v.close()
        (media / "vol.img.layout").write_text("".join(f"{n} {e[0][0]} {len(e)}\n" for n, e in layout.items() if n != "FRAG.DRV"))
        for folder in ("vol_folder", "vol_ro"):
            fill_folder(media / folder, {"/CPM/": None, "/CPM/CPM_1.DRV": pattern(VOLUME, 0x41),
                                         "/CPM/CPM_2.DRV": bytes(VOLUME), "/CPM/BAD.DRV": bytes(4 * MIB)})
        (media / "vol_ro" / "CPM" / "CPM_1.DRV").chmod(0o444)
        (media / "layout.json").write_text(json.dumps(layout, indent=1) + "\n")
    return {p.name: sha(p.read_bytes()) for p in sorted(media.iterdir()) if p.is_file()}


def build_host(case_dir):
    """Compile card_test against the production socket; returns (binary or None, log)."""
    binary = case_dir / "card_test"
    obj = case_dir / "zephyr80_fatfs.o"
    commands = [
        ["gcc", "-std=gnu99", "-O1", "-g", "-Wall", "-Werror", "-I", str(FATFS), "-c", str(PBITZ / "zephyr80_fatfs.c"), "-o", str(obj)],
        ["c++", "-std=c++17", "-O1", "-g", "-Wall", "-Wextra", "-Werror", "-I", str(HERE / "ioc_core"),
         "-I", str(EMULATOR / "mame/src/osd"), "-I", str(PBITZ), "-I", str(FATFS), str(HERE / "card/card_test.cpp"),
         str(PBITZ / "zephyr80_card.cpp"), str(PBITZ / "zephyr80_ioc_core.cpp"), str(obj), "-o", str(binary)],
    ]
    log = ""
    for command in commands:
        built = subprocess.run(command, capture_output=True, text=True)
        log += "$ " + " ".join(command) + "\n" + built.stdout + built.stderr
        if built.returncode:
            return None, log
    return binary, log


def compare_tree(found, want, what):
    """Failures between a medium's tree and the expected one (names compared upper-case)."""
    found = {k.upper(): v for k, v in found.items()}
    want = {k.upper(): v for k, v in want.items()}
    errors = [f"{what}: {k} missing" for k in want if k not in found]
    errors += [f"{what}: {k} unexpected" for k in found if k not in want]
    errors += [f"{what}: {k} differs ({len(found[k])} bytes, want {len(want[k])})" for k in want
               if k in found and found[k] != want[k]]
    return errors


def image_tree(path):
    v = fat.Volume(path)
    try:
        return v.tree()
    finally:
        v.close()


def fsck_image(path, work):
    """fsck.fat -n of an image's volume (the partition copied out first)."""
    v = fat.Volume(path)
    base = v.base
    v.close()
    if base:
        part = work / (path.name + ".part")
        with open(path, "rb") as src, open(part, "wb") as dst:
            src.seek(base * fat.SECTOR)
            shutil.copyfileobj(src, dst)
        path = part
    return fat.fsck(path)


def verify_host(media, kind, hashes):
    """Independent checks of what card_test wrote; returns (errors, notes)."""
    errors, notes = [], []
    expect = media / "expect"
    for medium in sorted(p.name for p in expect.iterdir()) if expect.is_dir() else []:
        want = fat.folder_tree(expect / medium)
        target = media / medium if (media / medium).is_dir() else media / f"{medium}.img"
        if target.is_dir():
            errors += compare_tree(fat.folder_tree(target), want, medium)
        else:
            errors += compare_tree(image_tree(target), want, medium)
            ok, out = fsck_image(target, media)
            notes.append(f"fsck {target.name}: {out.strip().splitlines()[-1]}")
            if not ok:
                errors.append(f"fsck {target.name}: {out.strip()}")
        notes.append(f"{medium}: {len(want)} entries match")
    records = media / "records.txt"
    count = 0
    for line in records.read_text().splitlines() if records.is_file() else []:
        target, offset, data = line.split()
        offset, data = int(offset), bytes.fromhex(data)
        if ":" in target:
            image, inner = target.split(":")
            v = fat.Volume(media / image)
            _, first, size = v.lookup(inner)
            got = v.read_file(first, size)[offset:offset + len(data)]
            v.close()
        else:
            with open(media / target, "rb") as f:
                f.seek(offset)
                got = f.read(len(data))
        count += 1
        if got != data:
            errors.append(f"record {target} @{offset}: on the medium {got[:8].hex()}..., want {data[:8].hex()}...")
    if count:
        notes.append(f"{count} volume/raw records found at their offsets")
    if kind == "image" and sha((media / "ro.img").read_bytes()) != hashes["ro.img"]:
        errors.append("ro.img changed")
    if kind == "directory":
        if (media / "outside" / "OUTSIDE.TXT").read_bytes() != b"keep me\n":
            errors.append("a file outside the folder root changed")
        if fat.folder_tree(media / "ro_folder") != {k: v for k, v in SEED.items()}:
            errors.append("ro_folder changed")
    if kind == "volumes":
        if (media / "vol_ro" / "CPM" / "CPM_1.DRV").read_bytes() != pattern(VOLUME, 0x41):
            errors.append("read-only CPM_1.DRV changed")
    return errors, notes


def run_host_probe(kind, case_dir):
    media = case_dir / "media"
    hashes = make_media(media, kind)
    binary, log = build_host(case_dir)
    if not binary:
        return False, 1, log, {"media": hashes}
    command = [str(binary), str(media), *HOST_TESTS[kind]]
    result = subprocess.run(command, capture_output=True, text=True, timeout=600)
    log += "$ " + " ".join(command) + "\n" + result.stdout + result.stderr
    verdict = re.search(r"^RESULT (\d+) passed, (\d+) failed", result.stdout, re.M)
    ok = result.returncode == 0 and verdict is not None and verdict.group(2) == "0"
    errors, notes = verify_host(media, kind, hashes)
    log += "".join(f"VERIFY {n}\n" for n in notes) + "".join(f"VERIFY FAIL {e}\n" for e in errors)
    return ok and not errors, result.returncode, log, {"media": hashes, "verify": notes, "errors": errors}


# MAME ------------------------------------------------------------------------

def mame_run(mame, image, case_dir, body, media_args, deadline, wall, steps=None, prompt=None, script="card.lua"):
    """One MAME process with the serial pty, running card.lua's `body`; returns (ok, exit, log, command, traces)."""
    import run as runner  # the runner's pty attachment and watchdog
    case_dir.mkdir(parents=True, exist_ok=True)
    command = [str(mame.resolve()), "zephyr80", "-noreadconfig", "-skip_gameinfo", "-video", "none", "-sound", "none",
               "-nothrottle", "-seconds_to_run", str(deadline + 2),
               "-cfg_directory", str(case_dir / "cfg"), "-nvram_directory", str(case_dir / "nvram"),
               "-state_directory", str(case_dir / "sta"), "-snapshot_directory", str(case_dir / "snap"),
               "-flash", str(image), "-autoboot_script", str(HERE / "harness.lua"), "-autoboot_delay", "0",
               "-sio0b_rs232", "pty", *mame_args.EXTRA, *media_args]
    environment = dict(os.environ, HARNESS_CASE=body, HARNESS_SCRIPT=str(HERE / script), HARNESS_DIR=str(case_dir),
                       HARNESS_DEADLINE=str(deadline), HARNESS_TTY_FILE=str(case_dir / "serial.tty"))
    if prompt:
        environment["HARNESS_PROMPT"] = prompt
    if steps is not None:
        (case_dir / "steps.tsv").write_text("".join(f"{cmd}\t{chr(31).join(expect)}\n" for cmd, expect in steps))
        environment["HARNESS_STEPS"] = str(case_dir / "steps.tsv")
    start = time.monotonic()
    code, log, _ = runner.launch(command, environment, wall, case_dir, {"pty": True}, prompt or "")
    log += f"RUN wall {time.monotonic() - start:.3f} s\n"
    (case_dir / "mame.log").write_text(log)
    verdicts = [line for line in log.splitlines() if re.match(rf"(PASS|FAIL) harness {re.escape(body)}: ", line)]
    traces = [line for line in log.splitlines() if line.startswith(("TRACE ", "RUN wall"))]
    return code == 0 and len(verdicts) == 1 and verdicts[0].startswith("PASS"), code, log, command, traces


def guest_media(case_dir, folder):
    """The KonaOS shell probe's card: the seeded tree plus a 64 KiB file for the copy timing."""
    tree = dict(SEED)
    tree["/DOCS/B64.BIN"] = pattern(65536, 0x64)
    if folder:
        root = case_dir / "card"
        if root.exists():
            shutil.rmtree(root)
        fill_folder(root, tree)
        return root, ["-carddir", str(root)], tree
    image = case_dir / "card.img"
    fat.make_image(image, 16, 16, 4)
    fill_image(image, tree)
    return image, ["-card", str(image)], tree


# The shell session: (command, substrings its answer must hold).
KONAOS_STEPS = [
    ("pwd", ["/"]),
    ("ls", ["HELLO.TXT", "DOCS", "SHARED"]),
    ("cat HELLO.TXT", ["Hello, card!"]),
    ("cp DOCS/BIG.TXT COPY.TXT", []),
    ("stat COPY.TXT", ["5000"]),
    ("mkdir NEWDIR", []),
    ("mv COPY.TXT NEWDIR/MOVED.TXT", []),
    ("ls NEWDIR", ["MOVED.TXT"]),
    ("cp DOCS/B64.BIN SHARED/B64.BIN", []),
    ("rm HELLO.TXT", []),
    ("mkdir GONE", []),
    ("rmdir GONE", []),
    ("cat MISSING.TXT", ["MISSING.TXT"]),
    ("ls", ["NEWDIR", "DOCS"]),
]
KONAOS_REOPEN = [
    ("ls", ["NEWDIR", "DOCS", "SHARED"]),
    ("stat NEWDIR/MOVED.TXT", ["5000"]),
    ("ls SHARED", ["B64.BIN", "NOTE.TXT"]),
]


def run_konaos(mame, serial, case_dir, folder):
    media, args, tree = guest_media(case_dir, folder)
    before = sha(media.read_bytes()) if not folder else None
    ok1, code, log, command, traces = mame_run(mame, serial, case_dir / "run1", "card-shell", args, 120, 240, KONAOS_STEPS, "/> ")
    log = "== run 1\n" + log
    want = dict(tree)
    del want["/HELLO.TXT"]
    want["/NEWDIR/"] = None
    want["/NEWDIR/MOVED.TXT"] = tree["/DOCS/BIG.TXT"]
    want["/SHARED/B64.BIN"] = tree["/DOCS/B64.BIN"]
    found = fat.folder_tree(media) if folder else image_tree(media)
    errors = compare_tree(found, want, "card after the shell session")
    notes = []
    if not folder:
        fsck_ok, out = fat.fsck(media)
        notes.append("fsck: " + out.strip().splitlines()[-1])
        if not fsck_ok:
            errors.append("fsck: " + out.strip())
    ok2, code2, log2, _, traces2 = mame_run(mame, serial, case_dir / "run2", "card-shell", args, 60, 180, KONAOS_REOPEN, "/> ")
    log += "== run 2 (the same card, a new MAME)\n" + log2
    log += "".join(f"VERIFY {n}\n" for n in notes) + "".join(f"VERIFY FAIL {e}\n" for e in errors)
    info = {"media": str(media), "sha256_before": before, "sha256_after": sha(media.read_bytes()) if not folder else None,
            "traces": traces + traces2, "verify": notes, "errors": errors}
    return ok1 and ok2 and not errors, code or code2, log, command, info


def run_options(mame, serial, case_dir, folder):
    """The option errors: both media, a missing path, the wrong kind of path."""
    case_dir.mkdir(parents=True, exist_ok=True)
    image = case_dir / "x.img"
    fat.make_image(image, 4, 16, 1)
    (case_dir / "dir").mkdir(exist_ok=True)
    base = [str(mame.resolve()), "zephyr80", "-noreadconfig", "-skip_gameinfo", "-video", "none", "-sound", "none",
            "-nothrottle", "-seconds_to_run", "1", "-cfg_directory", str(case_dir / "cfg"),
            "-nvram_directory", str(case_dir / "nvram"), "-flash", str(serial)]
    trials = [(["-card", str(image), "-carddir", str(case_dir / "dir")], "exclusive")]
    if folder:
        trials += [(["-carddir", str(case_dir / "nodir")], "does not exist"), (["-carddir", str(image)], "is not a directory")]
    else:
        trials += [(["-card", str(case_dir / "none.img")], "does not exist"), (["-card", str(case_dir / "dir")], "is not a file")]
    log, ok = "", True
    for args, message in trials:
        result = subprocess.run(base + args, capture_output=True, text=True, timeout=60)
        text = result.stdout + result.stderr
        good = result.returncode != 0 and message in text
        ok = ok and good
        log += f"$ {' '.join(base + args)}\nexit {result.returncode}; {'PASS' if good else 'FAIL'} want {message!r}\n{text}\n"
    return ok, 0 if ok else 1, log, base, {"trials": len(trials)}


def zsdos_steps(layout):
    """The ZephyrShell session: ROM-disk tools run from /SYSTEM/A (each ends through WBOOT, back at /).
    `layout`: (base, extents) of CPM_1.DRV and CPM_2.DRV as VOL_INFO must report them.  MCOPY runs
    last: after it ends, the next program loaded from /SYSTEM/A does not start (a guest-side fault
    that needs no card at all, MCOPY B:=A:PING.COM shows it too; see the validation record)."""
    (b0, e0), (b1, e1) = layout
    return [
        ("cd /SYSTEM/A", []),
        ("VOLINFO", [f"unit 0  file /CPM/CPM_1.DRV  base {b0}  extents {e0}  records 65536",
                     f"unit 1  file /CPM/CPM_2.DRV  base {b1}  extents {e1}  records 65536"]),
        ("cd /SYSTEM/A", []),
        ("SDDIR", ["NOTE.TXT      300", "1 file(s)"]),
        ("cd /SYSTEM/A", []),
        ("SDGET NOTE.TXT", ["SDGET: 300 bytes", "done"]),
        ("ls", ["NOTE.TXT"]),
        ("cd /SYSTEM/A", []),
        ("MCOPY D:=C:HELLO.TXT", ["Copy C  0: HELLO   .TXT to D  0:", "Verify Complete", "1 File Copied     0 Copy Errors"]),
    ]


# ZSDOS's SD volume (sd.asm SD_STORAGE_DPB): SPT 4, BSH 5 (4 KiB blocks), EXM 1, DSM 2047, DRM 511,
# AL0 F0h (blocks 0-3 hold the directory), OFF 0.  Records are linear: track * 4 + sector.
CPM_BLOCK = 4096
CPM_DIR_ENTRIES = 512


def cpm_volume(files=()):
    """An 8 MiB CP/M volume in that geometry with `files` (name, bytes) in user 0, one directory
    entry each (at most 32 KiB, so at most 8 blocks)."""
    volume = bytearray(b"\xe5" * VOLUME)
    block = 4
    for slot, (name, data) in enumerate(files):
        records = -(-len(data) // 128)
        blocks = -(-records // 32)
        assert blocks <= 8, name
        pointers = list(range(block, block + blocks)) + [0] * (8 - blocks)
        extent = 1 if records > 128 else 0
        entry = bytes([0]) + fat.pack83(name) + bytes([extent, 0, 0, records - 128 * extent]) + \
            b"".join(p.to_bytes(2, "little") for p in pointers)
        volume[slot * 32:slot * 32 + 32] = entry
        padded = data + b"\x1a" * (records * 128 - len(data))
        volume[block * CPM_BLOCK:block * CPM_BLOCK + len(padded)] = padded
        block += blocks
    return bytes(volume)


def cpm_file(volume, name):
    """The records of user 0's `name` on such a volume, or None."""
    packed = fat.pack83(name)
    entries = []
    for i in range(CPM_DIR_ENTRIES):
        e = volume[i * 32:i * 32 + 32]
        if len(e) == 32 and e[0] == 0 and bytes(c & 0x7f for c in e[1:12]) == packed:
            entries.append(e)
    if not entries:
        return None
    entries.sort(key=lambda e: e[14] * 32 + e[12])
    out = bytearray()
    for n, e in enumerate(entries):
        records = (e[12] & 1) * 128 + e[15] if n == len(entries) - 1 else 256
        pointers = [int.from_bytes(e[16 + 2 * k:18 + 2 * k], "little") for k in range(8)]
        data = b"".join(volume[p * CPM_BLOCK:(p + 1) * CPM_BLOCK] for p in pointers if p)
        out += data[:records * 128]
    return bytes(out)


def run_zsdos(mame, zsdos, case_dir, folder):
    """ZSDOS on a card holding /CPM/CPM_1.DRV (C:, a text file), CPM_2.DRV (D:, empty), /CPM/B (B:) and
    /SHARED/NOTE.TXT: VOLINFO, SDDIR, SDGET and MCOPY C: to D:; then D:'s copy is read back from the
    volume's own directory and B:'s with the FAT reader."""
    case_dir.mkdir(parents=True, exist_ok=True)
    text = b"".join(b"Line %03d of the C: volume test file.\r\n" % i for i in range(60)) + b"\x1a"
    note = pattern(300, 9)
    tree = {"/CPM/": None, "/CPM/B/": None, "/SHARED/": None, "/SHARED/NOTE.TXT": note,
            "/CPM/CPM_1.DRV": cpm_volume([("HELLO.TXT", text)]), "/CPM/CPM_2.DRV": cpm_volume()}
    if folder:
        root = case_dir / "card"
        if root.exists():
            shutil.rmtree(root)
        fill_folder(root, tree)
        args, layout = ["-carddir", str(root)], ((0, 1), (0, 1))
    else:
        image = case_dir / "card.img"
        fat.make_image(image, 24, 16, 8)
        fill_image(image, tree)
        v = fat.Volume(image)
        layout = tuple((e[0][0], len(e)) for e in (v.extents("/CPM/CPM_1.DRV"), v.extents("/CPM/CPM_2.DRV")))
        v.close()
        args = ["-card", str(image)]
    ok, code, log, command, traces = mame_run(mame, zsdos, case_dir / "run", "card-zsdos", args, 120, 300, zsdos_steps(layout), "$ ")
    if folder:
        found = fat.folder_tree(root)
    else:
        found = image_tree(image)
        fsck_ok, out = fat.fsck(image)
        log += "VERIFY fsck: " + out.strip().splitlines()[-1] + "\n"
    errors = [] if folder or fsck_ok else ["fsck: " + out.strip()]
    copy = cpm_file(found.get("/CPM/CPM_2.DRV") or b"", "HELLO.TXT")
    if copy is None:
        errors.append("D:HELLO.TXT is not in CPM_2.DRV's directory")
    elif copy != cpm_file(tree["/CPM/CPM_1.DRV"], "HELLO.TXT"):
        errors.append(f"D:HELLO.TXT differs from C:HELLO.TXT ({len(copy)} bytes)")
    if found.get("/CPM/CPM_1.DRV") != tree["/CPM/CPM_1.DRV"]:
        errors.append("C: (CPM_1.DRV) changed")
    b_note = found.get("/CPM/B/NOTE.TXT")
    if b_note is None or b_note[:300] != note or len(b_note) != 384:
        errors.append(f"B:NOTE.TXT (/CPM/B/NOTE.TXT) is not /SHARED/NOTE.TXT in three records ({len(b_note or b'')} bytes)")
    log += "".join(f"VERIFY FAIL {e}\n" for e in errors) or \
        "VERIFY D:HELLO.TXT in CPM_2.DRV equals C:HELLO.TXT record for record; C: unchanged; /CPM/B/NOTE.TXT holds /SHARED/NOTE.TXT\n"
    return ok and not errors, code, log, command, {"traces": traces, "errors": errors, "layout": layout}


def run(kind, mame, inputs, output, cases=None):
    """The probes of one case (`kind`: image, directory, volumes) into `output`; one record each."""
    output.mkdir(parents=True, exist_ok=True)
    results = []
    for case in cases or PROBES[kind]:
        case_dir = output / case
        if case_dir.exists():
            writable(case_dir)
            shutil.rmtree(case_dir)
        case_dir.mkdir(parents=True)
        start = time.monotonic()
        if case == "host":
            ok, code, log, info = run_host_probe(kind, case_dir)
            command = None
        elif case == "konaos":
            ok, code, log, command, info = run_konaos(mame, inputs["serial"], case_dir, kind == "directory")
        elif case == "options":
            ok, code, log, command, info = run_options(mame, inputs["serial"], case_dir, kind == "directory")
        else:
            ok, code, log, command, info = run_zsdos(mame, inputs["zsdos"], case_dir, case == "zsdos-folder")
        wall = time.monotonic() - start
        (output / f"{case}.log").write_text(log)
        lines = log.splitlines()
        emulated = [float(m.group(1)) for m in re.finditer(r"^TRACE emulated ([0-9.]+) s", log, re.M)]
        results.append({"case": case, "pass": ok, "exit": code, "wall_seconds": round(wall, 3),
                        "emulated_seconds": round(sum(emulated), 6) if emulated else None,
                        "verdict": " / ".join(l for l in lines if re.match(r"(PASS|FAIL|RESULT)( harness)? ", l)) or None,
                        "log": str(output / f"{case}.log"), "command": command, **info})
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    return results
