#!/usr/bin/env sh
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
    if command -v "$CUPL_BIN" >/dev/null 2>&1; then
        # CUPLFLAGS is intentionally word-split so callers can pass WinCUPL
        # compiler switches as they would on the command line.
        # shellcheck disable=SC2086
        "$CUPL_BIN" $CUPL_FLAGS "$SOURCE_BASE"
    elif command -v wine >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        wine "$CUPL_BIN" $CUPL_FLAGS "$SOURCE_BASE"
    else
        echo "WinCUPL compiler not found." >&2
        echo "Set CUPL=/path/to/CUPL.EXE or put cupl on PATH." >&2
        exit 127
    fi
}

(
    cd "$WORK_DIR"
    run_cupl
)

find "$WORK_DIR" -maxdepth 1 -type f ! -name "$SOURCE_BASE" -exec cp {} "$OUT_DIR"/ \;

if find "$OUT_DIR" -maxdepth 1 -type f | grep -q .; then
    echo "Generated WinCUPL output in $OUT_DIR"
else
    echo "WinCUPL completed, but no output files were found in $WORK_DIR" >&2
    exit 1
fi
