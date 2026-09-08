#!/bin/sh
# Assemble and link ZSDOS for Zephyr-80, and emit the 3584-byte BDOS image.
#
# ZSDOS is Z80 source for Al Hawley's ZMAC (or SLR's assemblers); nothing in the
# host toolchain reads it, so it is built the way RomWBW builds it -- under a
# CP/M emulator.  RunCPM stands in for RomWBW's ZXCC.
#
# Three things this works around, all found the hard way:
#
#   * DRI's LINK.COM aborts on ZMAC's output.  Microsoft's LINK-80 (L80.COM)
#     reads it fine, so that is what is used.  L80 writes a .COM-style image
#     that begins at 0100h whatever the link origin, so linking at CC00h gives a
#     55 KiB file that is mostly zeros; l80_slice.py cuts out the real 3.5 KiB.
#
#   * ZMAC consumes whatever console input follows it, so EXIT.COM never runs in
#     the same session and RunCPM idles until killed.  Rather than pay a fixed
#     timeout, the assembly is watched for its completion line and stopped as
#     soon as it appears.  The link runs in a second session, where EXIT works.
#
#   * CP/M tools need CRLF.  A source file with Unix endings makes ZMAC report
#     "INPUT LINE TOO LONG", because the whole file looks like one line.  The
#     vendored sources are CRLF; this checks rather than trusting it.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
work=${1:?usage: build-zsdos.sh <work-dir> <output.bin> <firmware.sym>}
out=${2:?usage: build-zsdos.sh <work-dir> <output.bin> <firmware.sym>}
sym=${3:?usage: build-zsdos.sh <work-dir> <output.bin> <firmware.sym>}
RUNCPM=${RUNCPM:-runcpm}
ORG=0xCC00
SIZE=0xE00

command -v "$RUNCPM" >/dev/null 2>&1 || {
    echo "build-zsdos: '$RUNCPM' not found." >&2
    echo "  ZSDOS is assembled by ZMAC under a CP/M emulator.  Set" >&2
    echo "  RUNCPM=/path/to/RunCPM (note: the executable is RunCPM/RunCPM)." >&2
    exit 1
}

for f in zsdos.z80 zsdos.lib; do
    python3 - "$here/src/$f" <<'PY' || exit 1
import sys
raw = open(sys.argv[1], 'rb').read()
# Only lines actually followed by a newline can be judged.  A CP/M text file
# ends with ^Z and no final newline, so the last element is not a short line.
lines = raw.split(b'\n')[:-1]
bad = [n for n, line in enumerate(lines, 1) if not line.endswith(b'\r')]
if bad:
    print(f"build-zsdos: {sys.argv[1]} has lines without CR at {bad[:5]}"
          " -- CP/M tools need CRLF, and ZMAC reports 'INPUT LINE TOO LONG'"
          " when the whole file looks like one line.", file=sys.stderr)
    sys.exit(1)
PY
done

rm -rf "$work"
mkdir -p "$work/A/0"
cp "$here/src/zsdos.z80" "$work/A/0/ZSDOS.Z80"
cp "$here/src/zsdos.lib" "$work/A/0/ZSDOS.LIB"
cp "$here/tools/ZMAC.COM" "$here/tools/L80.COM" "$work/A/0/"

# ZSDOS calls two BIOS helpers by absolute address.  Both move when the BIOS is
# rebuilt, so the addresses are generated from its symbol map rather than
# written down here.
python3 "$here/../tools/gen_zsdos_bios.py" --symbols "$sym" \
    --output "$work/A/0/ZSDOSBIO.LIB"
cp "$here/../zcpr2/tools/EXIT.COM" "$work/A/0/"

ccp=$(cd "$work" && printf 'EXIT\r\n' | timeout 30 "$RUNCPM" 2>&1 \
        | sed -n 's/^CCP \([^ ]*\) at .*/\1/p' | head -1)
[ -n "$ccp" ] || { echo "build-zsdos: could not read RunCPM's CCP name" >&2; exit 1; }
[ -f "$here/../zcpr2/tools/runcpm-ccp/$ccp" ] || {
    echo "build-zsdos: this RunCPM wants bootstrap CCP '$ccp', not vendored." >&2
    exit 1
}
cp "$here/../zcpr2/tools/runcpm-ccp/$ccp" "$work/$ccp"

# --- assemble; stop as soon as ZMAC reports it is done ---------------------
( cd "$work" && printf 'ZMAC ZSDOS.Z80\r\n' | "$RUNCPM" >asm.log 2>&1 ) &
runner=$!
i=0
while [ $i -lt 600 ]; do
    grep -q "assembled with" "$work/asm.log" 2>/dev/null && break
    kill -0 $runner 2>/dev/null || break
    i=$((i + 1))
    sleep 0.5
done
sleep 1
kill $runner 2>/dev/null || true
wait $runner 2>/dev/null || true

if ! grep -q "assembled with[[:space:]]*NO ERRORS" "$work/asm.log"; then
    echo "build-zsdos: ZMAC did not report a clean assembly:" >&2
    sed 's/\r//g' "$work/asm.log" | grep -iE "error|too long" | head >&2
    exit 1
fi
sed 's/\r//g' "$work/asm.log" | grep -E "Total Code Size" | head -1

# --- link at CC00h ---------------------------------------------------------
( cd "$work" && printf 'L80 /P:CC00,ZSDOS,ZSDOS.BIN/N/E\r\nEXIT\r\n' \
    | timeout 120 "$RUNCPM" >link.log 2>&1 ) || true

[ -f "$work/A/0/ZSDOS.BIN" ] || {
    echo "build-zsdos: L80 produced no ZSDOS.BIN; see $work/link.log" >&2
    exit 1
}
sed 's/\r//g' "$work/link.log" | grep -E "^Data" | head -1

python3 "$here/../tools/l80_slice.py" --image "$work/A/0/ZSDOS.BIN" \
    --origin "$ORG" --size "$SIZE" --output "$out"
