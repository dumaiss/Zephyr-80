#!/usr/bin/env python3
"""Build native CTCLow and Sound with the supplied CP/M FTL tools."""
import argparse
import os
import pty
from pathlib import Path
import re
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
PROJECT = Path(__file__).resolve().parent.parent


# ---------------------------------------------------------------------------
# RunCPM driver.
#
# Carried here rather than imported.  It came from LIBBUILD.PY, the Turbo
# Modula-2 build, which is gone: TM2's runtime leaves a hosted application no
# room to run on the machine, so the library is FTL-only now.
# ---------------------------------------------------------------------------

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


def unsqueeze(path):
    """Decode the distribution's SQ Huffman/RLE archive, checking its checksum."""
    data = path.read_bytes()
    if data[:2] != b"v\xff":
        raise ValueError("Not a squeezed archive: " + str(path))
    pos = data.index(0, 4) + 1
    count = struct.unpack_from("<h", data, pos)[0]
    pos += 2
    tree = [struct.unpack_from("<hh", data, pos + i * 4) for i in range(count)]
    result = bytearray()
    node, escape = 0, False
    for byte in data[pos + count * 4:]:
        for bit in range(8):
            node = tree[node][(byte >> bit) & 1]
            if node >= 0:
                continue
            char, node = -node - 1, 0
            if char == 256:
                if sum(result) & 65535 != int.from_bytes(data[2:4], "little"):
                    raise ValueError("SQ checksum mismatch: " + str(path))
                return result
            if escape:
                result.extend(bytes([result[-1]]) * (char - 1) if char else b"\x90")
                escape = False
            elif char == 0x90:
                escape = True
            else:
                result.append(char)
    raise ValueError("Missing SQ end marker: " + str(path))


def unpack_lbr(data, drive):
    for pos in range(32, int.from_bytes(data[14:16], "little") * 128, 32):
        entry = data[pos:pos + 32]
        if entry[0]:
            continue
        name = entry[1:9].decode("ascii").strip() + "." + entry[9:12].decode("ascii").strip()
        if not re.fullmatch(r"[A-Z0-9$!_-]{1,8}\.[A-Z0-9]{1,3}", name):
            raise ValueError("Invalid archive member: " + name)
        start = int.from_bytes(entry[12:14], "little") * 128
        size = int.from_bytes(entry[14:16], "little") * 128
        if start + size > len(data):
            raise ValueError("Truncated archive member: " + name)
        (drive / name).write_bytes(data[start:start + size])


