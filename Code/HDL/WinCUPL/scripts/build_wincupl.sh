#!/usr/bin/env sh
# Compile one WinCUPL source and copy its outputs (JED, doc, abs, sim) to an
# output directory.
#
# CUPL may be a native `cupl` on PATH or the Windows CUPL.EXE.  A .exe always
# runs under Wine: it carries the executable bit, so testing it with
# `command -v` and running it directly fails with "Exec format error".
set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <source.pld> <output-dir>" >&2
    exit 2
fi

SOURCE=$1
OUT_DIR=$2

if [ ! -f "$SOURCE" ]; then
    echo "WinCUPL source not found: $SOURCE" >&2
    exit 1
fi

CUPL_BIN=${CUPL:-cupl}
CUPL_FLAGS=${CUPLFLAGS:-}
SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$SOURCE")" && pwd)
SOURCE_BASE=$(basename -- "$SOURCE")
DESIGN=${SOURCE_BASE%.pld}
WORK_DIR="$SOURCE_DIR/.wincupl-$DESIGN"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$OUT_DIR"
cp "$SOURCE" "$WORK_DIR/$SOURCE_BASE"

run_cupl() {
    case "$CUPL_BIN" in
        *.exe|*.EXE)
            if [ ! -f "$CUPL_BIN" ]; then
                echo "WinCUPL compiler not found: $CUPL_BIN" >&2
                exit 127
            fi
            if ! command -v wine >/dev/null 2>&1; then
                echo "$CUPL_BIN is a Windows program and wine is not installed." >&2
                exit 127
            fi
            # CUPLFLAGS is intentionally word-split so callers can pass WinCUPL
            # compiler switches as they would on the command line.
            # shellcheck disable=SC2086
            WINEDEBUG=${WINEDEBUG:--all} wine "$CUPL_BIN" $CUPL_FLAGS "$SOURCE_BASE"
            ;;
        *)
            if ! command -v "$CUPL_BIN" >/dev/null 2>&1; then
                echo "WinCUPL compiler not found." >&2
                echo "Set CUPL=/path/to/CUPL.EXE or put cupl on PATH." >&2
                exit 127
            fi
            # shellcheck disable=SC2086
            "$CUPL_BIN" $CUPL_FLAGS "$SOURCE_BASE"
            ;;
    esac
}

(
    cd "$WORK_DIR"
    run_cupl
)

# CUPL reports errors in its listing and can still exit 0, so a missing JED is
# the failure signal.  The JED is named after the source's Name field, not the
# file name.
if ! find "$WORK_DIR" -maxdepth 1 -type f -iname '*.jed' | grep -q .; then
    echo "WinCUPL produced no JED for $SOURCE" >&2
    for lst in "$WORK_DIR"/*.lst "$WORK_DIR"/*.LST; do
        [ -f "$lst" ] && cat "$lst" >&2
    done
    exit 1
fi

# Replace, not merge: a stale JED left beside a new one is how the wrong fuse
# map gets programmed.
find "$OUT_DIR" -maxdepth 1 -type f -exec rm -f {} \;
find "$WORK_DIR" -maxdepth 1 -type f ! -name "$SOURCE_BASE" -exec cp {} "$OUT_DIR"/ \;
rm -rf "$WORK_DIR"
echo "Generated WinCUPL output in $OUT_DIR:"
ls "$OUT_DIR"
