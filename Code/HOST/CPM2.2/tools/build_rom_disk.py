#!/usr/bin/env python3
"""Build the read-only ROM disk volume for drive A: and split it into ROM pages.

The volume is an ordinary CP/M filesystem, so the CCP, DIR, STAT and PIP all work
on it unmodified -- which is the point: once B: is healthy, `PIP B:=A:*.*`
populates the card from flash with no host proxy involved.

The hardware only exposes ROM at 0000h-BFFFh while shadow/copy mode is on, so the
volume is emitted as one 48 KiB chunk per ROM page rather than a single blob.
cbios_storage_rom.asm maps a CP/M record back to (page, offset) with the same
stride.

This writes only inside the build directory and the staging tree.  It must never
touch images/zephyr80-vdrip2.cpm, which is the separate, user-owned VDrip volume.

cpmtools looks for a file named `diskdefs` in the current directory before it
falls back to /etc/cpmtools/diskdefs, so the disk definition is staged next to
the scratch image and the tools are run from there.  Nothing needs installing
system-wide.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


# (source root key, file name in that root, CP/M file name).
#
# The diagnostics keep the same build-name -> CP/M-name mapping that
# HelloWorld/tools/install_diagnostics.py already uses for the VDrip volume, so a
# utility is called the same thing on both disks.
#
# SUBMIT is deliberately absent: the CCP hard-codes drive A for $$$.SUB
# (cpm22.asm "always use drive A for submit"), so it cannot work on a read-only
# A:.  ZSID is carried instead of DDT because DDT's assembler and disassembler
# are 8080-only, which is a real handicap on a Z80.
MANIFEST = (
    # IO Controller and SD-card diagnostics, built from HelloWorld.
    ("hello", "ioc_ping.com", "PING.COM"),
    ("hello", "ioc_reset.com", "RESET.COM"),
    ("hello", "ioc_bulk.com", "BULK.COM"),
    ("hello", "ioc_sd_read.com", "SDREAD.COM"),
    ("hello", "ioc_sdblk.com", "SDBLK.COM"),
    ("hello", "ioc_sdrec.com", "SDREC.COM"),
    ("hello", "ioc_sdsoak.com", "SDSOAK.COM"),
    ("hello", "ioc_sdfmt.com", "SDFMT.COM"),
    ("hello", "ioc_sdwrite.com", "SDWRITE.COM"),
    ("hello", "ioc_sdbench.com", "SDBENCH.COM"),
    ("hello", "ioc_rts_probe.com", "RTSPROBE.COM"),
    ("hello", "ioc_diagchk.com", "DIAGCHK.COM"),
    ("hello", "hidkey.com", "HIDKEY.COM"),
    ("hello", "v9958tst.com", "V9958TST.COM"),
    # The monitor is the only tool that still works with no usable disk at all:
    # L loads Intel HEX over the console, DB dumps a bank, I/O reach ports.
    # Built from source rather than copied, so it always matches the tree.
    ("monitor", "zephyr80_monitor.bin", "MONITOR.COM"),
    # Stock CP/M utilities.  No source in tree; carried from the VDrip volume.
    ("stock0", "pip.com", "PIP.COM"),
    ("stock0", "STAT.COM", "STAT.COM"),
    ("stock0", "NOWRAP.com", "NOWRAP.COM"),
    ("stock0", "WRAPON.COM", "WRAPON.COM"),
    ("stock1", "ZSID.COM", "ZSID.COM"),
    ("stock1", "DUMP.COM", "DUMP.COM"),
)

# Unallocated space is filled with E5h, the conventional "formatted but empty"
# byte.  CP/M never reads a block the directory does not reference, so this is
# cosmetic -- but it makes a hex dump of the ROM obviously a CP/M volume.
FILL = 0xE5


def run(command: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command, cwd=cwd, check=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
    except FileNotFoundError as error:
        raise SystemExit(f"required command not found: {command[0]}") from error
    except subprocess.CalledProcessError as error:
        if error.stdout:
            sys.stderr.write(error.stdout)
        if error.stderr:
            sys.stderr.write(error.stderr)
        raise SystemExit(
            f"command failed with status {error.returncode}: {' '.join(command)}"
        ) from error


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hello-dir", type=Path, default=Path("../HelloWorld/build"))
    parser.add_argument("--monitor-dir", type=Path, default=Path("../Monitor/build"))
    parser.add_argument("--stock-dir0", type=Path, default=Path("images/A/0"))
    parser.add_argument("--stock-dir1", type=Path, default=Path("images/A/1"))
    parser.add_argument("--staging-dir", type=Path, default=Path("images/ROM/0"))
    parser.add_argument("--diskdef", type=Path, default=Path("images/diskdef"))
    parser.add_argument("--format", dest="disk_format", default="zephyr80-rom")
    parser.add_argument("--build-dir", type=Path, default=Path("build"))
    parser.add_argument("--image", type=Path, default=Path("build/romdisk.img"))
    parser.add_argument("--chunk-prefix", type=Path, default=Path("build/romdisk.p"))
    parser.add_argument("--page-bytes", type=lambda v: int(v, 0), default=0xC000)
    parser.add_argument("--page-count", type=int, default=3)
    parser.add_argument("--block-size", type=lambda v: int(v, 0), default=1024)
    parser.add_argument("--dir-entries", type=int, default=128)
    parser.add_argument("--user", type=int, default=0)
    args = parser.parse_args()
    if not 0 <= args.user <= 15:
        parser.error("--user must be between 0 and 15")
    if args.page_count < 1:
        parser.error("--page-count must be positive")
    return args


def collect_sources(args: argparse.Namespace) -> list[tuple[Path, str]]:
    roots = {
        "hello": args.hello_dir,
        "monitor": args.monitor_dir,
        "stock0": args.stock_dir0,
        "stock1": args.stock_dir1,
    }
    resolved: list[tuple[Path, str]] = []
    missing: list[str] = []
    for root_key, name, cpm_name in MANIFEST:
        source = roots[root_key] / name
        if source.is_file():
            resolved.append((source, cpm_name))
        else:
            missing.append(str(source))
    if missing:
        raise SystemExit(
            "missing ROM disk input:\n  " + "\n  ".join(missing)
            + "\n\nBuild the contributing projects first "
              "(HelloWorld: `make com`, Monitor: `make`)."
        )
    return resolved


def stage(staging_dir: Path, sources: list[tuple[Path, str]]) -> None:
    staging_dir.mkdir(parents=True, exist_ok=True)
    for source, cpm_name in sources:
        shutil.copy2(source, staging_dir / cpm_name)


def read_directory(image: bytes, args: argparse.Namespace) -> list[tuple]:
    """Walk the CP/M directory the way cbios_storage_rom.asm's DPB describes it."""
    entries = []
    for offset in range(0, args.dir_entries * 32, 32):
        entry = image[offset : offset + 32]
        if entry[0] == 0xE5:            # free slot
            continue
        name = entry[1:9].decode("ascii", "replace").rstrip()
        # The high bit of each extension byte is an attribute flag, not the char.
        ext = bytes(b & 0x7F for b in entry[9:12]).decode("ascii", "replace").rstrip()
        extent = (entry[12] & 0x1F) | ((entry[14] & 0x3F) << 5)
        record_count = entry[15]
        # DSM is 143, below 256, so allocation pointers are single bytes.
        pointers = list(entry[16:32])
        entries.append((entry[0], f"{name}.{ext}" if ext else name,
                        extent, record_count, pointers))
    return entries


