#!/usr/bin/env python3
"""Flag unreachable code: a label nothing jumps to, sitting after an
unconditional control transfer.

This is not a general dead-code pass -- most unreferenced labels in this tree
are legitimate, being fall-through entry points, .globl exports or documentation
markers.  The narrow case here is the one that has actually cost debugging time,
twice:

  IOC_SDSOAK   the CRC computation and the trailer send sat after a `jr`, so the
               CRC was never computed and the trailer never sent.  Every write
               was rejected by the MCU.

  IOCBULK      the CRC trailer read sat after `jr IOCBULK_CHUNK`, so
               ioc_bulk_crc was never loaded.  The comparison then ran against
               IOCBULKW's leftover value -- which matched, because the soak
               reads back the block it just wrote.  It passed 3200 times and
               was only exposed by a test that read a different record than it
               had last written.

Both are invisible to the assembler: the code is valid, it is simply never
entered.  Neither is visible to a passing test either, which is the point.
"""
import re
import sys
import glob

LABEL   = re.compile(r'^([A-Za-z_][A-Za-z_0-9]*):')
# Unconditional transfers only.  A conditional jump falls through, so a label
# after one is reachable.
UNCOND  = re.compile(r'^\s*(jp|jr)\s+(?!nz,|z,|nc,|c,|po,|pe,|p,|m,)\S|^\s*(ret|reti|retn)\s*$',
                     re.IGNORECASE)


def code_of(line):
    return line.split(';')[0].rstrip()


def collect(paths):
    """Reference set across the WHOLE tree, not one file.

    Scanning per-file was the first attempt and it reported 28 findings, every
    one of them wrong: the CP/M jump table in zephyr.asm is entered from
    outside, and half the console driver is called from other modules.  A label
    is only unreachable if nothing ANYWHERE names it -- and a .globl export
    means something outside this tree may.
    """
    refs = set()
    exported = set()
    files = {}

    for path in paths:
        lines = open(path).read().split('\n')
        files[path] = lines
        for line in lines:
            code = code_of(line)
            if LABEL.match(line):
                code = code[code.index(':') + 1:]
            for m in re.finditer(r'(?<![A-Za-z_0-9.])([A-Za-z_][A-Za-z_0-9]*)', code):
                refs.add(m.group(1))
            g = re.match(r'\s*\.globl\s+(.*)', code, re.IGNORECASE)
            if g:
                exported.update(n.strip() for n in g.group(1).split(','))

    return files, refs, exported


def scan(path, lines, refs, exported):
    findings = []

    for idx, line in enumerate(lines):
        m = LABEL.match(line)
        if not m:
            continue
        name = m.group(1)
        if name in refs or name in exported:
            continue

        # Walk back over blank and comment-only lines to the previous statement.
        j = idx - 1
        while j >= 0 and code_of(lines[j]).strip() == '':
            j -= 1
        if j < 0:
            continue
        if not UNCOND.match(code_of(lines[j])):
            continue

        # A jump table entry is preceded AND followed by a `jp`, and is entered
        # by address rather than by name.  The CP/M BIOS vector table in
        # zephyr.asm is thirty of these in a row.
        k = idx + 1
        while k < len(lines) and code_of(lines[k]).strip() == '':
            k += 1
        if k < len(lines) and re.match(r'\s*jp\s', code_of(lines[k]), re.IGNORECASE):
            continue

        findings.append((idx + 1, name, code_of(lines[j]).strip()))

    return findings


def main(argv):
    paths = argv[1:] or sorted(glob.glob('src/*.asm'))
    files, refs, exported = collect(paths)
    total = 0
    for path in paths:
        for line, name, prev in sorted(scan(path, files[path], refs, exported)):
            print(f"{path}:{line}: unreachable: '{name}' is never referenced "
                  f"and follows '{prev}'")
            total += 1

    if total:
        print(f"check_reachable: {total} unreachable label(s)")
        return 1

    print("check_reachable: OK (no unreachable labels)")
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
