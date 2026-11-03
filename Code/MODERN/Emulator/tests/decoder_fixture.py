#!/usr/bin/env python3
"""Derive Rev13 expectations from the authoritative WinCUPL Boolean equations.

This deliberately does not import/transcribe the C++ region rules. Negated
RAM_A assignments describe the zeros of the physical pins; !RD/!WR inputs
are asserted-high CUPL symbols, whereas MREQ is the physical active-low pin.
The ROM/SRAM CS equations describe asserted selects (active-low output pins).
No matching WinCUPL .si vectors are present in the supplied HDL checkout.
"""
import argparse
import ast
import hashlib
import json
from pathlib import Path
import re

HERE = Path(__file__).resolve().parent


def digest(data):
    return hashlib.sha256(data).hexdigest()


def expression(text):
    tokens = re.findall(r"[A-Z][A-Z0-9_]*|[!&#()]", text)
    pos = 0

    def atom():
        nonlocal pos
        tok = tokens[pos]
        pos += 1
        if tok == "!":
            node = atom()
            return lambda env: not node(env)
        if tok == "(":
            node = disjunction()
            assert tokens[pos] == ")"
            pos += 1
            return node
        return lambda env: env[tok]

    def conjunction():
        nonlocal pos
        parts = [atom()]
        while pos < len(tokens) and tokens[pos] == "&":
            pos += 1
            parts.append(atom())
        return lambda env: all(part(env) for part in parts)

    def disjunction():
        nonlocal pos
        parts = [conjunction()]
        while pos < len(tokens) and tokens[pos] == "#":
            pos += 1
            parts.append(conjunction())
        return lambda env: any(part(env) for part in parts)

    result = disjunction()
    assert pos == len(tokens)
    return result


def derive(pld_path, model_path):
    source = pld_path.read_bytes()
    plain = re.sub(r"/\*.*?\*/", "", source.decode(), flags=re.S)
    equations = {}
    for name, rhs in re.findall(r"^\s*(!?[A-Z][A-Z0-9_]*)\s*=\s*(.*?);", plain, re.M | re.S):
        equations[name] = expression(rhs)
    assert set(equations) == {"ROM_READ", "!RAM_A16", "!RAM_A17", "!RAM_A18", "ROM_CS", "SRAM_CS"}
    # Execute only the actual reference class, avoiding any simulator runtime.
    model_source = model_path.read_bytes()
    node = next(n for n in ast.parse(model_source).body if isinstance(n, ast.ClassDef) and n.name == "MemoryDecoder")
    namespace = {}
    exec(compile(ast.Module(body=[node], type_ignores=[]), str(model_path), "exec"), namespace)
    reference = namespace["MemoryDecoder"](13)
    rows = []
    select_checks = 0
    for latch in range(256):
        for region in range(8):
            env = {"A13": bool(region & 1), "A14": bool(region & 2), "A15": bool(region & 4),
                   "MEM_MODE0": bool(latch & 8), "MEM_MODE1": bool(latch & 16)}
            for bit in range(3):
                env[f"BANK_Q{bit}"] = bool(latch & (1 << bit))
                env[f"PAGE{bit}"] = bool(latch & (1 << (5 + bit)))
            env["ROM_READ"] = equations["ROM_READ"](env)
            bank = sum((not equations[f"!RAM_A{16 + bit}"](env)) << bit for bit in range(3))
            for mreq in range(2):
                for rd in range(2):
                    for wr in range(2):
                        env.update(MREQ=mreq, RD=not rd, WR=not wr)
                        actual = tuple(int(equations[n](env)) for n in ("ROM_CS", "SRAM_CS"))
                        assert actual == reference.chip_selects(mreq, rd, wr, latch), (latch, region, mreq, rd, wr)
                        select_checks += 1
            env.update(MREQ=0, RD=True, WR=False)
            flash, ram = (int(equations[n](env)) for n in ("ROM_CS", "SRAM_CS"))
            assert flash + ram == 1
            env.update(RD=False, WR=True)
            assert not equations["ROM_CS"](env) and equations["SRAM_CS"](env)
            for low in (0, 0x123, 0x1000, 0x1fff):
                address = (region << 13) | low
                assert bank == reference.bank_of(address, latch), (latch, address, bank)
                write_address = (bank << 16) | address
                read_address = (((latch >> 5) << 16) | address) if flash else write_address
                rows.append(f"{latch:02x} {address:04x} {flash} {read_address:05x} {write_address:05x}\n")
    header = ("# Rev13 fixture derived from MEM_DECODER.pld Boolean equations, including inverted RAM outputs.\n"
              f"# PLD SHA256 {digest(source)}\n"
              "# latch cpu_address read_flash read_physical write_physical (hex except read_flash)\n")
    metadata = {"source": "Code/HDL/WinCUPL/src/MEM_DECODER.pld", "source_sha256": digest(source),
                "reference": "ZephyrOS/tests/z80sim.py:MemoryDecoder", "reference_sha256": digest(model_source),
                "rows": len(rows), "select_checks": select_checks,
                "coverage": "256 latches x 8 decoded regions x start/interior/mid/end; reads and writes; all bus control combinations",
                "vectors": "No .si vectors found in supplied HDL tree; ignored generated .sim uses older equations and is not an oracle."}
    return (header + "".join(rows)).encode(), (json.dumps(metadata, indent=2) + "\n").encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zephyr-root", required=True, type=Path)
    parser.add_argument("--konaos-root", required=True, type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    data, metadata = derive(args.zephyr_root / "Code/HDL/WinCUPL/src/MEM_DECODER.pld", args.konaos_root / "tests/z80sim.py")
    for name, expected in (("rev13.txt", data), ("rev13-provenance.json", metadata)):
        path = HERE / "fixtures" / name
        if args.check:
            assert path.read_bytes() == expected, f"Stale fixture: {path}"
        else:
            path.write_bytes(expected)
    print("PASS PLD fixture: 8192 read/write mappings; 16384 control/select comparisons with MemoryDecoder(13)")
    print(f"fixture sha256={digest(data)}")


if __name__ == "__main__":
    main()
