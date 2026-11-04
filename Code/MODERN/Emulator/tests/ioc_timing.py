"""IO controller lane timing probes: the `ioc-timing` case of tests/run.py.

Each probe boots the probe program (sio1_lanes.asm) on a disposable card
image and runs one ioc_timing.lua case body in its own MAME process, in both
`-ioc_speed` modes.  `transfers` times LINK_SYNC, PING and reads and writes of
128 B, 512 B and 4 KiB phase by phase against the paced model and checks that
fast mode ends with the same replies and the same bytes on the card.
`admission`, `partial` and `reset` cover the timing edges (no host, back to
back commands, an abandoned transfer, a stalled request, a machine reset with
work pending) and `state` saves a transfer in flight and finishes it from the
restored state."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

import card_backends as cards
import fat_fixture as fat
import sio1_lanes

HERE = Path(__file__).resolve().parent
CASES = ("transfers", "zsdos", "admission", "partial", "reset", "state")
SPEEDS = ("paced", "fast")
WALL = 120
FILE = cards.pattern(4096, 3)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def make_card(path):
    """A FAT16 card with /SHARED/R4K.BIN (the pattern the probe reads) and /SHARED/NOTE.TXT."""
    fat.make_image(path, 16, 16, 4)
    cards.fill_image(path, {"/SHARED/": None, "/SHARED/R4K.BIN": FILE, "/SHARED/NOTE.TXT": cards.pattern(300, 9)})
    return path


def run_body(mame, image, case_dir, body, speed, card, deadline, extra=(), extra_env=None):
    """One MAME process: returns (ok, exit, log, command)."""
    case_dir.mkdir(parents=True, exist_ok=True)
    command = [str(mame.resolve()), "zephyr80", "-noreadconfig", "-skip_gameinfo", "-video", "none", "-sound", "none",
               "-nothrottle", "-seconds_to_run", str(deadline + 2),
               "-cfg_directory", str(case_dir / "cfg"), "-nvram_directory", str(case_dir / "nvram"),
               "-state_directory", str(case_dir / "sta"), "-snapshot_directory", str(case_dir / "snap"),
               "-flash", str(image), "-autoboot_script", str(HERE / "harness.lua"), "-autoboot_delay", "0",
               "-ioc_speed", speed, "-card", str(card), *extra]
    environment = dict(os.environ, HARNESS_CASE=body, HARNESS_SCRIPT=str(HERE / "ioc_timing.lua"),
                       HARNESS_DIR=str(case_dir), HARNESS_DEADLINE=str(deadline), HARNESS_IOC_SPEED=speed, HARNESS_TRACE="1", **(extra_env or {}))
    start = time.monotonic()
    try:
        result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=WALL)
        code, log = result.returncode, result.stdout + result.stderr
    except subprocess.TimeoutExpired as exc:
        code = 124
        log = (exc.stdout or b"").decode(errors="replace") + f"\nWALL TIMEOUT after {WALL} seconds\n"
    log += f"RUN wall {time.monotonic() - start:.3f} s\n"
    verdicts = [line for line in log.splitlines() if re.match(rf"(PASS|FAIL) harness {re.escape(body)}: ", line)]
    ok = code == 0 and len(verdicts) == 1 and verdicts[0].startswith("PASS")
    (case_dir / "mame.log").write_text(log)
    return ok, code, log, command


def lines_of(log, prefix):
    return [line for line in log.splitlines() if line.startswith(prefix)]


def parse_times(log):
    """TIME lines to {label: {key: value}}."""
    out = {}
    for line in lines_of(log, "TIME "):
        fields = line.split()
        label = " ".join(f for f in fields[2:] if "=" not in f)
        out[label] = {k: float(v) for k, v in (f.split("=") for f in fields[2:] if "=" in f)}
    return out


def check_card(path):
    """What the card holds after `transfers`: the read file untouched, the written file complete, fsck clean."""
    v = fat.Volume(path)
    try:
        tree = v.tree()
    finally:
        v.close()
    errors = []
    if tree.get("/SHARED/R4K.BIN") != FILE:
        errors.append("R4K.BIN changed")
    if tree.get("/SHARED/W4K.BIN") != FILE:
        errors.append(f"W4K.BIN is {len(tree.get('/SHARED/W4K.BIN') or b'')} bytes and does not equal the pattern")
    ok, text = fat.fsck(path)
    if not ok:
        errors.append("fsck: " + text.strip())
    return tree, errors


def probe_transfers(mame, image, case_dir):
    runs, trees, errors, log = {}, {}, [], ""
    for speed in SPEEDS:
        card = make_card(case_dir / f"card-{speed}.img")
        ok, code, text, command = run_body(mame, image, case_dir / speed, "transfers", speed, card, 40)
        log += f"== {speed}\n{text}"
        runs[speed] = {"ok": ok, "times": parse_times(text), "out": lines_of(text, "OUT "), "wall": re.search(r"RUN wall ([0-9.]+)", text).group(1),
                       "emulated": float(re.search(r"^TRACE emulated ([0-9.]+) s", text, re.M).group(1)) if re.search(r"^TRACE emulated", text, re.M) else None}
        if not ok:
            errors.append(f"{speed}: the body failed")
            continue
        trees[speed], more = check_card(card)
        errors += [f"{speed}: {e}" for e in more]
    info = {"runs": {s: {"times": r["times"], "wall": r["wall"], "emulated": r["emulated"]} for s, r in runs.items()}}
    if all(r["ok"] for r in runs.values()):
        if runs["paced"]["out"] != runs["fast"]["out"]:
            errors.append("paced and fast outcomes differ: " + "; ".join(sorted(set(runs["paced"]["out"]) ^ set(runs["fast"]["out"]))[:6]))
        if trees["paced"] != trees["fast"]:
            errors.append("the cards differ after paced and fast")
        for label, paced in runs["paced"]["times"].items():
            fast = runs["fast"]["times"].get(label)
            if fast is None:
                errors.append(f"fast has no timing for {label}")
            elif fast.get("total", fast.get("exchange", 0)) > paced.get("total", paced.get("exchange", 0)) + 1:
                errors.append(f"{label}: fast {fast} is slower than paced {paced}")
        info["outcomes"] = len(runs["paced"]["out"])
        info["card_sha256"] = {s: {k: sha(v) for k, v in trees[s].items() if k.startswith("/SHARED/") and v is not None} for s in trees}
    log += "".join(f"VERIFY FAIL {e}\n" for e in errors)
    return not errors, 0, log, None, {"errors": errors, **info}


def probe_both(body, extra_check=None):
    """A body in both modes on fresh cards: both pass, their outcome lines are equal."""
    def probe(mame, image, case_dir):
        runs, errors, log, cards_ = {}, [], "", {}
        for speed in SPEEDS:
            card = make_card(case_dir / f"card-{speed}.img")
            ok, code, text, command = run_body(mame, image, case_dir / speed, body, speed, card, 40)
            log += f"== {speed}\n{text}"
            runs[speed] = {"ok": ok, "out": lines_of(text, "OUT "), "verdict": next((l for l in text.splitlines() if re.match(rf"(PASS|FAIL) harness {body}", l)), None)}
            cards_[speed] = card
            if not ok:
                errors.append(f"{speed}: the body failed")
        if all(r["ok"] for r in runs.values()):
            if runs["paced"]["out"] != runs["fast"]["out"]:
                errors.append("paced and fast outcomes differ: " + "; ".join(sorted(set(runs["paced"]["out"]) ^ set(runs["fast"]["out"]))))
            if extra_check:
                errors += extra_check(cards_)
        log += "".join(f"VERIFY FAIL {e}\n" for e in errors)
        return not errors, 0, log, None, {"errors": errors, "verdicts": {s: r["verdict"] for s, r in runs.items()}, "outcomes": runs["paced"]["out"]}
    return probe


def check_partial(cards_):
    """The short write committed the 300 bytes sent in both modes.  What follows them (the SIO's CRC, then its fill or
    the line's marks, depending on when the guest disabled its transmitter against the window) is not compared."""
    errors, files = [], {}
    for speed, card in cards_.items():
        v = fat.Volume(card)
        try:
            files[speed] = v.tree().get("/SHARED/P512.BIN")
        finally:
            v.close()
        data = files[speed]
        if data is None or len(data) != 512:
            errors.append(f"{speed}: P512.BIN is {None if data is None else len(data)} bytes, want 512")
        elif data[:300] != FILE[:300]:
            errors.append(f"{speed}: the 300 bytes sent are not on the card")
    return errors


def probe_state(mame, image, case_dir):
    runs, errors, log = {}, [], ""
    for speed in SPEEDS:
        card = make_card(case_dir / f"card-{speed}.img")
        speed_dir = case_dir / speed
        ok, code, text, command = run_body(mame, image, speed_dir, "state-save", speed, card, 40)
        log += f"== {speed} state-save\n{text}"
        if not ok:
            errors.append(f"{speed}: state-save failed")
            continue
        load_card = make_card(case_dir / f"card-{speed}-restored.img")
        ok, code, text, command = run_body(mame, image, speed_dir, "state-load", speed, load_card, 40, extra=("-state", "midbulk"),
                                           extra_env={"HARNESS_PREV": str(speed_dir)})
        log += f"== {speed} state-load\n{text}"
        runs[speed] = {"ok": ok, "out": lines_of(text, "OUT "), "state": (speed_dir / "state.txt").read_text().strip(),
                       "verdict": next((l for l in text.splitlines() if re.match(r"(PASS|FAIL) harness state-load", l)), None)}
        if not ok:
            errors.append(f"{speed}: state-load failed")
    log += "".join(f"VERIFY FAIL {e}\n" for e in errors)
    return not errors, 0, log, None, {"errors": errors, "runs": runs}


PROBES = {
    "transfers": probe_transfers,
    "zsdos": probe_both("zsdos"),
    "admission": probe_both("admission"),
    "partial": probe_both("partial", check_partial),
    "reset": probe_both("reset"),
    "state": probe_state,
}


def run(mame, konaos_image, zsdos_image, output, cases=None):
    """Run the probes (all of CASES by default) into `output`; returns one record per probe."""
    output.mkdir(parents=True, exist_ok=True)
    image = sio1_lanes.assemble(output)
    results = []
    for case in cases or CASES:
        case_dir = output / case
        if case_dir.exists():
            shutil.rmtree(case_dir)
        case_dir.mkdir(parents=True)
        start = time.monotonic()
        ok, code, log, command, info = PROBES[case](mame, image, case_dir)
        wall = time.monotonic() - start
        (output / f"{case}.log").write_text(log)
        lines = log.splitlines()
        results.append({"case": case, "pass": ok, "exit": code, "wall_seconds": round(wall, 3),
                        "verdict": " / ".join(l for l in lines if re.match(r"(PASS|FAIL) harness ", l)) or None,
                        "log": str(output / f"{case}.log"), "command": command, "image": str(image),
                        "sha256": sha(image.read_bytes()), **info})
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    return results
