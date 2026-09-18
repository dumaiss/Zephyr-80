#!/usr/bin/env python3
"""Build full boot pages 0 and 7 from the linked address space.

Page 0 holds common memory and the reset bootstrap. Page 7 holds the identical
bootstrap, ZSDOS/BIOS at 2000h-DFFFh, and a pristine CCP at CCP_RESTORE_BASE.
Only these boot pages seed SRAM; drive-A pages are independent ROM storage.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path

BODY_LO = 0x2000
BODY_HI = 0xE000      # end of the managed OS body; full physical page is copied
COMMON_LO = 0xE000
CCP_SLOT = 0x800


def constants(paths: list[Path]) -> dict[str, str]:
    table: dict[str, str] = {}
    pattern = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([^;\n]+)", re.M)
    for path in paths:
        for name, expr in pattern.findall(path.read_text(errors="replace")):
            table.setdefault(name, expr.strip())
    return table


def value(table: dict[str, str], name: str, depth: int = 0) -> int:
    if depth > 20:
        raise SystemExit(f"constant {name}: recursive definition")
    if name not in table:
        raise SystemExit(f"constant {name}: not defined")
    expr = table[name]

    def resolve(match: re.Match) -> str:
        token = match.group(0)
        if re.fullmatch(r"0[xX][0-9A-Fa-f]+|[0-9]+", token):
            return str(int(token, 0))
        return str(value(table, token, depth + 1))

    text = re.sub(r"0[xX][0-9A-Fa-f]+|[A-Za-z_][A-Za-z0-9_]*|[0-9]+", resolve, expr)
    if not re.fullmatch(r"[0-9+\-*()<>| ]+", text):
        raise SystemExit(f"constant {name}: cannot evaluate {expr!r}")
    return int(eval(text))  # digits and arithmetic only, checked above


def emitted(ihx: Path) -> set[int]:
    addresses: set[int] = set()
    base = 0
    for line in ihx.read_text().splitlines():
        if not line.startswith(":"):
            continue
        count = int(line[1:3], 16)
        address = int(line[3:7], 16)
        kind = int(line[7:9], 16)
        if kind == 0x04:
            base = int(line[9:13], 16) << 16
        elif kind == 0x00:
            addresses.update(range(base + address, base + address + count))
    return addresses


def spans(addresses: list[int]) -> str:
    if not addresses:
        return "none"
    out, start, prev = [], addresses[0], addresses[0]
    for a in addresses[1:]:
        if a != prev + 1:
            out.append((start, prev))
            start = a
        prev = a
    out.append((start, prev))
    return ", ".join(f"{s:04X}h-{e:04X}h" for s, e in out[:6]) + (" ..." if len(out) > 6 else "")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--flat", type=Path, required=True, help="64 KiB makebin image")
    parser.add_argument("--ihx", type=Path, required=True, help="the linked Intel HEX")
    parser.add_argument("--defs", type=Path, required=True)
    parser.add_argument("--wrapper", type=Path, required=True)
    parser.add_argument("--ccp", type=Path, required=True)
    parser.add_argument("--zsdos", type=Path, required=True)
    parser.add_argument("--page0", type=Path, required=True)
    parser.add_argument("--bank7", type=Path, required=True)
    args = parser.parse_args()

    table = constants([args.wrapper, args.defs])
    cbase = value(table, "CBASE")
    fbase = value(table, "FBASE")
    zsdos_org = value(table, "ZSDOS_ORG")
    zsdos_size = value(table, "ZSDOS_SIZE")
    bios7 = value(table, "BIOS7_BASE")

    flat = args.flat.read_bytes()
    if len(flat) != 0x10000:
        raise SystemExit(f"{args.flat}: {len(flat)} bytes, expected 65536")

    used = emitted(args.ihx)
    low = sorted(a for a in used if value(table, "BOOTSTRAP_LIMIT") <= a < BODY_LO)
    if low:
        raise SystemExit("bytes assembled into the caller window, which belongs to the "
                         f"running program: {spans(low)}")
    restore = value(table, "CCP_RESTORE_BASE")
    restore_size = value(table, "CCP_RESTORE_SIZE")
    scratch_end = value(table, "MOVE_BUFFER") + value(table, "MOVE_BUFFER_SIZE")
    if not scratch_end <= restore < restore + restore_size <= BODY_HI:
        raise SystemExit("CCP restore asset overlaps scratch or leaves the OS body")
    for start, end in [(0xc000, scratch_end), (restore, restore + restore_size)]:
        if any(start <= a < end for a in used):
            raise SystemExit(f"assembled bytes overlap private stacks/scratch or CCP restore: {start:04X}-{end:04X}")
    zs = sorted(a for a in used if zsdos_org <= a < zsdos_org + zsdos_size)
    if zs:
        raise SystemExit(f"bytes assembled where ZSDOS goes: {spans(zs)}")
    if bios7 != zsdos_org + zsdos_size:
        raise SystemExit(f"BIOS7_BASE {bios7:04X}h is not ZSDOS_ORG + ZSDOS_SIZE; ZSDOS "
                         "computes its BIOS as ZSDOS+1000h")

    page0 = bytearray(flat)
    page0[BODY_LO:COMMON_LO] = bytes(COMMON_LO - BODY_LO)
    bank7 = bytearray(0x10000)
    bank7[BODY_LO:BODY_HI] = flat[BODY_LO:BODY_HI]
    bootstrap_limit = value(table, "BOOTSTRAP_LIMIT")
    bank7[:bootstrap_limit] = page0[:bootstrap_limit]

    zsdos = args.zsdos.read_bytes()
    if len(zsdos) != zsdos_size:
        raise SystemExit(f"{args.zsdos}: {len(zsdos)} bytes, the slot is {zsdos_size}")
    if zsdos[:6] != b"ZSDOS " or zsdos[6] != 0xC3:
        raise SystemExit(f"{args.zsdos} does not start with ZSDOS's serial and entry jump")
    bank7[zsdos_org:zsdos_org + zsdos_size] = zsdos
    if bank7[bios7] != 0xC3:
        raise SystemExit(f"no jump at {bios7:04X}h, where ZSDOS expects its BIOS table")

    ccp = args.ccp.read_bytes()
    if len(ccp) != CCP_SLOT or ccp[0] != 0xC3 or ccp[3] != 0xC3:
        raise SystemExit(f"{args.ccp} is not a {CCP_SLOT}-byte CCP with a two-entry header")
    page0[cbase:cbase + CCP_SLOT] = ccp
    if restore_size != len(ccp):
        raise SystemExit("CCP restore slot size differs from the CCP")
    bank7[restore:restore + restore_size] = ccp
    if page0[fbase] != 0xC3:
        raise SystemExit(f"FBASE at {fbase:04X}h is not a jump")

    args.page0.write_bytes(bytes(page0))
    args.bank7.write_bytes(bytes(bank7))
    body = sorted(a for a in used if BODY_LO <= a < BODY_HI)
    common = sorted(a for a in used if a >= COMMON_LO)
    print(f"  bank 7: ZSDOS {zsdos_org:04X}h, BIOS {bios7:04X}h; "
          f"{len(body)} BIOS bytes in {spans(body)}")
    print(f"  common: {len(common)} bytes; CCP at {cbase:04X}h, FBASE {fbase:04X}h")


if __name__ == "__main__":
    main()
