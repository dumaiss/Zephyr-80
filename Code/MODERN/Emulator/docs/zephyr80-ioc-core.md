# The IO controller's protocol core

`zephyr80_ioc_core` (`mame/src/mame/pbitz/zephyr80_ioc_core.*`) is the IO
controller's command and bulk protocol, independent of any transport: it takes
the request found in a command window and returns the reply, arms the bulk
transfer a reply announces (READY), checks and commits what the bulk lane
brings back, and answers the DONE query. It holds every protocol object; the
media behind it are a `zephyr80_ioc_storage` backend
(`zephyr80_ioc_storage.h`), the machine's [card socket](zephyr80-card.md). Its HID
module, `zephyr80_ioc_hid`, is the controller's keyboard input
([the USB keyboard](zephyr80-keyboard.md)). The transport that runs it over SIO1 is
`zephyr80_ioc` ([SIO1 and the IO controller](zephyr80-sio1-ioc.md)).

The specification is the controller firmware (`Code/MCU/IOController`) as
deployed: the normal profile with the filesystem commands and the bulk-lane
CRC bypass (`include/config.h`, `Makefile`). `include/ioc_frame.h` gives the
packet, classes, layouts and statuses; `src/dispatch.c` the class table;
`src/handlers.c`, `fs2.c`, `fs_share.c`, `volume.c` and `ioc_hid.c` the
replies and state; `src/bulk_channel.c` the bulk packet and its lifecycle;
`src/main.c` the service order. No firmware runs; the core is native code that
reproduces these replies, errors and state transitions.

## Frames

`A5 5A LEN_LO LEN_HI TYPE SEQ STATUS DATA… CRC_HI CRC_LO`; LEN counts TYPE,
SEQ, STATUS and DATA (3–29 on the command lane, 3 + 1…512 on the bulk lane);
CRC-16-CCITT (1021h, preset 0, MSB-first, no final XOR) over LEN_LO to the last
DATA byte. A request is the first position in the 36-byte window holding a
whole packet with an admitted class (`external_sync.c` `is_command_class`), a
zero STATUS and a valid CRC; a window of marking idle, a bad CRC or length, a
packet running past the window, an unadmitted class or a nonzero STATUS gets no
reply and counts as an abort. A broken frame does not hide a valid one after
it. The reply carries the request's SEQ and is rebuilt from a zeroed mailbox
every time, so no byte of an earlier reply survives into it.

## Command and status matrix

Statuses are `ioc_frame.h` values. "Empty socket" is what the machine answers
with no `-card` or `-carddir` media: the firmware with no card in the socket
(`sd_card_init` reports `SD_ERR_NO_CARD`).

