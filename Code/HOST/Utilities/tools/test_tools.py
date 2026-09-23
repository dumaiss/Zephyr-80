#!/usr/bin/env python3
"""Run MKDIR, RMDIR, PWD, FSTAT, MV and CP against volume models in libqkz80."""
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
root = Path(__file__).resolve().parents[1]
exe = root / "build/tools-test"
subprocess.run(["c++", "-std=c++17", "-Wall", "-Wextra", "-O2",
                str(root / "tests/tools.cpp"), "-lqkz80", "-o", str(exe)], check=True)
subprocess.run([str(exe)] + [str(root / f"build/{n}.com")
                             for n in ("mkdir", "rmdir", "pwd", "fstat", "mv", "cp")], check=True)
