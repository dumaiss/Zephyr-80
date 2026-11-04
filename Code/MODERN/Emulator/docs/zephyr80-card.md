# The IO controller's card socket

`zephyr80_card_socket` (`mame/src/mame/pbitz/zephyr80_card.*`) is the
`zephyr80_ioc_storage` backend of the [protocol core](zephyr80-ioc-core.md):
the SD socket and whatever card is in it. Two image devices
(`zephyr80_card_slot.*`) put media in it:

```sh
./mamepbitzd zephyr80 -flash konaos.bin -card sd.img      # a card image
./mamepbitzd zephyr80 -flash konaos.bin -carddir card/    # a host folder
```

They are exclusive: loading one while the socket holds the other's media
fails (`-card and -carddir are exclusive`). A missing path, a folder given to
`-card` or a file given to `-carddir` fails the load with its reason; MAME
then stops, as for any command-line image. Without either option the socket
is empty and the controller answers as the firmware does with no card
(`SD_ERR_NO_CARD`). The socket opens the path itself; neither device creates
media. Unloading ejects the card (see media changes below). A file or folder
the process cannot write is a write-protected card.

The specification is the firmware (`Code/MCU/IOController`): `src/sd_card.c`
(the session), `src/sdfs.c` and `src/diskio.c` (the FAT volume),
`src/fatmap.c` (volume images), `src/volume.c` (units), `src/fs2.c` and
`src/fs_share.c` (through the core). Nothing below the socket is modelled: no
SPI, no card commands, no card controller.

## Card images

A card image is a file of 512-byte blocks: a raw card, a FAT16 or FAT32
volume at block 0, or one in the first MBR partition that holds one.

- **The FAT volume** is FatFs R0.15, the firmware's own copy with its own
  `ffconf.h` (`mame/3rdparty/fatfs`, unmodified; 1-clause BSD-style license
  in `LICENSE.txt`). `zephyr80_fatfs.c` builds it with the socket's media
  layer. The configuration is the firmware's: no LFN, code page 437, one
  volume, FF_FS_TINY (one 512-byte window), no file locking, no RTC (dates
  2022-01-01). Mounting follows `sdfs_mount`: the card up, the 55AAh
  signature at block 0 checked before FatFs sees the card, then `f_mount`; a
  card without the signature or a filesystem is a card without a filesystem,
  not a failure.
- **Volume images** are resolved as `fatmap_resolve` does, over the card's
  blocks: `/CPM/<name>` by its packed short name, exactly 8 MiB, its chain
  coalesced into at most 16 extents (more is FATMAP_FRAGMENTED, VOL_MOUNT
  32h), the extents covering the file. VOL_INFO reports the extent count and
  the first extent's block. Records map through the extents (`vol_map`).
- **Raw blocks** are the image's blocks; the raw unit is the firmware's
  (unit 0, 65536 records from block 0).

FatFs, the volume images and the raw unit share the one file of blocks.
Raw and volume access stay coherent with the FatFs window: a raw read of the
block FatFs holds dirty sees its pending bytes (the window is written back
first), and a raw write to it is never overwritten later (written back first,
then reloaded). The resolver also writes the window back before it reads.

### Why FatFs

MAME's `fs::PC_FAT` (`src/lib/formats/fs_fat.cpp`) does not cover what the
firmware's filesystem contract needs:

| Need | `fs::PC_FAT` | FatFs (firmware copy) |
|---|---|---|
| FAT16 | formats/mounts as FAT12 floppies only (`pc_fat_image::mount` passes 12-bit entries, sector 0) | yes |
| FAT32 | no ("No FAT32 support") | yes |
| MBR partition | no (mounts at sector 0) | yes (`FF_MULTI_PARTITION` 0: the first FAT partition) |
| read by offset | no: `file_read` returns the whole file | `f_read` at `f_lseek` |
| write at an offset, extend | no: `file_write` replaces the whole file | `f_write`, `f_lseek` growth |
| truncate | no | `f_truncate` |
| rename | no | `f_rename` |
| remove a file | `remove()` returns unsupported for any path below the root | `f_unlink` |
| directories | create yes; remove no | `f_mkdir`, `f_unlink` |
| free space | no | `f_getfree` |
| the firmware's results | none (error_condition) | FRESULT, as the firmware maps them |

