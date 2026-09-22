#!/usr/bin/env python3
"""Run the assembled ZFW command parser and exit path in libqkz80."""
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
root = Path(__file__).resolve().parents[1]
bios_tools = root.parent / "CPM2.2" / "tools"
sys.path.insert(0, str(bios_tools))
from generate_memory_docs import parse_listing

symbols, _ = parse_listing(root / "build/zfw.lst")
symbol_file = root / "build/zfw-test-symbols.txt"
symbol_file.write_text("".join(f"{name} {value}\n" for name, value in symbols.items()))
exe = root / "build/zfw-test"
subprocess.run([
    "c++", "-std=c++17", "-Wall", "-Wextra", "-O2",
    str(root / "tests/zfw.cpp"), "-lqkz80", "-o", str(exe),
], check=True)
subprocess.run([
    str(exe), str(root / "build/zfw.com"), str(symbol_file),
], check=True)