def extract_files(image: bytes, args: argparse.Namespace) -> dict[tuple[int, str], bytes]:
    records_per_block = args.block_size // 128
    partial: dict[tuple[int, str], dict[int, bytes]] = {}
    for user, name, extent, record_count, pointers in read_directory(image, args):
        records = partial.setdefault((user, name), {})
        for index in range(record_count):
            block = pointers[index // records_per_block]
            if block == 0:
                continue
            start = block * args.block_size + (index % records_per_block) * 128
            records[extent * 128 + index] = image[start : start + 128]
    return {
        key: b"".join(records[i] for i in sorted(records))
        for key, records in partial.items()
    }


def verify(image: bytes, args: argparse.Namespace,
           sources: list[tuple[Path, str]]) -> None:
    """Read the volume back and compare every file against its source.

    This deliberately does not use cpmcp to extract.  The cpmtools build on this
    machine aborts inside malloc when it re-reads a directory it wrote itself --
    on the existing zephyr80-vdrip format too, so it is not specific to this
    volume -- and a verification step that cannot run is no verification at all.
    Reading the directory here also checks the layout against the geometry the
    BIOS will use rather than against cpmtools' own idea of it, which is the
    thing that actually has to be right.

    CP/M stores whole 128-byte records, so a file comes back padded up to a
    record boundary.  That is normal: the CCP loads records, and the tail beyond
    the .COM image is never executed.
    """
    files = extract_files(image, args)
    problems: list[str] = []
    for source, cpm_name in sources:
        want = source.read_bytes()
        got = files.get((args.user, cpm_name))
        if got is None:
            problems.append(f"{cpm_name}: missing from the directory")
            continue
        padded = len(want) + (-len(want)) % 128
        if len(got) != padded or got[: len(want)] != want:
            problems.append(
                f"{cpm_name}: read back {len(got)} bytes, expected {padded}"
                f" ({len(want)} + record padding)"
            )
    if problems:
        raise SystemExit("ROM disk verification failed:\n  " + "\n  ".join(problems))


def build_image(args: argparse.Namespace, sources: list[tuple[Path, str]]) -> bytes:
    build_dir = args.build_dir.resolve()
    build_dir.mkdir(parents=True, exist_ok=True)

    # cpmtools resolves `diskdefs` relative to the working directory, so put a
    # copy there and run every cpmtools invocation from build/.
    shutil.copy2(args.diskdef, build_dir / "diskdefs")

    # Pre-size the volume to exactly what the DPB describes, then format in
    # place.  mkfs.cpm on its own emits only the directory, and cpmtools then
    # reads past EOF on any later access -- it aborts inside malloc rather than
    # reporting anything useful.  Creating the file at full capacity first keeps
    # every tool on solid ground and makes the page split exact.
    capacity = args.page_bytes * args.page_count
    scratch = build_dir / "romdisk.scratch.img"
    scratch.write_bytes(bytes([FILL]) * capacity)
    run(["mkfs.cpm", "-f", args.disk_format, scratch.name], cwd=build_dir)

    staging_dir = args.staging_dir.resolve()
    run(
        ["cpmcp", "-f", args.disk_format, scratch.name]
        + [str(staging_dir / cpm_name) for _, cpm_name in sources]
        + [f"{args.user}:"],
        cwd=build_dir,
    )

    data = scratch.read_bytes()
    verify(data, args, sources)

    if len(data) != capacity:
        raise SystemExit(
            f"ROM disk image is {len(data)} bytes, expected {capacity}"
        )
    scratch.unlink(missing_ok=True)
    return data


def main() -> int:
    args = parse_args()
    sources = collect_sources(args)
    stage(args.staging_dir, sources)
    data = build_image(args, sources)

    args.image.parent.mkdir(parents=True, exist_ok=True)
    args.image.write_bytes(data)

    for page in range(args.page_count):
        start = page * args.page_bytes
        chunk = data[start : start + args.page_bytes]
        chunk_path = Path(f"{args.chunk_prefix}{page + 1}.bin")
        chunk_path.write_bytes(chunk)

    used = sum((source.stat().st_size for source, _ in sources))
    print(
        f"ROM disk: {len(sources)} files, {used} bytes of content, "
        f"{len(data)} byte volume in {args.page_count} pages"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
