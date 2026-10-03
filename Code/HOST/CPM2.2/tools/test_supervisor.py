#!/usr/bin/env python3
"""Run the assembled transient-supervisor lifecycle using libqkz80.
Run make first. Requires a C++17 compiler and libqkz80 headers/library.
Executes the shipped page-0 and bank-7 images in one mode-11 view with ports
mocked; device and teardown routines are stubbed and their order recorded.
It does not model banking, the console, the IO Controller or FS2 storage.
"""
import argparse
from pathlib import Path
import re
import subprocess
import sys
sys.dont_write_bytecode = True
from generate_memory_docs import parse_listings, add_defs

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--build-dir', type=Path, default=Path('build'))
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
build = args.build_dir.resolve()

# The CCP the image was built with decides whether the shim cases apply.
match = re.search(r'^; CCP=(\w+)', (build / 'config.inc').read_text(), re.M)
if not match:
    raise SystemExit('config.inc does not record the CCP; rebuild')
ccp = match.group(1)

symbols, _ = parse_listings(sorted(build.glob('*.rst')))
for inc in ('memory.inc', 'platform.inc', 'modes.inc'):
    add_defs(symbols, root / 'src/layout' / inc)
symbol_file = build / 'supervisor-test-symbols.txt'
symbol_file.write_text(''.join(f'{name} {value}\n' for name, value in symbols.items()))
exe = build / 'supervisor-lifecycle-test'
subprocess.run(['c++', '-std=c++17', '-Wall', '-Wextra', '-O2',
                str(root / 'tests/supervisor_lifecycle.cpp'), '-lqkz80', '-o', str(exe)], check=True)
subprocess.run([str(exe), str(build / 'firmware.bin'), str(build / 'bank7.bin'),
                str(symbol_file), ccp], check=True)