| Class | Reply | Behaviour | Empty socket | Served from |
|---|---|---|---|---|
| 01h PING | 81h | echo of DATA 0–15, level 75, power byte (6Fh synced, 2Fh not), service and abort counters | 00h | core |
| 02h RESET | none | the machine resets 10 ms later (`handler_reset`); READY stays low | — | core |
| 03h SD_READ | 83h | first 16 bytes of card block 0; on failure 8 SD-trace bytes, which read zero (no SPI trace is modelled) | 15h | card media |
| 04h, 05h, 07h, 0Bh | FEh | BULK_TEST, SD_READ_BULK, SD_WRITE_BULK, PROFILE are diagnostic-profile classes: admitted, then unknown | 02h | core |
| 06h XFER_STATUS | 86h | DONE: last transfer id and its final status; the 18 diagnostic bytes read zero | 00h | core |
| 08h SD_READ_REC | 88h | READY, 128 bytes to the Z80, record echo; volume unit from DATA 4 when LEN ≥ 5 | 15h | card media |
| 09h SD_WRITE_REC | 89h | READY for 128 bytes from the Z80; the commit writes the record (DONE) | READY, DONE 15h | card media |
| 0Ah SD_FLUSH | 8Ah | the backend's flush | 00h | card media |
| 0Ch LINK_SYNC | 8Ch | both lanes drop their boundary before the reply | 00h | core |
| 0Dh HID_STATUS | 8Dh | page 0 (26 bytes), 6 (26) and 7 (21); other pages answer page 0. No USB host controller is modelled: bring-up NOT_STARTED, revision 0, `/USB_INT` idle; page 0's live fields are the keyboard's (one device, address 1, reports, last report, full speed); gamepad sentinels FFh, latches 7Fh | 00h | HID module (keyboard); mouse and controller devices |
| 0Eh HID_INPUT | 8Eh | up to min(DATA 0, 24) queued bytes, then queued and dropped counts | 00h | HID module |
| 0Fh SD_READ_BLOCK | 8Fh | READY, 512 bytes, block echo | 15h | card media |
| 10h VOL_MOUNT | 90h | the unit dropped, then `/CPM/<name>` of exactly 8 MiB mounted; unit ≥ 2 30h, missing 10h, wrong size 32h | 15h | card media |
| 11h VOL_INFO | 91h | unit, mode, extents, base block, records, name, boot guard (clear) | 00h, unmounted | card media |
| 12h HID_MOUSE | 92h | flags, buttons, presses, dx/dy/wheel since the last read, then cleared | 00h, zero | mouse device |
| 20h–28h FS_* | A0h–A8h | the `/SHARED` folder: one directory session, one file handle, explicit offsets, ≤ 512-byte chunks, close truncates to the exact size, self-test sum | 13h (READDIR, READ, WRITE, CLOSE without a handle: 36h) | card media |
| 30h FS2_CAPS | B0h | version 1, flags 1FFEh, generation, chunk 512, 2 files, 1 directory, 16 components, 2-byte tokens | 00h | core |
| 31h FS2_GENERATION | B1h | the generation | 00h | core |
| 32h FS2_RESET | B2h | every context closed, generation + 1, resolver at the root | 00h | core |
| 33h FS2_ROOT | B3h | resolver at the root | 00h | core |
| 34h PUSH, 35h OPEN_RO, 38h OPENDIR, 3Bh STAT, 3Ch SPACE, 3Dh OPEN_RW, 41h–44h | B4h… | resolver path + 8.3 name; FatFs results mapped by `map_result` | 4Bh | card media |
| 36h READ, 37h CLOSE, 39h READDIR, 3Ah CLOSEDIR, 3Eh WRITE, 3Fh SYNC, 40h TRUNCATE, 45h READ_RUN | B6h… | token: slot + cookie, checked against the generation | 48h | card media |

The FS2 commands' statuses: 40h not found, 41h end of listing, 42h exists,
43h bad name, 44h read-only or denied, 45h no space, 46h not a directory,
47h is a directory, 48h no handle, 49h stale (an old generation), 4Ah range
(length 0 or above 512, a run unaligned or above 2048, mode above 2, a 17th
resolver component), 4Bh no media, 4Eh I/O. A media-level FatFs failure (disk
error, not ready, no filesystem) drops every FS2 context and advances the
generation. That is the only way a media change is noticed: the backend never
announces one, and its session (`card_ready`) ends only when an access fails;
record and block access re-initialise the card and drop the units when they
find the session ended (`vol_ensure_mounted`).

Volumes (`volume.c`): the first record or block access brings the card up and
mounts unit 0 raw (the card itself, 65536 records) when nothing is mounted and
the media have card blocks. After every service the idle pass runs the one
auto-mount once the card is up: `CPM_1.DRV` on unit 0, `CPM_2.DRV` on unit 1,
stopping at the first failure. Mounting drops the unit first, so a failed
auto-mount leaves unit 0 unmounted. A record past the end is 31h, an unmounted
unit 30h.

## Storage interface

The backend contract is `zephyr80_ioc_storage`, shaped like the firmware's own
layers; results are the firmware's codes and the core converts them.

| Group | Operations | Firmware |
|---|---|---|
| Card session | `card_init`, `card_ready`, `controller_reset` | `sd_card_init`, `sd_card_is_initialized` (false only after a failed access) |
| Raw blocks | `raw_blocks`, `block_read`, `block_write`, `flush` | `sd_card`, `sd_cache` |
| FAT volume | `fs_mount`, `fs_unmount`, `fs_geometry`, `stat`, `open`, `close`, `size`, `seek`, `read`, `write`, `truncate`, `sync`, `opendir`, `readdir`, `closedir`, `unlink`, `mkdir`, `rename` | `sdfs`, FatFs (`FRESULT` numbering; `seek` clips a read-only file and grows a writable one) |
| Volume images | `image_open`, `image_close`, `image_read`, `image_write` | `fatmap_resolve` (`FatMapStatus`) and the volume's blocks |

