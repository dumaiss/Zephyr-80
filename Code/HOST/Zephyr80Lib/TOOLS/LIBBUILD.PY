#!/usr/bin/env python3
"""Build ZEPHYR80.LIB with the original CP/M tools under RunCPM."""

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
    "PLYCORE.DEF",
    "PLAYER.DEF",
)

MOD_MODULES = (
    "TIMER.MOD",
    "SOUND.MOD",
    "ZTR.MOD",
    "PLYCORE.MOD",
    "PLAYER.MOD",
)

LIBRARY_MODULES = (
    "CTCLOW",
    "TIMER",
    "SOUND",
    "ZTR",
    "PLYCORE",
    "PLAYER",
)

TEST_MODULES = (
    "TIMTEST.MOD",
    "SNDTEST.MOD",
    "ZTRTEST.MOD",
    "PLYTEST.MOD",
    "LIBTEST.MOD",
)

LINK_TARGETS = (
    ("TIMTEST", "TIMTEST.COM"),
    ("SNDTEST", "SNDTEST.COM"),
    ("ZTRTEST", "ZTRTEST.COM"),
    ("PLYTEST", "PLYTEST.COM"),
    ("LIBTEST", "LIBTEST.COM"),
)

LIBRARY_NAME = "ZEPHYR80.LIB"

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


def create_library(cpm: CPM) -> None:
    """Create the TM2 archive through the original interactive librarian."""
    cpm.enter_m2()
    cpm.send("b")
    cpm.expect(b"Select library:", 30.0)
    cpm.send(LIBRARY_NAME + "\r")
    cpm.expect(b"is new library. OK (Y/N)?", 30.0)
    cpm.send("y")
    cpm.expect(b"*", 30.0)
    for module in LIBRARY_MODULES:
        for suffix in ("SYM", "MCD"):
            member = module + "." + suffix
            print("      " + member)
            cpm.send("i")
            cpm.expect(b"Include file:", 30.0)
            cpm.send(member + "\r")
            cpm.expect(b"*", 60.0)
    cpm.send("q")
    cpm.expect(b"\n>", 30.0)


def select_library_path(cpm: CPM) -> None:
    """Add ZEPHYR80 after the default SYSLIB compiler search path."""
    cpm.send("o")
    cpm.expect(b"\n>", 30.0)
    cpm.send("p")
    cpm.expect(b"New search path:", 30.0)
    # TM2 presents "SYSLIB " as an editable default.  Appending the second
    # archive produces the search path "SYSLIB ZEPHYR80".
    cpm.send("ZEPHYR80\r")
    result = cpm.expect(b"\n>", 30.0)
    check_output(result, "TM2 library path", ("SYSLIB ZEPHYR80",))
    cpm.send("q")
    cpm.expect(b"\n>", 30.0)


def extract_library_code(cpm: CPM) -> None:
    """Extract MCD members for the standalone low-memory linker."""
    cpm.send("b")
    cpm.expect(b"Select library:", 30.0)
    cpm.send(LIBRARY_NAME + "\r")
    cpm.expect(b"*", 30.0)
    for module in LIBRARY_MODULES:
        member = module + ".MCD"
        cpm.send("c")
        cpm.expect(b"Copy module:", 30.0)
        cpm.send(member + "\r")
        cpm.expect(b"Copy to drive or library:", 30.0)
        cpm.send("A:\r")
        result = cpm.expect(b"*", 60.0)
        check_output(result, "extract " + member, ("Copying " + member,))
    cpm.send("q")
    cpm.expect(b"\n>", 30.0)


def build(args: argparse.Namespace, work: Path, drive: Path) -> None:
    print("[1/8] Assemble CTCLOW.Z80")
    cpm = CPM(args.runcpm, work, args.verbose)
    try:
        cpm.expect(b"A0>", 60.0)
        result = cpm.cpm("ZMAC CTCLOW.Z80", 120.0)
        check_output(result, "ZMAC", ("NO ERRORS", "CTCLOW.REL"))

        print("[2/8] Compile definition modules")
        cpm.enter_m2()
        for name in DEF_MODULES:
            print("      " + name)
            cpm.compile(name)
        cpm.leave_m2()

        print("[3/8] Convert the Microsoft REL bridge in a fresh TM2 session")
        cpm.enter_m2()
        cpm.send("rREL CTCLOW CTCLOW\r")
        result = cpm.expect(b"\n>", 120.0)
        check_output(result, "REL", ("undefined symbols:", "none", "CTCLOW.MCD produced"))
        cpm.leave_m2()

        print("[4/8] Compile implementation modules")
        cpm.enter_m2()
        for name in MOD_MODULES:
            print("      " + name)
            cpm.compile(name)
        cpm.leave_m2()

        print("[5/8] Create " + LIBRARY_NAME)
        create_library(cpm)
        select_library_path(cpm)

        # Remove every loose library product.  Compilation and linking below
        # must therefore resolve both SYM and MCD members from ZEPHYR80.LIB.
        for module in LIBRARY_MODULES:
            for suffix in ("SYM", "MCD"):
                loose = drive / (module + "." + suffix)
                if not loose.is_file():
                    raise BuildError("library input disappeared: " + str(loose))
                loose.unlink()

        print("[6/8] Compile consumers using only the library")
        for name in TEST_MODULES:
            print("      " + name)
            cpm.compile(name)

        print("[7/8] Extract code and link with the low-memory linker")
        cpm.send("wLINK.MCD\r")
        cpm.expect(b"\n>", 30.0)
        cpm.send("l\r")
        cpm.expect(b"Output File:", 30.0)
        cpm.send("TLINK.COM\r")
        cpm.expect(b"Include all needed modules", 30.0)
        cpm.send("y")
        result = cpm.expect(b"\n>", 120.0)
        check_output(result, "TM2 linker bootstrap", ("TLINK.COM produced",))

        extract_library_code(cpm)
        cpm.leave_m2()

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

        print("[8/8] Run hardware-independent regressions")
        result = cpm.cpm("LIBTEST", 120.0)
        check_output(result, "LIBTEST", ("ZEPHYR80.LIB API OK",))

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
    finally:
        cpm.close()

    output_dir = args.output.expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    outputs = (LIBRARY_NAME,) + tuple(name for _, name in LINK_TARGETS)
    for name in outputs:
        source = drive / name
        if not source.is_file():
            raise BuildError("build output is missing: " + str(source))
        temporary = output_dir / (name + ".NEW")
        shutil.copy2(source, temporary)
        os.replace(temporary, output_dir / name)

    print("Published:")
    for name in outputs:
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
        work = Path(tempfile.mkdtemp(prefix="zephyr80lib-"))
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
