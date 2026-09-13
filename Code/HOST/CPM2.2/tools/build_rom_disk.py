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
# the software volumes already use, so a
# utility is called the same thing on both disks.
#
# SUBMIT is deliberately absent: the CCP hard-codes drive A for $$$.SUB
# (cpm22.asm "always use drive A for submit"), so it cannot work on a read-only
# A:.  ZSID is carried instead of DDT because DDT's assembler and disassembler
# are 8080-only, which is a real handicap on a Z80.
# The volume is the rescue disk: what you want present when the machine is in
# trouble and A: is the only volume you can trust.  Bring-up, benchmark and
# destructive tools (../Utilities `make diagnostic`) are never carried.  Four of
# them destroy data on whatever card is inserted, with no drive letter to get
# wrong:
#   SDWRITE  overwrites block 0 and with it the partition table
#   SDREC    overwrites records 0-7, which is the head of the CP/M directory
#   SDSOAK   writes across multiple LBAs as an addressing stress test
#   SDBENCH  writes a fixed high LBA repeatedly and does not restore it
# A rescue disk that ships those is a rescue disk that can finish the job.  They
# still build; copy one to a work drive when it is needed.

# (root, source name, CP/M name)
MANIFEST = (
    # --- Rescue and provisioning ----------------------------------------
    # Non-destructive version, transport, power and controller-health check.
    ("utils", "ioc_ping.com", "PING.COM"),
    # Deliberate recovery: resets host and controller together.
    ("utils", "ioc_reset.com", "RESET.COM"),
    # Non-destructive command-lane read; separates controller/SD failure from
    # CP/M filesystem failure.  The BIOS media probe uses the same command.
    ("utils", "ioc_sd_read.com", "SDREAD.COM"),
    # Provisioning, not a soak test: a fresh SD volume needs its directory
    # initialised.  Destructive, and kept only because without it a new card
    # cannot be made usable at all.  See the warning note below.
    ("utils", "ioc_sdfmt.com", "SDFMT.COM"),
    # Separates IOC HID translation and queueing from BIOS CONST/CONIN.
    ("utils", "hidkey.com", "HIDKEY.COM"),
    # Passive normal-firmware USB/F310 enumeration and report status.
    ("utils", "padstat.com", "PADSTAT.COM"),
    # Arms or disarms the serial console tee.  Rescue tool by definition: it is
    # what you reach for when the screen is dark, or what turns the mirror off
    # again once a terminal has been unplugged.
    ("utils", "sercon.com", "SERCON.COM"),
    # The only recovery environment that still works with no usable disk:
    # L loads Intel HEX over the console, DB dumps a bank, I/O reach ports.
    # Built from source rather than copied, so it always matches the tree.
    ("monitor", "zephyr80_monitor.bin", "MONITOR.COM"),
    # Required to provision and inspect the SD volume from the ROM disk.
    ("stock0", "pip.com", "PIP.COM"),
    ("stock0", "STAT.COM", "STAT.COM"),
    # User-facing console configuration, not hardware bring-up.  Built from
    # source in ../Utilities: these used to be shipped as prebuilt binaries
    # carried in a software volume, so the ROM could ship a build that no longer
    # matched the source it was supposedly made from.
    ("utils", "nowrap.com", "NOWRAP.COM"),
    ("utils", "wrapon.com", "WRAPON.COM"),
    # General Z80 diagnosis that adds no BIOS instrumentation.  ZSID rather
    # than DDT: DDT's assembler and disassembler are 8080-only.
    ("stock1", "ZSID.COM", "ZSID.COM"),
    ("stock1", "DUMP.COM", "DUMP.COM"),
    # Reports which addressing mode each storage unit is really using -- an
    # 8 MiB file on a FAT card, or the raw card.  A rescue tool because the
    # alternative is inferring the mode from whether the disk looks right,
    # which is the slowest possible way to discover that an image failed to
    # mount and the firmware fell back to raw.
    ("utils", "volinfo.com", "VOLINFO.COM"),
    # Reports which CCP and BDOS are actually EXECUTING, read out of RAM rather
    # than inferred from what was meant to be flashed.  Uses no IO Controller
    # traffic, so it answers when the link is dead -- which is when the question
    # tends to be asked.
    ("utils", "sysid.com", "SYSID.COM"),
    # The /SHARED/ folder tools.  Rescue tools in the most literal sense: with a
    # FAT card in the socket these are how a file gets off this machine, or onto
    # it, when nothing else works -- no serial link, no second drive.  None can
    # reach /CPM/: the controller builds every path itself under /SHARED/ and
    # rejects any name carrying a separator, which is what keeps a user program
    # structurally unable to touch a mounted disk image.
    ("utils", "sddir.com", "SDDIR.COM"),
    ("utils", "sdget.com", "SDGET.COM"),
    ("utils", "sdput.com", "SDPUT.COM"),
    ("utils", "sddel.com", "SDDEL.COM"),

    # --- Z-System general-purpose tools ----------------------------------
    # Richard Conn's ZCPR2 utility set, plus NSWEEP.  Prebuilt binaries, not
    # built from source here: they are third-party CP/M software, carried in
    # ../Utilities/zsys.
    #
    # The binaries in ../Utilities/zsys are UNINSTALLED: they carry ZCPR2's
    # distribution defaults, an external path at 0040h and a multiple command
    # line buffer at FF00h.  On this machine 0040h is page-zero noise (it decodes
    # as a path to drive O:) and FF00h is the BDOS facade's stack.  So every
    # ZCPR2 utility is installed as it is staged -- see install_zcpr2_utility --
    # the way GENINS would: no external path, no command line buffer, and an
    # internal path of current, B0, A0.  The checked-in files stay pristine.
    #
    # ../CPM2.2/zcpr2 is built with MULTCMD=FALSE, INTPATH=TRUE and WHEEL=FALSE,
    # so there is no external path buffer, no memory named-directory buffer and
    # no wheel byte for a tool to use.  Named directories still work: CD, PWD
    # and MKDIR read and write a NAMES.DIR file, found on that internal path.
    #
    # Not carried:
    #   LD                         loads NAMES.DIR into a memory buffer
    #   PATH                       edits the external path
    #   WHEEL                      needs the wheel byte
    #   STARTUP                    needs the multiple-command buffer
    #   SUB, ZEX                   $$$.SUB is hard-coded to drive A, which is
    #                              this read-only ROM; ZEX also recognises the
    #                              CCP by the high bit on CPRMPT, which zcpr2
    #                              deliberately clears for this 8-bit console
    #   DEVICE, IOLOADER, RECORD   need CHBIOSZ's SYSIO redirectable drivers
    #   CONFIG, TINIT              program a TVI 950 terminal
    #   MENU, MCHECK, GENINS,
    #   LDIRZ, LRUNZ,
    #   CCPLOC, ECHO               no role on a rescue disk, or redundant with
    #                              something already carried (CCPLOC vs SYSID)
    #   XDIR, ERASE, RENAME,
    #   PROTECT, COMPARE, DIFF     work, but NSWP does erase/rename/attributes
    #                              and lists sizes and free space, CRC answers
    #                              "is this the same file", and ZCPR2 has a
    #                              resident DIR.  They are out on SPACE, not on
    #                              function -- see the budget note below.
    #
    # Full-screen file manager: copy, erase, rename, view, tag, set attributes,
    # across every user area.  The one tool that makes this volume self
    # sufficient for file work without PIP command syntax.
    ("zsys", "NSWP.COM", "NSWP.COM"),
    # Command-line multi-file copy with automatic verify, and an interactive
    # mode.  This is the machine's working copy tool, not a convenience: the
    # stock DRI PIP carried above does not run under ZCPR2/ZSDOS, so under that
    # configuration MCOPY and NSWP are the only two things on this volume that
    # can move a file.  PIP stays because it still works -- and is still the
    # documented way to populate the card -- under the stock CCP and BDOS,
    # which this same ROM manifest also builds.
    #
    # Unlike most of Conn's set, MCOPY needs nothing installed: it has no
    # external-address abort path, and `dir:` accepts the plain DU: form.
    ("zsys", "MCOPY.COM", "MCOPY.COM"),
    # File CRC.  Directly relevant on this machine: every file that arrives
    # crosses the IO Controller link and the SD path, and this is how you find
    # out whether it arrived intact rather than inferring it from whether the
    # program runs.
    ("zsys", "CRC.COM", "CRC.COM"),
    # Named directories.  MKDIR edits NAMES.DIR, CD logs into a directory by
    # name, PWD lists the names and shows the current one.  The file lives on
    # B0 (A: is read only) or wherever the internal path finds it first.
    ("zsys", "CD.COM", "CD.COM"),
    ("zsys", "PWD.COM", "PWD.COM"),
    ("zsys", "MKDIR.COM", "MKDIR.COM"),
)

