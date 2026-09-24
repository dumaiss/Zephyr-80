#!/usr/bin/env python3
"""Run the assembled Milestone-1 synthetic FAT BIOS in libqkz80."""

import argparse
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True

from generate_memory_docs import add_defs, parse_listings


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--build-dir", type=Path, default=Path("build"))
args = parser.parse_args()

root = Path(__file__).resolve().parents[1]
build = args.build_dir.resolve()
symbols, _ = parse_listings(sorted(build.glob("*.rst")))
add_defs(symbols, root / "src/layout/memory.inc")

symbol_file = build / "fat-bios-m1-test-symbols.txt"
symbol_file.write_text("".join(f"{name} {value}\n" for name, value in symbols.items()))
exe = build / "fat-bios-m1-test"
subprocess.run(
    [
        "c++",
        "-std=c++17",
        "-Wall",
        "-Wextra",
        "-O2",
        str(root / "tests/fat_bios_m1.cpp"),
        "-lqkz80",
        "-o",
        str(exe),
    ],
    check=True,
)
subprocess.run(
    [str(exe), str(build / "firmware_flat.bin"), str(symbol_file)], check=True
)
