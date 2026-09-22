#!/usr/bin/env python3
"""Run the assembled ZFCB.COM against a model of CP/M's FCB calls in libqkz80."""
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
root = Path(__file__).resolve().parents[1]
exe = root / "build/zfcb-test"
subprocess.run([
    "c++", "-std=c++17", "-Wall", "-Wextra", "-O2",
    str(root / "tests/zfcb.cpp"), "-lqkz80", "-o", str(exe),
], check=True)
subprocess.run([str(exe), str(root / "build/zfcb.com")], check=True)