# The volume is 144 KiB in 1 KiB blocks (DSM=143 in cbios_storage_rom.asm), of
# which 4 blocks are the 128-entry directory -- 140 blocks of content, and that
# is a BIOS-side constant, not something this script can grow.
#
# Space, not usefulness, decides what is carried: when the set outgrows the
# volume, cpmcp stops the build with "device full".
#
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
    parser.add_argument("--utils-dir", type=Path, default=Path("../Utilities/build"))
    parser.add_argument("--zsys-dir", type=Path, default=Path("../Utilities/zsys"))
    parser.add_argument("--monitor-dir", type=Path, default=Path("../Monitor/build"))
    parser.add_argument("--stock-dir0", type=Path, default=Path("../Software/disk1/0"))
    parser.add_argument("--stock-dir1", type=Path, default=Path("../Software/disk1/1"))
    parser.add_argument("--staging-dir", type=Path, default=Path("build/romdisk-stage"))
    parser.add_argument("--diskdef", type=Path, default=Path("config/diskdef"))
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


def _find(root: Path, name: str) -> Path | None:
    """Locate one manifest entry, matching the filename case-insensitively.

    CP/M filenames are case-insensitive and canonically upper case, while the
    trees these are collected from are a mixture: the software volumes are
    normalised lower case, the build directories use whatever the source file
    was called.  Matching exactly meant STAT.COM and stat.com were different
    inputs, and the manifest had to know which spelling each tree happened to
    use -- a difference that carries no meaning on the target.
    """
    exact = root / name
    if exact.is_file():
        return exact
    if not root.is_dir():
        return None
    wanted = name.lower()
    for candidate in sorted(root.iterdir()):
        if candidate.is_file() and candidate.name.lower() == wanted:
            return candidate
    return None