The image backend therefore uses FatFs only; there is no second
implementation to fall back to.

## Host folders

A folder is served as a FAT volume with no card blocks.

- **Names.** A host entry is on the card only when its name is an 8.3 short
  name: 1–8 characters, optionally a dot and 1–3 more, printable ASCII
  without spaces or `"*+,./:;<=>?[\]|`, and exactly the name the card would
  show once upper-cased (`readme.txt` is `README.TXT`; `a.`, `.hidden`,
  `long name.txt`, `toolongname.txt`, `a.b.c` and non-ASCII names are not on
  the card). Lookup is case-insensitive. A new file or directory takes its
  upper-case name; a rename gives the host entry the new name.
- **Collisions.** Two host entries whose names fold to one 8.3 name
  (`dup.txt` and `DUP.TXT`) are both left out of listings, and any operation
  on that name is refused (`FR_DENIED`, FS2 44h): neither is chosen.
- **Traversal.** Paths resolve segment by segment from the folder's root,
  matching only the names the folder presents; `.` and `..` are not names
  (`FR_INVALID_NAME`), so nothing outside the root is reached. Symbolic links
  and anything neither a regular file nor a directory are not on the card.
  The root itself is resolved once, when the folder is inserted.
- **Order.** Listings are in 8.3 name order, fixed when the directory is
  opened; an entry removed since is skipped and sizes are read as each entry
  is returned.
- **Results** follow FatFs: a missing last segment is NO_FILE, a missing or
  non-directory intermediate one NO_PATH, the root as a file INVALID_NAME,
  a directory opened as a file NO_FILE (or DENIED to create it), an existing
  name for MKDIR or RENAME EXIST, a non-empty directory or a file without
  write permission DENIED (a directory holding only names the card does not
  show is not empty), a read-only folder WRITE_PROTECTED. Reading clips at
  the end; a writer's seek past the end grows the file with zeros (FatFs
  leaves the new clusters' contents undefined). A host that refuses bytes
  (ENOSPC, EFBIG, EDQUOT) is a full volume: a short write, FS2 NO_SPACE.
- **Space** is the host filesystem's, in 4 KiB clusters, reported as FAT32.
- **Raw access.** A folder has no card blocks: `SD_READ` answers with block
  0 blank (the card is up; the ZSDOS drive probe needs that), every other raw
  access fails, and there is no raw unit (record and block access on unit 0
  answer VOL_UNMOUNTED unless `/CPM/CPM_1.DRV` is mounted there).
- **Volume images** are host files `/CPM/<name>` under the same name rules,
  exactly 8 MiB; VOL_INFO reports one extent at block 0. A volume file
  without write permission refuses writes (SD_WRITE_REJ, 19h).

## Units and auto-mount

The core owns the unit table (`volume.c`). The first record or block access
brings the card up and, on a card image, mounts unit 0 raw if nothing is
mounted. After every service, once the card is up, the idle pass mounts
`CPM_1.DRV` on unit 0 and `CPM_2.DRV` on unit 1, stopping at the first
failure; mounting drops the unit first, so on a card without `CPM_1.DRV`
unit 0 ends unmounted (as on the board). ZSDOS's C: and D: are units 0 and
1 (`sd.asm`); its B: is the FAT volume's `/CPM/B` through FS2.

## Persistence