def cpm_text(source, target):
    data = source.read_bytes()
    body = data.rstrip(b"\x1a")
    body.decode("ascii")
    if b"\n" in body.replace(b"\r\n", b"") or b"\r" in body.replace(b"\r\n", b""):
        raise ValueError("CP/M source must use CRLF: " + str(source))
    target.write_bytes(body + b"\x1a")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ftl-dir", type=Path, default=PROJECT.parent / "Software/disk1/5")
    parser.add_argument("--runcpm", type=Path, default=PROJECT / "TOOLS/RUNCPM")
    parser.add_argument("--ccp", type=Path, default=PROJECT / "TOOLS/CCP-ZCP3.60K")
    parser.add_argument("--output", type=Path, default=PROJECT / "BUILD/FTL")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="zephyr-ftl-") as temp:
        work = Path(temp)
        drive = work / "A/0"
        drive.mkdir(parents=True)
        # The original distribution searches B: before A: for library modules.
        (work / "B/0").mkdir(parents=True)
        shutil.copyfile(args.ccp, work / "CCP-ZCP3.60K")
        for name in ("ASM.COM", "OPSASM.DAT", "MD.COM", "M2.COM", "M2OVL.OVR", "ML.COM", "ERRMSG.DAT"):
            shutil.copyfile(args.ftl_dir / name, drive / name)
        for name in ("SYMFILES", "MODULA2"):
            unpack_lbr(unsqueeze(args.ftl_dir / (name + ".LQR")), drive)
        for name in ("SRC/CTCLOW.DEF", "SRC/CTCLOW.Z80", "SRC/PORTIO.DEF",
                     "SRC/PORTIO.ASM",
                     "SRC/PLYLOW.DEF", "SRC/PLYLOW.ASM",
                     "SRC/TIMER.DEF", "SRC/TIMER.MOD",
                     "SRC/SOUND.DEF", "SRC/SOUND.MOD",
                     "SRC/ZTR.DEF", "SRC/ZTR.MOD",
                     "SRC/PLYCORE.DEF", "SRC/PLYCORE.MOD",
                     "SRC/PLAYER.DEF", "SRC/PLAYER.MOD",
                     "TEST/FTLTEST.MOD", "TEST/PROFTEST.MOD", "TEST/CALLTEST.MOD", "TEST/LAYTEST.MOD", "TEST/BITTEST.MOD"):
            cpm_text(PROJECT / name, drive / Path(name).name)
        cpm = CPM(args.runcpm.resolve(), work)
        log = []
        try:
            cpm.expect(b"A0>")
            for command, success in (("MD CTCLOW.DEF", "Compilation Complete"),
                                     ("ASM CTCLOW.Z80 CTCLOW.REL", "END OF ASSEMBLY"),
                                     ("MD PORTIO.DEF", "Compilation Complete"),
                                     ("ASM PORTIO.ASM PORTIO.REL", "END OF ASSEMBLY"),
                                     ("MD PLYLOW.DEF", "Compilation Complete"),
                                     ("ASM PLYLOW.ASM PLYLOW.REL", "END OF ASSEMBLY"),
                                     ("MD TIMER.DEF", "Compilation Complete"),
                                     ("MD SOUND.DEF", "Compilation Complete"),
                                     ("MD ZTR.DEF", "Compilation Complete"),
                                     ("MD PLYCORE.DEF", "Compilation Complete"),
                                     ("MD PLAYER.DEF", "Compilation Complete"),
                                     ("M2 TIMER.MOD", "Compilation Complete"),
                                     ("M2 SOUND.MOD", "Compilation Complete"),
                                     ("M2 ZTR.MOD", "Compilation Complete"),
                                     ("M2 PLYCORE.MOD", "Compilation Complete"),
                                     ("M2 PLAYER.MOD", "Compilation Complete"),
                                     ("M2 FTLTEST.MOD", "Compilation Complete"),
                                     ("ML FTLTEST", "link complete"),
                                     ("M2 PROFTEST.MOD", "Compilation Complete"),
                                     ("ML PROFTEST", "link complete"),
                                     ("M2 CALLTEST.MOD", "Compilation Complete"),
                                     ("ML CALLTEST", "link complete"),
                                     ("M2 LAYTEST.MOD", "Compilation Complete"),
                                     ("ML LAYTEST", "link complete"),
                                     ("M2 BITTEST.MOD", "Compilation Complete"),
                                     ("ML BITTEST", "link complete")):
                print(command, flush=True)
                result = display(cpm.cpm(command))
                log.append(result)
                if success not in result or "Error(s)" in result or "errors in" in result:
                    raise RuntimeError(result)
        finally:
            cpm.close()
            (args.output / "BUILD.LOG").write_text("\n".join(log))
        # Search rather than index: not every link map carries CTCLOW, and
        # which command runs last changes as targets are added.
        found = None
        for entry in reversed(log):
            match = re.search(r"CTCLOW\s+([0-9a-fA-F]{4})", entry)
            if match:
                found = match
                break
        if found is None:
            raise BuildError("no link map contained CTCLOW")
        base = int(found[1], 16)
        symbols, pending = {}, []
        for line in log[1].splitlines():
            label = re.fullmatch(r"\s*([A-Z][A-Z0-9]*):\s*", line)
            if label:
                pending.append(label[1])
            address = re.match(r"([0-9A-F]{4})\s+", line)
            if address:
                for name in pending:
                    symbols[name] = base + int(address[1], 16)
                pending.clear()
        (args.output / "SYMBOLS.TXT").write_text("".join(f"{k} {v}\n" for k, v in symbols.items()))
        for name in ("CTCLOW.REL", "CTCLOW.SYM", "PORTIO.REL", "PORTIO.SYM",
                     "PLYLOW.REL", "PLYLOW.SYM", "TIMER.REL", "TIMER.SYM",
                     "SOUND.REL", "SOUND.SYM", "ZTR.REL", "ZTR.SYM",
                     "PLYCORE.REL", "PLYCORE.SYM", "PLAYER.REL", "PLAYER.SYM",
                     "FTLTEST.COM", "PROFTEST.COM", "CALLTEST.COM", "LAYTEST.COM", "BITTEST.COM"):
            shutil.copyfile(drive / name, args.output / name)
        print("Native FTL output: " + str(args.output))


if __name__ == "__main__":
    main()
