#!/bin/sh
# Assemble ZCPR2 for Zephyr-80 and emit a 2048-byte CCP image.
#
# ZCPR2.ASM is DRI MAC source: it uses MACLIB to pull in its configuration and
# defines the Z80 opcodes as 8080 macros.  Nothing in the host toolchain reads
# that dialect, so it is assembled the way it was meant to be -- by MAC.COM,
# under a CP/M emulator.  RunCPM is used as a toolchain here, exactly like
# sdasz80 or xc8-cc, and is not vendored.
#
# RunCPM quirks this works around, all found the hard way:
#   * it loads its own bootstrap CCP by bare filename relative to FILEBASE, so
#     that file must sit in the working directory -- not in CCP/ and not on the
#     emulated disk.  Which file it wants is compiled into the binary, so the
#     name is read back from its own banner rather than assumed.
#   * drives are ./A/0, ./B/0 ... directly under the working directory.  A
#     DISK/ prefix, which the RunCPM distribution uses, is not what the binary
#     looks for.
#   * it does not exit when stdin closes.  EXIT.COM terminates it, so both runs
#     end with one; the timeouts are only a backstop.  An earlier version of
#     this script relied on the timeout alone -- which meant the CCP-detection
#     run blocked forever, because that one had none.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
work=${1:?usage: build-zcpr2.sh <work-dir> <output.bin>}
out=${2:?usage: build-zcpr2.sh <work-dir> <output.bin>}
# The emulator is carried in this tree and built by the parent Makefile, which
# passes it in.  Falling back to the in-tree path keeps the script runnable on
# its own; falling back to PATH would silently pick up an unpatched RunCPM,
# whose internal CCP has no matching binary in tools/runcpm-ccp.
RUNCPM=${RUNCPM:-$here/../build/tools/RunCPM}

command -v "$RUNCPM" >/dev/null 2>&1 || {
    echo "build-zcpr2: '$RUNCPM' not found." >&2
    echo "  ZCPR2 is assembled by MAC.COM under a CP/M emulator; no host" >&2
    echo "  assembler reads its dialect.  The emulator is carried in this tree" >&2
    echo "  and built by the parent Makefile:" >&2
    echo "    make -C .. build/tools/RunCPM" >&2
    echo "  See ../tools/runcpm/README.md.  RUNCPM= overrides." >&2
    exit 1
}

rm -rf "$work"
mkdir -p "$work/A/0"
cp "$here/src/ZCPR2.ASM" "$here/src/Z2HDR.LIB" "$work/A/0/"
cp "$here/tools/MAC.COM" "$here/tools/MLOAD.COM" "$work/A/0/"

# Ask the binary which bootstrap CCP it wants, then supply it.
cp "$here/tools/EXIT.COM" "$work/A/0/"
ccp=$(cd "$work" && printf 'EXIT\r\n' | timeout 30 "$RUNCPM" 2>&1 \
        | sed -n 's/^CCP \([^ ]*\) at .*/\1/p' | head -1)
[ -n "$ccp" ] || { echo "build-zcpr2: could not read RunCPM's CCP name" >&2; exit 1; }
if [ ! -f "$here/tools/runcpm-ccp/$ccp" ]; then
    echo "build-zcpr2: this RunCPM wants bootstrap CCP '$ccp', which is not in" >&2
    echo "  $here/tools/runcpm-ccp/ -- copy it from your RunCPM's CCP/ directory." >&2
    exit 1
fi
cp "$here/tools/runcpm-ccp/$ccp" "$work/$ccp"

printf 'MAC ZCPR2\r\nEXIT\r\n' | (cd "$work" && timeout 600 "$RUNCPM" >build.log 2>&1 || true)

hex="$work/A/0/ZCPR2.HEX"
[ -f "$hex" ] || {
    echo "build-zcpr2: MAC produced no ZCPR2.HEX; see $work/build.log" >&2
    exit 1
}

# MAC flags errors with a letter in column 1 of the listing.
if sed 's/\r$//' "$work/A/0/ZCPR2.PRN" | grep -qE '^[A-Z] '; then
    echo "build-zcpr2: MAC reported assembly errors:" >&2
    sed 's/\r$//' "$work/A/0/ZCPR2.PRN" | grep -E '^[A-Z] ' | head >&2
    exit 1
fi

python3 "$here/../tools/hex_to_ccp.py" --hex "$hex" \
    --base 0xCC00 --size 0x800 --output "$out"
