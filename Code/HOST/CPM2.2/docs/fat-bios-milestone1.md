# FAT-backed drive Milestone 1: synthetic BIOS personality

Milestones 2–4 now supersede the exposure restrictions in this historical
milestone note. See `fat-read-only-milestones2-4.md` for the active read-only
implementation and hardware acceptance procedure.

Milestone 1 gives ZSDOS a safe BIOS-level representation of the future
FAT-backed D: drive. It does not expose FAT files and does not intercept BDOS
file operations.

The implementation is entirely in bank 7:

| Object | Classification | Location |
|---|---|---|
| Synthetic BIOS routines, DPH and DPB | BANK 7 fixed code | `9000h-9FFFh` FAT code region |
| Track, sector and 256-byte synthetic ALV | BANK 7 persistent state | `CE10h-D60Fh` FAT state region |
| Shared directory buffer | Existing bank-7 BIOS object | `CBIOS_STORAGE_DIRBUF` |
| New common-memory objects | None | — |
| Reclaimable cache allocation | None | `6600h-7FFFh` remains untouched |

The synthetic geometry is the existing 8 MiB compatibility geometry:

```text
SPT=4, BSH=5, BLM=31, EXM=1, DSM=2047, DRM=511,
AL0=F0h, AL1=00h, CKS=0, OFF=0
```

For D:, `SELDSK` returns the synthetic DPH, READ fills a valid 128-byte record
with `E5h`, and WRITE returns `BIOS_ERR`. HOME, SETTRK, SETSEC and SECTRAN keep
normal BIOS sequencing state. ZSDOS can therefore select and log D: while an
unintercepted filesystem operation sees an empty disk rather than a previously
selected conventional drive.

## Exposure gate

The normal image keeps D: unavailable. Build an explicit Milestone-1 hardware
image with:

```text
make FAT_BIOS_M1=1
```

The stamped artifact is:

```text
build/zephyr80-zcpr2-zsdos-fatbios-m1.bin
```

The synthetic code and data are linked in both configurations, so the gate
changes behavior without changing their addresses or memory cost.

The implementation brief asks SELDSK eventually to verify that the configured
FAT root is available. Milestone 1 has no IOC FS2 resolver yet, so it cannot
perform that check without introducing Milestone-2 protocol work early. The
opt-in build gate is the temporary availability decision. Root verification is
added when the read-only FS2 service exists.

## Verification

`tools/test_fat_bios_m1.py` executes the assembled routines in libqkz80 and
checks:

- DPH pointers and every synthetic DPB geometry field;
- complete `E5h` READ data;
- invalid track and sector rejection;
- unconditional WRITE failure;
- enabled D: selection and disabled-build rejection;
- READ and WRITE routing through the normal storage dispatcher.

The generated memory documentation also verifies the DPH pointers, exact DPB
bytes, fixed-region ceilings and contiguous track/sector/ALV state.

Hardware acceptance for the opt-in image is:

```text
A>D:
D>DIR
```

D: must select normally and report an empty directory. A:, B: and C: must retain
their existing contents and behavior. A write attempted against D: must fail.

Future USER-area support is limited to USER 0 through 15. The characterized
synthetic SEARCH contract is recorded in `fat-bdos-characterization.md`; it is
not part of this BIOS-only milestone.