def collect_sources(args: argparse.Namespace) -> list[tuple[Path, str]]:
    roots = {
        "utils": args.utils_dir,
        "zsys": args.zsys_dir,
        "monitor": args.monitor_dir,
        "stock0": args.stock_dir0,
        "stock1": args.stock_dir1,
    }
    resolved: list[tuple[Path, str]] = []
    missing: list[str] = []
    for root_key, name, cpm_name in MANIFEST:
        source = _find(roots[root_key], name)
        if source is not None:
            resolved.append((source, cpm_name))
        else:
            missing.append(str(roots[root_key] / name))
    if missing:
        raise SystemExit(
            "missing ROM disk input:\n  " + "\n  ".join(missing)
            + "\n\nBuild the contributing projects first "
              "(Utilities: `make`, Monitor: `make`).  The zsys entries are\n"
              "prebuilt third-party binaries -- they are not built, they are "
              "checked in."
        )
    return resolved


def stage(staging_dir: Path, sources: list[tuple[Path, str]]) -> None:
    # Start empty, so a tool dropped from the manifest does not linger here.
    shutil.rmtree(staging_dir, ignore_errors=True)
    staging_dir.mkdir(parents=True, exist_ok=True)
    for source, cpm_name in sources:
        target = staging_dir / cpm_name
        shutil.copy2(source, target)
        target.write_bytes(install_zcpr2_utility(source.read_bytes()))


# ZCPR2 utility installation, the fields GENINS sets.  Every Conn utility opens
# with JP START and this block; "chdir" (the privileged-area password) at 1Fh is
# how one is recognised.
#   04h  external path address; 0000h selects the internal path (the program
#        tests this address, not the byte at 03h)
#   06h  internal path: up to eight disk/user pairs, disks 1-based, '$' current
#   16h  end of path
#   17h  multiple command line buffer available (0 = no); address at 18h
Z2_SIGNATURE_OFFSET = 0x1F
Z2_SIGNATURE = b"chdir"
Z2_INTERNAL_PATH = bytes([ord("$"), ord("$"), 2, 0, 1, 0])   # current, B0, A0


def install_zcpr2_utility(data: bytes) -> bytes:
    """Return data installed for this machine if it is a ZCPR2 utility, else unchanged."""
    if len(data) < 0x24 or data[0] != 0xC3 or \
            data[Z2_SIGNATURE_OFFSET:Z2_SIGNATURE_OFFSET + len(Z2_SIGNATURE)] != Z2_SIGNATURE:
        return data
    out = bytearray(data)
    out[0x04:0x06] = b"\x00\x00"
    out[0x06:0x16] = Z2_INTERNAL_PATH + bytes(16 - len(Z2_INTERNAL_PATH))
    out[0x16] = 0x00
    out[0x17] = 0x00
    return bytes(out)


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
        # Compare with what was staged: ZCPR2 utilities are installed on the way.
        want = (args.staging_dir.resolve() / cpm_name).read_bytes()
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
