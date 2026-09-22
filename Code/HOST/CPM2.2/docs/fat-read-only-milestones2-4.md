# FAT read-only filesystem: Milestones 2–4

The normal image exposes drive D: as a read-only CP/M compatibility view of
the FAT directory `/CPM/D`. USER 0 maps directly to that directory; USER 1
through 15 map to `@1` through `@15`. A missing USER directory is empty.

## Milestone 2: IOC FS2

FS2 version 1 occupies the additive command range `30h–3Ch`. The existing
`20h–28h` `/SHARED` service is unchanged. The service provides capabilities,
generation, context reset, a component resolver, two read-only file slots, one
directory slot, explicit-offset reads, stat and free-space queries.

Names and path components use packed, space-padded 8.3 form. The resolver is
bounded to 16 components and 239 characters. Directory enumeration omits names
that cannot be represented without ambiguity as strict 8.3, including `~`
aliases. File and directory tokens combine a slot number and reuse cookie;
media invalidation makes a still-recognizable old token return `STALE`.

FS2 shares the existing filesystem 512-byte bulk staging buffer. The normal
linker result uses 9,852 of 12,800 PIC data bytes (77.0%), compared with 9,229
bytes before FS2. The measured increment is 623 bytes, including two `FIL`
objects, one `DIR`, tokens and the resolver.

## Milestone 3: native API

BDOS function 218 accepts a 32-byte version-1 descriptor. It implements:

```text
ZOPEN ZCLOSE ZREAD ZSEEK ZTELL ZSTAT ZOPENDIR ZREADDIR ZCHDIR
```

The descriptor uses packed 8.3 components. Repeated `ZCHDIR` operations walk a
hierarchy beneath the current USER namespace: `/CPM/D` for USER 0 and
`/CPM/D/@1` through `/CPM/D/@15` for higher USERs. The relative current
directory follows the USER component, so a directory visible at `D8:` is also
selectable by `ZCD` from `D8:`.
Synthetic `SELDSK` validates `/CPM/D` itself; it does not replay the native
USER-relative current directory while deciding whether drive D: exists.
The saved relative directory is owned by the USER that selected it; other USER
namespaces remain at their roots. `ZCD` with no argument clears the current
USER's relative directory. An explicit target such as `B0:ZCD D8:TESTDIR`
temporarily selects USER 8 for the native operation, restores the caller's USER,
and returns directly to ZCPR without a warm boot. `B0:ZCD D8:` selects the
USER-8 root.
`ZREAD` stages up to 512 bytes per descriptor call through the existing common
bulk buffer. Library callers loop for longer reads. Zephyr handles retain the
IOC token and independent 32-bit position; IOC tokens are never returned to an
application. `Utilities/src/zbdos.inc` contains the descriptor constants and
`zb_native` wrapper. `ZCD.COM` is the minimal hierarchy utility.

The descriptor fields are:

| Offset | Size | Meaning |
|---:|---:|---|
| 0 | 1 | version, currently 1 |
| 1 | 1 | operation |
| 2 | 1 | returned status |
| 3 | 1 | structural directory bit only; zero for files |
| 4 | 1 | Zephyr handle |
| 6 | 4 | position, size, or seek target |
| 10 | 2 | requested read length |
| 12 | 2 | application read buffer |
| 16 | 2 | returned read length |
| 18 | 11 | packed 8.3 component |

## Milestone 4: read-only BDOS personality

The facade stages FCB and DMA arguments as before. Once it enters bank 7, a
small dispatcher handles FAT calls or passes the call to unmodified ZSDOS.
ZSDOS therefore remains authoritative for current drive, USER and the
synthetic DPH. The bank-7 mirrors are updated only after the corresponding
ZSDOS calls.

