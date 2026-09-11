#!/usr/bin/env python3
"""Build SNTracker TM2 with the original CP/M tools under RunCPM."""

from __future__ import annotations

import argparse
import os
import pty
import re
import select
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path


DEF_MODULES = (
    "CTCLOW.DEF",
    "TIMER.DEF",
    "SOUND.DEF",
    "ZTR.DEF",
    "PLAYER.DEF",
    "TRKUI.DEF",
)

MOD_MODULES = (
    "TIMER.MOD",
    "SOUND.MOD",
    "ZTR.MOD",
    "PLAYER.MOD",
    "TRKUI.MOD",
    "SNTRACK.MOD",
    "TIMTEST.MOD",
    "SNDTEST.MOD",
    "ZTRTEST.MOD",
    "PLYTEST.MOD",
)

LINK_TARGETS = (
    ("SNTRACK", "SNTRACK.COM"),
    ("TIMTEST", "TIMTEST.COM"),
    ("SNDTEST", "SNDTEST.COM"),
    ("ZTRTEST", "ZTRTEST.COM"),
    ("PLYTEST", "PLYTEST.COM"),
)

ANSI = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]")


class BuildError(RuntimeError):
    pass


def display(data: bytes) -> str:
    clean = ANSI.sub(b"", data).replace(b"\r", b"")
    return clean.decode("cp437", errors="replace")


class CPM:
    def __init__(self, executable: Path, work: Path, verbose: bool = False):
        master, slave = pty.openpty()
        self.master = master
        self.verbose = verbose
        self.pending = bytearray()
        self.process = subprocess.Popen(
            [str(executable)],
            cwd=work,
            stdin=slave,
            stdout=slave,
            stderr=slave,
            close_fds=True,
        )
        os.close(slave)

    def send(self, text: str) -> None:
        os.write(self.master, text.encode("ascii"))

    def expect_any(
        self, markers: tuple[bytes, ...], timeout: float = 120.0
    ) -> tuple[bytes, bytes]:
        deadline = time.monotonic() + timeout
        while True:
            for marker in markers:
                position = self.pending.find(marker)
                if position >= 0:
                    finish = position + len(marker)
                    result = bytes(self.pending[:finish])
                    del self.pending[:finish]
                    return result, marker
            if self.process.poll() is not None:
                raise BuildError(
                    "RunCPM exited unexpectedly:\n" + display(bytes(self.pending[-8000:]))
                )
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise BuildError(
                    "Timed out waiting for {!r}:\n{}".format(
                        markers, display(bytes(self.pending[-8000:]))
                    )
                )
            ready, _, _ = select.select([self.master], [], [], min(remaining, 1.0))
            if not ready:
                continue
            try:
                chunk = os.read(self.master, 4096)
            except OSError as error:
                raise BuildError("RunCPM terminal closed unexpectedly") from error
            if not chunk:
                continue
            if self.verbose:
                sys.stdout.write(display(chunk))
                sys.stdout.flush()
            self.pending.extend(chunk)
            if len(self.pending) > 262144:
                del self.pending[:131072]

    def expect(self, marker: bytes, timeout: float = 120.0) -> bytes:
        result, _ = self.expect_any((marker,), timeout)
        return result

    def cpm(self, command: str, timeout: float = 120.0) -> bytes:
        self.send(command + "\r")
        return self.expect(b"A0>", timeout)

    def enter_m2(self) -> None:
        self.send("M2\r")
        self.expect(b"\n>", 60.0)

    def leave_m2(self) -> None:
        self.send("q")
        self.expect(b"A0>", 60.0)

    def compile(self, name: str) -> bytes:
        self.send("w" + name + "\r")
        self.expect(b"\n>", 30.0)
        self.send("c\r")
        result, marker = self.expect_any((b"\n>", b"E(dit, Q(uit >"), 180.0)
        text = display(result)
        if marker != b"\n>" or "produced" not in text or "OUTOFMEMORY" in text.upper():
            if marker == b"E(dit, Q(uit >":
                self.send("q")
                self.expect(b"\n>", 30.0)
            raise BuildError("TM2 failed while compiling {}:\n{}".format(name, text[-8000:]))
        return result

    def close(self) -> None:
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        os.close(self.master)


def require_file(path: Path, description: str) -> Path:
    path = path.expanduser().resolve()
    if not path.is_file():
        raise BuildError("{} not found: {}".format(description, path))
    return path


def copy_text(source: Path, destination: Path) -> None:
    data = source.read_bytes().replace(b"\r\n", b"\n").replace(b"\r", b"\n")
    destination.write_bytes(data.replace(b"\n", b"\r\n"))


def validate_83(path: Path) -> None:
    parts = path.name.split(".")
    valid = (
        len(parts) <= 2
        and 1 <= len(parts[0]) <= 8
        and (len(parts) == 1 or len(parts[1]) <= 3)
    )
    if not valid:
        raise BuildError("source filename is not CP/M 8.3-compatible: " + path.name)


def stage(args: argparse.Namespace, work: Path) -> Path:
    drive = work / "A" / "0"
    drive.mkdir(parents=True)

    tm2_dir = args.tm2_dir.expanduser().resolve()
    if not tm2_dir.is_dir():
        raise BuildError("TM2 distribution directory not found: " + str(tm2_dir))
    for source in tm2_dir.iterdir():
        if source.is_file():
            shutil.copy2(source, drive / source.name.upper())

    project = Path(__file__).resolve().parent.parent
    for directory in (project / "SRC", project / "TEST"):
        for source in sorted(directory.iterdir()):
            if source.is_file():
                validate_83(source)
                copy_text(source, drive / source.name.upper())

    shutil.copy2(require_file(args.night, "Night Market ZTR"), drive / "NIGHT.ZTR")
    shutil.copy2(require_file(args.runaway, "Runaway Circuit ZTR"), drive / "RUNAWAY.ZTR")
    shutil.copy2(require_file(args.ccp, "RunCPM CCP"), work / "CCP-ZCP3.60K")
    return drive


