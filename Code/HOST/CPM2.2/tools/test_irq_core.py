#!/usr/bin/env python3
"""Run assembled IRQ code using the installed libqkz80 (ports mocked).
Run make first. Requires a C++17 compiler and libqkz80 headers/library.
This does not model SIO/CTC electronics, banking, or replace TIMTEST on hardware.
"""
import argparse
from pathlib import Path
import subprocess
import re
import sys
sys.dont_write_bytecode = True
from generate_memory_docs import parse_listing, add_defs

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--build-dir', type=Path, default=Path('build'))
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
build = args.build_dir.resolve()
# CPU-global instructions may only be emitted by the IRQ core.
for source in (root / 'src').glob('*.asm'):
    if source.name == 'cbios_irq.asm':
        continue
    for line in source.read_text().splitlines():
        instruction = line.split(';', 1)[0].strip().lower()
        if re.match(r'(?:di|ei|reti|retn|im)\b|ld\s+(?:i,|a,i\b)', instruction):
            raise SystemExit(f'CPU interrupt policy outside IRQ core: {source}: {line}')
symbols, _ = parse_listing(build / 'firmware.rst')
add_defs(symbols, root / 'src/cbios_defs.inc')
symbol_file = build / 'irq-test-symbols.txt'
symbol_file.write_text(''.join(f'{name} {value}\n' for name, value in symbols.items()))
exe = build / 'irq-core-test'
subprocess.run(['c++', '-std=c++17', '-Wall', '-Wextra', '-O2',
                str(root / 'tests/irq_core.cpp'), '-lqkz80', '-o', str(exe)], check=True)
subprocess.run([str(exe), str(build / 'firmware_flat.bin'), str(symbol_file)], check=True)
