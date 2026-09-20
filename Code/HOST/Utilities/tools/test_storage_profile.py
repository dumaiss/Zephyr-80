#!/usr/bin/env python3
"""STORAGE_PROFILE: run after make in Utilities and CPM2.2. Requires libqkz80.
Mocks CALL 5/timer service; executes the actual assembled benchmark and BIOS
match routine. Does not claim to simulate the facade, SD card, or timing.
Removal: repository docs/storage-profiling.md.
"""
from pathlib import Path
import subprocess
import sys
sys.dont_write_bytecode = True
root = Path(__file__).resolve().parents[1]
bios = root.parent / 'CPM2.2'
sys.path.insert(0, str(bios / 'tools'))
from generate_memory_docs import parse_listing, add_defs
for project, name in [(root, 'ioc_sdbench'), (bios, 'firmware')]:
    symbols, _ = parse_listing(project / 'build' / (name + '.lst'))
    if project == bios:
        add_defs(symbols, bios / 'src/cbios_defs.inc')
    (root / 'build' / (name + '-profile-symbols.txt')).write_text(
        ''.join(f'{n} {v}\n' for n, v in symbols.items()))
exe = root / 'build/storage-profile-test'
subprocess.run(['c++', '-std=c++17', '-Wall', '-Wextra', '-O2',
    str(root / 'tests/storage_profile.cpp'), '-lqkz80', '-o', str(exe)], check=True)
subprocess.run([str(exe), str(root / 'build/ioc_sdbench.com'),
    str(root / 'build/ioc_sdbench-profile-symbols.txt'),
    str(bios / 'build/firmware_flat.bin'),
    str(root / 'build/firmware-profile-symbols.txt')], check=True)