def check_output(data: bytes, label: str, required: tuple[str, ...]) -> None:
    text = display(data)
    upper = text.upper()
    if "OUTOFMEMORY" in upper or "OUT OF MEMORY" in upper:
        raise BuildError(label + " ran out of memory:\n" + text[-8000:])
    for marker in required:
        if marker not in text:
            raise BuildError(label + " did not report {!r}:\n{}".format(marker, text[-8000:]))


def build(args: argparse.Namespace, work: Path, drive: Path) -> None:
    print("[1/7] Assemble CTCLOW.Z80")
    cpm = CPM(args.runcpm, work, args.verbose)
    try:
        cpm.expect(b"A0>", 60.0)
        result = cpm.cpm("ZMAC CTCLOW.Z80", 120.0)
        check_output(result, "ZMAC", ("NO ERRORS", "CTCLOW.REL"))

        print("[2/7] Compile definition modules")
        cpm.enter_m2()
        for name in DEF_MODULES:
            print("      " + name)
            cpm.compile(name)
        cpm.leave_m2()

        print("[3/7] Convert the Microsoft REL bridge in a fresh TM2 session")
        cpm.enter_m2()
        cpm.send("rREL CTCLOW CTCLOW\r")
        result = cpm.expect(b"\n>", 120.0)
        check_output(result, "REL", ("undefined symbols:", "none", "CTCLOW.MCD produced"))
        cpm.leave_m2()

        print("[4/7] Compile implementation and main modules")
        cpm.enter_m2()
        for name in MOD_MODULES:
            print("      " + name)
            cpm.compile(name)
        cpm.leave_m2()

        print("[5/7] Build the low-memory standalone linker")
        cpm.enter_m2()
        cpm.send("lLINK\rTLINK.COM\ry")
        result = cpm.expect(b"\n>", 120.0)
        check_output(result, "TM2 linker bootstrap", ("TLINK.COM produced",))
        cpm.leave_m2()

        print("[6/7] Link application and test programs")
        for module, output in LINK_TARGETS:
            print("      " + output)
            cpm.send("TLINK\r")
            cpm.expect(b"Link main module:", 30.0)
            cpm.send(module + "\r")
            cpm.expect(b"Output File:", 30.0)
            cpm.send(output + "\r")
            cpm.expect(b"Include all needed modules", 30.0)
            cpm.send("y")
            result = cpm.expect(b"A0>", 180.0)
            check_output(
                result,
                "link " + output,
                ("Unresolved External References: None", "Missing Modules: None", output + " produced"),
            )

        print("[7/7] Run hardware-independent regressions")
        result = cpm.cpm("ZTRTEST", 120.0)
        check_output(result, "ZTRTEST", ("Title: Night Market", "Bytes:", "20234"))
        ztr_text = display(result)
        for line in ztr_text.splitlines():
            if line.startswith(("Title:", "Bytes:", "Rate:", "Orders:")):
                print("      " + line.strip())

        result = cpm.cpm("PLYTEST", 300.0)
        check_output(result, "PLYTEST", ("NIGHT.ZTR:", "RUNAWAY.ZTR:"))
        player_text = display(result)
        for line in player_text.splitlines():
            if line.startswith(("NIGHT.ZTR:", "RUNAWAY.ZTR:")):
                print("      " + line.strip())

        result = cpm.cpm("SNTRACK", 60.0)
        check_output(result, "SNTRACK command line", ("Usage: SNTRACK file.ZTR",))
    finally:
        cpm.close()

    output_dir = args.output.expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    for _, name in LINK_TARGETS:
        source = drive / name
        if not source.is_file():
            raise BuildError("linked output is missing: " + str(source))
        temporary = output_dir / (name + ".NEW")
        shutil.copy2(source, temporary)
        os.replace(temporary, output_dir / name)

    print("Published:")
    for _, name in LINK_TARGETS:
        result = output_dir / name
        print("  {:12s} {:6d} bytes".format(name, result.stat().st_size))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runcpm", type=Path, required=True)
    parser.add_argument("--tm2-dir", type=Path, required=True)
    parser.add_argument("--ccp", type=Path, required=True)
    parser.add_argument("--night", type=Path, required=True)
    parser.add_argument("--runaway", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--keep", action="store_true", help="retain the temporary CP/M drive")
    parser.add_argument("--verbose", action="store_true", help="show raw compiler output")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        args.runcpm = require_file(args.runcpm, "RunCPM executable")
        if not os.access(args.runcpm, os.X_OK):
            raise BuildError("RunCPM is not executable: " + str(args.runcpm))
        work = Path(tempfile.mkdtemp(prefix="sntrack-tm2-"))
        try:
            drive = stage(args, work)
            print("CP/M staging drive: " + str(work))
            build(args, work, drive)
        except Exception:
            print("Build staging preserved for diagnosis: " + str(work), file=sys.stderr)
            raise
        else:
            if args.keep:
                print("Build staging retained: " + str(work))
            else:
                shutil.rmtree(work)
        return 0
    except (BuildError, OSError) as error:
        print("error: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