Implemented calls are OPEN, CLOSE, SEARCH FIRST/NEXT, sequential read, random
read and COMPUTE FILE SIZE. MAKE, write, delete, rename, attribute mutation and
timestamp mutation fail read-only. FCBs remain authoritative: each record
operation can reopen the file and derive the explicit byte offset from the FCB,
so copied FCBs work without hidden tokens.

SEARCH emits the characterized contract: DMA is filled with `E5h`, entry zero
contains USER, a seven-bit-clean 8.3 name, EX/S1/S2/RC, allocation bytes are
zero, and A is zero. FAT file attributes are deliberately discarded; this
read-only personality does not expose R/O, hidden, system or archive bits.
The FS2 directory marker remains internal so SEARCH can exclude directories.
Exhaustion returns `FFh`. SEARCH emits one synthetic entry per FAT file. Its
`EX`, `S2`, and `RC` fields describe the terminal logical extent so catalogue
tools can recover the record count. FAT has no physical CP/M extents or
allocation blocks, and inventing multiple continuation entries caused ordinary
directory tools to print large files repeatedly. COMPUTE FILE SIZE remains
authoritative for the complete record count. The special SEARCH FIRST FCB drive
byte `3Fh` enumerates USER 0 through 15 as one continuation, preserving each
entry's USER byte; CRC 2.0 relies on this raw-directory convention.

Sequential and random reads return 128-byte records. A partial final record is
padded with `1Ah`; a request beginning at EOF returns the CP/M EOF result.
Function 35 writes the rounded-up 24-bit record count to the caller FCB.
Function 27 refreshes the synthetic ALV from FAT free space, capped by the
virtual 8 MiB geometry.

Cold boot, warm boot, disk reset, drive change and USER change invalidate
transient search/file contexts as appropriate. Warm boot preserves the native
current directory. The fixed implementation occupies the declared
`9000h–9FFFh` bank-7 code region and `CE10h–D60Fh` state region. The
`6600h–7FFFh` reclaimable cache pool remains unowned; record reads use the
required fallback path when no cache lease exists.

## Hardware acceptance

Milestones 2–4 passed hardware acceptance on 2026-09-22. The following suite
was run against the FAT-backed D: personality and the conventional B: volume.

### Basic search and small sequential read

```text
D:
DIR
TYPE LESSON.MD
CRC LESSON.MD
```

`DIR` produced sane names without FAT attribute corruption or duplicate
entries. `TYPE` printed the complete file, and CRC found `LESSON.MD` and
reported its CRC.

### Large-file extent and sequential-read handling

```text
CRC SONG.ZVG
VGMPLAY SONG.ZVG
```

CRC processed the complete large file. VGMPlayer played it normally without a
premature EOF, pause, read failure, or drive error.

### Explicit FAT FCB while another drive is current

```text
B:
VGMPLAY D8:SONG.ZVG
```

Playback completed normally. This verifies explicit FAT FCB drive semantics
without permanently selecting D:.

### Explicit conventional-drive FCB while FAT is current

```text
D:
VGMPLAY B8:SONG.ZVG
```

Playback completed normally without a ZSDOS `No Drive` error. This exercises a
temporary B: operation, restoration of D:, and subsequent B: access.

### Hierarchical FAT current directory

```text
D:
ZCD GAMES
DIR
CRC <small-file-in-GAMES>
ZCD ..
```

The current directory changed, `DIR` and CRC operated inside it, and returning
to the parent restored the expected view.

### USER mapping

```text
USER 1
DIR
CRC <fixture-in-@1>
USER 0
DIR
```

USER 1 exposed `/CPM/D/@1`, USER 0 exposed `/CPM/D`, and searches did not leak
files between USER namespaces.

### Conventional CP/M volume regression

```text
B:
DIR
TYPE BDOSCHAR.SUB
CRC BDOSCHAR.SUB
```

All three operations passed on the conventional CP/M volume. Together with the
cross-drive VGMPlayer cases, this confirms that the read-only FAT personality
did not regress ordinary B: directory, read, search, or drive-selection
behavior.
