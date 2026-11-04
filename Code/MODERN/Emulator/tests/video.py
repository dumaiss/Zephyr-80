"""V9958 cases of tests/run.py: `v9958` and `graphics-apps`.

`v9958` (the stock V9958 as this machine wires it):
  bitmap          vdp_text.lua vdp-bitmap: the observers against known VRAM, palette, sprites and status
                  in GRAPHIC6 and GRAPHIC7, 192 and 212 lines, scroll, page 1, a stale-pixel control.
  ports           video.lua vdp-ports: VRAM range and banks, mirrors, palette, registers, status.
  commands        video.lua vdp-commands with video.asm: HMMV, HMMM, LMMV, LMMM, LINE and PSET run by real
                  Z80 code, results against references, busy state and time.
  konaos-console  the production KonaOS console: glyphs, positions, reverse video, erase, wrap, cursor,
                  scrolling, colours, status-port reads (video.lua console-konaos).
  zsdos-console   the same on ZSDOS (video.lua console-zsdos).
`graphics-apps` (programs on a card image run on the production KonaOS image; apps.lua):
  gfxtest, gfxdemo, sntview, iobench, and sntview and iobench again at the fast IO controller setting.

Every run keeps its console font (guest_font.py), a manifest with the exact command and every input hash,
the captures (PNG with its file and pixel SHA-256, program and stop) and the harness's transcript."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import zlib

import card_backends
import fat_fixture as fat
import guest_font
import keyboard
import mame_args

HERE = Path(__file__).resolve().parent
PROBES = {
    "v9958": ("bitmap", "ports", "commands", "konaos-console", "zsdos-console"),
    "graphics-apps": ("gfxtest", "gfxdemo", "sntview", "iobench", "sntview-fast", "iobench-fast"),
}

ESC = b"\x1b"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def ansi_file():
    """The ANSI listing: glyph rows, positioning, reverse video, erase, wrap, no-wrap, tab, backspace, insert
    line, and a closing marker.  BDOS function 6 treats E = FDh-FFh as console input, so the CP850 row stops at
    FCh (ZSDOS's `cat` writes through it)."""
    def csi(text):
        return ESC + b"[" + text.encode()
    out = csi("2J") + csi("H")
    out += bytes(range(0x20, 0x50)) + b"\r\n" + bytes(range(0x50, 0x7f)) + b"\r\n"
    out += bytes(range(0x80, 0xc0)) + b"\r\n" + bytes(range(0xc0, 0xfd)) + b"\r\n"
    out += csi("10;20H") + b"AT 10,20"
    out += csi("12;1H") + csi("7m") + b"REVERSE" + csi("0m") + b" norm"
    out += csi("14;1H") + b"XXXXXXXXXX" + csi("14;5H") + csi("K")
    out += csi("15;1H") + b"ABCDEFGH" + csi("15;4H") + csi("1K")
    out += csi("16;82H") + b"ABCDEF"
    out += csi("?7l") + csi("18;83H") + b"WXYZ" + csi("?7h")
    out += csi("20;1H") + b"a\tbcd\be"
    out += csi("22;1H") + b"INSERTED-ONE" + csi("22;1H") + csi("L")
    out += csi("25;1H") + b"END-OF-ANSI" + csi("25;18H")
    return out


def scroll_file():
    return b"".join(b"S%03d the quick brown fox jumps over the lazy dog\r\n" % i for i in range(1, 101))


def assemble(output):
    """Build the command probe's flash image from video.asm with the SDCC tools."""
    build = output / "video_probe"
    build.mkdir(parents=True, exist_ok=True)
    rel, ihx, image = build / "video.rel", build / "video.ihx", build / "video.bin"
    for command in (["sdasz80", "-o", "-l", "-s", str(rel), str(HERE / "video.asm")],
                    ["sdldz80", "-n", "-i", str(ihx), str(rel)],
                    ["makebin", str(ihx), str(image)]):
        subprocess.run(command, check=True, capture_output=True, text=True)
    return image


def halt_image(case_dir):
    image = case_dir / "halt.bin"
    image.write_bytes(b"\xf3\x76")  # DI; HALT
    return image


def manifest_name(exe):
    manifest = exe.parent / exe.stem / (exe.stem + ".json")
    if not manifest.is_file():
        raise FileNotFoundError(f"build manifest {manifest} is missing for {exe}")
    name = json.loads(manifest.read_text())["name"]
    if name != exe.name:
        raise ValueError(f"{manifest} names {name}, not {exe.name}")
    return name


def png_pixels_sha256(path):
    """SHA-256 of a PNG's decoded image data: the same for the same screen whatever MAME build wrote the file
    (the file's text chunks carry the build's version string)."""
    data = Path(path).read_bytes()[8:]
    idat, offset = b"", 0
    while offset < len(data):
        length = int.from_bytes(data[offset:offset + 4], "big")
        if data[offset + 4:offset + 8] == b"IDAT":
            idat += data[offset + 8:offset + 8 + length]
        offset += 12 + length
    return sha(zlib.decompress(idat))


def captures_manifest(run_dir, programs, assets):
    """Every PNG a run kept: its file and pixel SHA-256, the program and stop it shows, with the program and
    asset hashes."""
    manifest = {"programs": programs, "assets": assets, "captures": []}
    table = run_dir / "captures.tsv"
    if table.is_file():
        lines = table.read_text().splitlines()
        for line in lines[1:]:
            fields = line.split("\t")
            png = run_dir / fields[0]
            manifest["captures"].append({"file": fields[0], "program": fields[1], "args": fields[2], "stop": fields[3],
                                         "emulated_s": float(fields[4]), "mode": fields[5], "page": fields[6],
                                         "sha256": sha(png.read_bytes()) if png.is_file() else None,
                                         "pixels_sha256": png_pixels_sha256(png) if png.is_file() else None})
    for png in sorted(run_dir.glob("*.png")):
        if not any(c["file"] == png.name for c in manifest["captures"]):
            manifest["captures"].append({"file": png.name, "sha256": sha(png.read_bytes()), "pixels_sha256": png_pixels_sha256(png)})
    (run_dir / "captures.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


def run_v9958(mame, inputs, case_dir, probe):
    case_dir.mkdir(parents=True, exist_ok=True)
    info = {}
    if probe == "bitmap":
        image = halt_image(case_dir)
        ok, code, log, command = keyboard.mame_run(mame, image, case_dir / "run", "vdp-bitmap", 20, 120, script="vdp_text.lua")
    elif probe == "ports":
        image = halt_image(case_dir)
        ok, code, log, command = keyboard.mame_run(mame, image, case_dir / "run", "vdp-ports", 20, 120, script="video.lua")
    elif probe == "commands":
        image = assemble(case_dir)
        info["probe_sha256"] = sha(image.read_bytes())
        ok, code, log, command = keyboard.mame_run(mame, image, case_dir / "run", "vdp-commands", 60, 240, script="video.lua")
        table = case_dir / "run" / "commands.tsv"
        if table.is_file():
            info["commands_tsv"] = str(table)
    else:
        guest = "konaos" if probe == "konaos-console" else "zsdos"
        tree = {"/ANSI.TXT": ansi_file(), "/SCROLL.TXT": scroll_file()}
        if guest == "konaos":
            card = case_dir / "card.img"
            fat.make_image(card, 16, 16, 4)
            card_backends.fill_image(card, {"/BIN/": None, **tree})
            media = ["-card", str(card)]
            body, deadline = "console-konaos", 80
        else:
            card = case_dir / "card"
            if card.exists():
                shutil.rmtree(card)
            card_backends.fill_folder(card, {"/CPM/": None, "/CPM/B/": None, **{"/CPM/B" + k: v for k, v in tree.items()}})
            media = ["-carddir", str(card)]
            body, deadline = "console-zsdos", 120
        ok, code, log, command = keyboard.mame_run(mame, inputs[guest], case_dir / "run", body, deadline, 400, extra=media,
                                                   font=guest, script="video.lua")
        info["media"] = str(card)
        info["files"] = {k: {"bytes": len(v), "sha256": sha(v)} for k, v in tree.items()}
        info["guest_sha256"] = sha(inputs[guest].read_bytes())
    return ok, code, log, command, info


APPS = {"gfxtest": "gfxtest", "gfxdemo": "gfxdemo", "sntview": "sntview", "iobench": "iobench"}


def run_apps(mame, inputs, case_dir, probe):
    case_dir.mkdir(parents=True, exist_ok=True)
    program = probe.replace("-fast", "")
    names = {n: manifest_name(inputs[n]) for n in ("gfxtest", "gfxdemo", "sntview", "iobench")}
    tree = {"/BIN/": None, **{f"/BIN/{names[n].upper()}": inputs[n].read_bytes() for n in names},
            "/NIGHT.ZTR": inputs["ztr"].read_bytes()}
    card = case_dir / "card.img"
    fat.make_image(card, 16, 16, 4)
    card_backends.fill_image(card, tree)
    body = {"gfxtest": "apps-gfxtest", "gfxdemo": "apps-gfxdemo", "sntview": "apps-sntview", "iobench": "timing-iobench"}[program]
    deadline, wall = {"gfxtest": (400, 600), "gfxdemo": (60, 200), "sntview": (120, 300), "iobench": (300, 600)}[program]
    extra = ["-card", str(card)]
    if probe.endswith("-fast"):
        extra += ["-ioc_speed", "fast"]
    env = {"HARNESS_PLAY_SECONDS": "40"}
    ok, code, log, command = keyboard.mame_run(mame, inputs["konaos"], case_dir / "run", body, deadline, wall, extra=extra,
                                               font="konaos", env=env, script="apps.lua")
    programs = {n: {"file": str(inputs[n]), "card": f"/BIN/{names[n].upper()}", "sha256": sha(inputs[n].read_bytes())} for n in names}
    assets = {"/NIGHT.ZTR": {"file": str(inputs["ztr"]), "sha256": sha(inputs["ztr"].read_bytes())}}
    manifest = captures_manifest(case_dir / "run", programs, assets)
    info = {"media": str(card), "captures": len(manifest["captures"]), "programs": programs, "konaos_sha256": sha(inputs["konaos"].read_bytes()),
            "ioc_speed": "fast" if probe.endswith("-fast") else "paced"}
    for name in ("sntview-exit.txt", "gfxtest-results.txt", "gfxtest-timing.tsv", "iobench.tsv"):
        if (case_dir / "run" / name).is_file():
            info[name] = (case_dir / "run" / name).read_text()
    return ok, code, log, command, info


def run(case, mame, inputs, output, cases=None):
    output.mkdir(parents=True, exist_ok=True)
    results = []
    for probe in cases or PROBES[case]:
        case_dir = output / probe
        if case_dir.exists():
            shutil.rmtree(case_dir)
        start = time.monotonic()
        ok, code, log, command, info = (run_v9958 if case == "v9958" else run_apps)(mame, inputs, case_dir, probe)
        wall = time.monotonic() - start
        (output / f"{probe}.log").write_text(log)
        lines = log.splitlines()
        emulated = [float(m) for m in re.findall(r"^TRACE emulated ([0-9.]+) s", log, re.M)]
        results.append({"case": probe, "pass": ok, "exit": code, "wall_seconds": round(wall, 3),
                        "emulated_seconds": round(sum(emulated), 6) if emulated else None,
                        "verdict": " / ".join(line for line in lines if re.match(r"(PASS|FAIL|RESULT)( harness)? ", line)) or None,
                        "traces": [line for line in lines if line.startswith(("TRACE ", "RUN wall", "Average speed"))],
                        "diagnostics": [line for line in lines if line.startswith("DIAG ")],
                        "log": str(output / f"{probe}.log"), "command": command, **info})
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    return results