| State | Owner |
|---|---|
| FS2 slots, cookies, tokens, cached positions, writable flags, generation, resolver path (cwd, ≤ 239 characters, 16 components) | core |
| `/SHARED` handle number, directory session, cached position | core |
| Volume unit table (mode, name, records, reported extents and base), mount and auto-mount flags | core |
| Transfer ids, the armed transfer, the DONE record, staged write parameters, bulk buffers | core |
| HID module (keyboard reports, translation, repeat, input queue and doorbell), mouse read state | core |
| Media contents, the FAT mount, open file/directory/image objects, caching and write-back | backend |

Paths are the firmware's FatFs paths, built by the core (`/SHARED/NAME.EXT`,
the resolver plus one component); the backend resolves them on its media. An
unmount leaves the backend's objects allocated but answering INVALID_OBJECT
until the core closes them; `controller_reset` drops them all (controller RAM
is lost; the media keep their contents). The core keeps at most eight objects
open. Media without card blocks (a host folder) answer `raw_blocks` false and
get no raw unit. The core needs a backend before it starts; the machine's is
`zephyr80_card_socket`, and the host test's in-memory card is
`tests/ioc_core/memory_storage.h`.

## Bulk

A READY reply carries the transfer id (never 0, wrapping), the direction
(00h to the Z80, 01h from it), the DATA length and the offset or record echo;
the transfer is armed with the reply's TYPE and SEQ. A read reads the media
before READY; a read of nothing (end of file) answers a zero READY and arms
nothing. After the reply the transport runs the transfer:

- To the Z80 (`bulk_packet`, `bulk_sent`): A5 5A, LEN, TYPE, SEQ, STATUS 00h,
  DATA, and the trailer as two zero bytes (the deployed CRC bypass). DONE is
  OK once the bytes are out. FS2_READ_RUN reads up to 2048 bytes before READY
  and sends 512-byte packets (`run_more`, `run_next`), each with the run's id,
  TYPE and SEQ.
- From the Z80 (`bulk_window`, `bulk_received`): a window of the packet plus
  16 bytes of late-start slack and 2 more is captured; the marker is searched
  in its first 16 positions; LEN, TYPE, SEQ and a zero STATUS must match what
  READY armed, otherwise DONE is 22h (BULK_NO_SYNC) and nothing is written.
  The trailer is not checked (bypass), so fill bytes from a host that
  underruns inside DATA are committed, as on the board. Then the commit runs
  (record write, `/SHARED` write, FS2 write) and its status is DONE's.
- No host (`bulk_no_host`): DONE 21h (BULK_NO_HOST), nothing written.
- A controller reset drops the armed transfer and the DONE record (id 0).

Transfers move on the bulk lane only and are built from the bulk buffers; no
command byte reaches them.

## Bounds and memory

| Item | Bound |
|---|---|
| Command window, request, reply | 36, 35, 35 bytes |
| Mailbox | 32 bytes, DATA ≤ 26 |
| Bulk packet, capture window | 521 bytes (512 DATA), 539 bytes |
| Run | 2048 bytes (`IOC_FS2_RUN_MAX`) |
| Buffers | chunk 2048, block 512, record 128 bytes |
| FS2 | 2 files, 1 directory, path 239 characters, 16 components |
| HID input queue | 128 bytes, a key's bytes whole or dropped, drop count saturating at FFh; a repeat only below 64 |
| Volume units | 2 |

The core object is 3272 bytes on x86-64 (buffers 2688, resolver 240, the HID
module 168 of which 128 are its queue, the rest counters, tables and two
pointers); the transport adds 36 + 35 + 539 bytes of lane buffers.
Every member of both is save-registered.

## Not modelled

The PIC, the MAX3421E and USB, the SD card and its SPI trace, the SD block
cache's timing and write-back (the backend decides when writes reach the media;
a record write is a read-modify-write of its block), bulk CRC (the deployed
bypass), the diagnostic profile, the PROFILE timers, the boot guard (never
degraded, no resets counted), the power handshake beyond PING's idle byte, USB
below the HID usages ([the USB keyboard](zephyr80-keyboard.md#not-modelled)),
and the mouse and controller devices.
