#!/usr/bin/env python3
"""Run the assembled LS.COM against models of both drive types in libqkz80."""
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
root = Path(__file__).resolve().parents[1]
exe = root / "build/ls-test"
subprocess.run(["c++", "-std=c++17", "-Wall", "-Wextra", "-O2",
                str(root / "tests/ls.cpp"), "-lqkz80", "-o", str(exe)], check=True)
subprocess.run([str(exe), str(root / "build/ls.com")], check=True)