Every write the socket accepts goes straight to the host file (unbuffered);
nothing is cached below FatFs. What FatFs holds in its window (an open
file's last partial block, its directory entry, a FAT block) reaches the
card at SYNC, CLOSE, the next window move or a raw access to that block, as
on the board; an open file not closed before MAME exits keeps what was
written back. SD_FLUSH, FS_CLOSE and FS_DELETE flush the host file.

## Sessions, media changes and invalidation

What survives a media change is the controller's RAM: the session
(`card_ready`), the FatFs mount and every open object. The controller never
notices a change by itself (`sd_card.c`):

| Event | Socket | What the guest sees |
|---|---|---|
| card removed (unload) | accesses answer NO_CARD and end the session | the first FS2 access that reaches the card fails (FR_DISK_ERR or NOT_READY, FS2 4Eh/4Bh): the mount is dropped, the generation advances, older tokens are STALE; record access answers 15h |
| card inserted with no session | the next access brings it up | the next FS2 access mounts it fresh |
| card swapped between commands (the session survives) | the first read re-initialises it and succeeds (`sd_card_read_block`'s retry); the first write fails (no retry) and ends the session | FatFs keeps its mount: reads use the old geometry on the new card until a failure; a write-back fails (FS2 4Eh), then as above; a volume keeps its extents |
| any failed card access (past the end, a host I/O error) | the session ends | as above; record access re-initialises and drops the units on its next request |
| read-only medium refusing a write | the session stays | FR_WRITE_PROTECTED (FS2 44h), or SD_WRITE_REJ for blocks |
| controller reset (CMD_RESET, machine reset) | every object, the mount and the session are dropped; media stay | tokens are unknown (NO_HANDLE), units unmounted |
| FS2_RESET, UNLINK, RENAME, RMDIR | (core) | FS2 contexts close as `fs2.c` closes them |

A record write is a read-modify-write of its block, so its read
re-initialises a swapped card and the write then succeeds; only a write with
no read before it (a FatFs window write-back) meets the failing first write.
A host folder has no geometry to go stale: an object opened on a replaced
folder fails its next use with FR_DISK_ERR (and ends the session), while
paths resolve on the folder now in the socket.

## Bounds and memory

| Item | Bound |
|---|---|
| Open objects (files, directories, volume images) | 16 |
| FatFs | one FATFS with its 512-byte window, 16 FIL and DIR objects |
| Transfers | the bytes asked for: no file is read whole to serve a chunk |
| Volume image extents | 16 (`VOL_MAX_EXTENTS`) |
| Folder listing | the names of one directory, while it is open |

The socket object is 4000 bytes on x86-64 (16 object slots) plus 2608 bytes
of FatFs state (the FATFS with its window, 16 FIL and 16 DIR), allocated
once; an open host file adds its stdio stream and a listing its names.

## Save states

The socket's state is saved with the machine's, with no host pointer or file
in it:

| State | Saved as |
|---|---|
| session, replaced flag, FAT and folder mounts, insertion serial | the values |
| each of the 16 objects | its type, validity, media serial, write mode, position, length, extents; a folder object's file as its path below the folder's root; a folder directory's names still to be read |
| FatFs | the FATFS fields and its 512-byte window (dirty or not), every FIL and DIR with its volume and window pointers as presence and window offsets, and FatFs's mount counter |
| the media | their identity: kind (none, image, folder), write protection, an image's size, and a SHA-1 of what the card presents: an image's bytes, or a folder's 8.3 tree depth first in 8.3 order, each name with its kind, ambiguity and write permission, then a file's size and bytes |

The media themselves are never copied into the state. On load the socket
identifies the inserted media the same way and compares: a difference in kind,
write protection, size or content ends MAME with a fatal error naming both
identities, so no saved FatFs window, position or pending write is ever
applied to other media. The media's path does not matter: a copy of the card
as it was at the save restores. With matching media the socket reopens each
folder object's file at its path and mode, rebuilds the folder listings from
the saved names, registers the FatFs volume again and restores its objects'
pointers. A file the restore cannot reopen is a fatal error too. Objects left
from media that were ejected keep their serial and fail their next access, as
before the save.

Identifying the media reads them whole on every save and load (a 16 MiB
image in tens of milliseconds); MAME's rewind feature, which saves every frame,
is not suited to a card in the socket.

## Not modelled

The SD card and its SPI session (initialisation, CMD17/CMD24, CRC, timing),
the controller's 8-block write-back cache and its idle flush (writes reach
the file at once, so a deferred write never fails later), the card-detect
switch's timing, write protection on a real card (a read-only host file is
the only write-protected card), and card latency.
