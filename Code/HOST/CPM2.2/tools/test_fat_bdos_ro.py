#!/usr/bin/env python3
"""Run the pure assembled FAT BDOS semantics, read and write, in libqkz80."""
import argparse
from pathlib import Path
import subprocess
import sys
sys.dont_write_bytecode = True
from generate_memory_docs import add_defs, parse_listing

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--build-dir", type=Path, default=Path("build"))
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
build = a.build_dir.resolve()
symbols, _ = parse_listing(build / "firmware.rst")
add_defs(symbols, root / "src/layout/memory.inc")
names = build / "fat-bdos-ro-test-symbols.txt"
names.write_text("".join(f"{k} {v}\n" for k, v in symbols.items()))
exe = build / "fat-bdos-ro-test"
subprocess.run(["c++", "-std=c++17", "-Wall", "-Wextra", "-O2",
                str(root / "tests/fat_bdos_ro.cpp"), "-lqkz80", "-o", str(exe)], check=True)
subprocess.run([str(exe), str(build / "firmware_flat.bin"), str(names)], check=True)
