# Source Boundary Review

## Purpose

This manual review document tracks source and dependency boundaries for the CPM2.2 Zephyr-80 build tooling. It is intentionally outside generated build outputs.

## Required Checks

| Boundary | Expected Result | Review Status |
|---|---|---|
| `cpm-2.2` | Read-only CP/M 2.2 source input. | Pending |
| `../CPM` | Context only; no direct build, include, link, or runtime dependency. | Pending |
| `tools/swapbits.py` | Project-local owned copy of the bit-swap behavior. | Pending |
| `../Monitor` | Approved external monitor payload producer. | Pending |
| `../bbcbasic-z80/BBCBASIC.COM` | Approved external BBC BASIC payload input. | Pending |

## Review Notes

- The root `Makefile` must invoke `tools/swapbits.py`, not `../CPM/tools/swapbits.py`.
- Any behavior copied or reimplemented from `../CPM` must be confirmed by an approved plan before adoption.
- Build output artifacts belong under `build/`.
- Application code belongs in the workspace root, never in `aidlc-docs/`.
