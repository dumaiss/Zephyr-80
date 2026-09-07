# IO Controller: drive images as FAT32 files, and a shared folder for user space

> ## SHIPPED. BOTH PARTS BUILD; PART 1 CONFIRMED ON HARDWARE.
>
> Part 1 runs on hardware: the controller resolves `/CPM/CPM_1.DRV` on a FAT
> card into an extent table, and CP/M reads the volume out of it. Part 2 is
> built and on A:, not yet exercised.
>
> **The split that shipped is not the one this document proposed.** FatFs serves
> `/SHARED/` only; image resolution runs on `src/fatmap.c`. That is deliberate
> rather than historical: mounting a CP/M volume is boot-critical, and keeping
> it on 500 analysable lines means a fault in the 7,000-line library costs a
> user-space tool instead of the machine's ability to boot.
>
> Getting there took eleven firmware builds, because **every failure was caused
> by code that never executed.** Recorded here because none of it is guessable
> from the source.
>
> ### 1. FatFs was blamed for eleven builds, wrongly
>
> **This section originally concluded "FatFs cannot be linked into this
> firmware". That was wrong, and the retest has since proved it wrong: FatFs
> links and runs.**
>
> The bisect flag `IOC_FS_COMMANDS` gated the volume handlers and the filesystem
> handlers *together*, so it moved two variables at once. One flag must gate one
> variable — that is the lesson worth keeping from this whole episode.
>
> `IOC_FS_COMMANDS` gated the volume handlers and the filesystem handlers
> together, so every build that linked FatFs ALSO linked the `vol_name()` defect
> in section 2 -- and every build that stripped one stripped the other. FatFs
> was never once tested without the actual fault present. Across all eleven
> builds, `vol_name()` predicts the result 11/11; `ff.c` predicts 2/11.
>
> **The retest has now been run: FatFs links and the firmware boots.** It was
> never the cause. `IOC_FATFS` defaults to 1.
>
> The measurements below stand; only the causal claim was wrong.
>
> | Build | Flash | RAM | `ff.c` | Result |
> |---|---:|---:|:--:|---|
> | HEAD | 60,042 | 7,379 | no | boots |
> | Feature code, mount path dead-stripped | 74,057 | 9,291 | no | boots |
> | HEAD + 36 KB inert `const` | 96,906 | 7,379 | no | boots |
> | FatFs read-only | 86,947 | 9,284 | yes | **reset-loops** |
> | FatFs full | 100,671 | 9,369 | yes | **reset-loops** |
>
> Not size: the failing builds are smaller than the passing control. Not RAM.
> Not the compiler helper set -- identical in all three. Not execution: nothing
> called FatFs during boot in either failing build.
>
> ### 2. The actual fault
>
> The purpose-built resolver reset-looped too, at 68,864 bytes -- smaller in
> both flash and RAM than the 74,057-byte build that boots. Further bisection,
> one construct per build:
>
> - Moving the two new commands out of the `switch` into `if`s: still failed.
> - Dead-stripping the two handlers: **booted**.
> - A new handler that calls into `sd_cache`, linked but never run: **booted**.
>   (So a second caller into the shared cache was not the trigger.)
> - The handlers live with the resolver stubbed to `return NO_FS`: **failed**.
>
> That narrowed it to twelve small functions, and to one construct in them:
>
> ```c
> static const uint8_t blank_name[11] = { ' ', ... };
> const uint8_t *vol_name(uint8_t unit)
> { return (unit < VOL_UNITS) ? units[unit].name : blank_name; }
> ```
>
> On PIC18 a `const` object lives in program memory, so that returns a pointer
> whose target address space is not known until run time -- and it was passed to
> `memcpy()`. Replacing the five accessors with one `vol_report()` that fills a
> plain byte array **fixed it**. The offending function was never called.
>
> **Rule for this firmware: do not return a pointer that may address either RAM
> or program memory.** XC8 cannot analyse this call graph at all (warning 1393,
> from TinyUSB's function-pointer driver tables), so constructs that merely ask
> something unusual of it are not safe here even when unreachable.
> `Code/MCU/IOController/docs/max3421-bring-up-debug.md` records six earlier
> silent corruptions from the same allocator.
>
> ### 3. Two ordinary bugs, found once it booted
>
> `CMD_VOL_INFO` called `vol_ensure_mounted()`. That can run `sd_card_init()`
> (about a second at 125 kHz, well past the BIOS IOCALL timeout -- the query
> returned `IOC_XPORT_TIMEOUT_REPLY_MARKER`), and when the card session is lost
> it calls `vol_init()`, which discards every mount. **Asking what was mounted
> could unmount it.** A status query is now non-blocking and side-effect free.
>
> `vol_service()` ran the auto-mount without dropping COMMAND_READY, so a
> request arriving mid-mount waited past the host's timeout. It now follows the
> same rule the cache flush does.
>
> ### What is built
>
> `src/fatmap.c` -- read-only FAT16/FAT32, mount-time only, no recursion, no
> function pointers, no buffers (it reads through `sd_cache_read_bytes`). About
> +8.7 KB flash and +0.5 KB RAM, against FatFs's +26.6 KB and +2.0 KB. It is
> what Part 1 ships on, and it is kept because it is small and proven -- not
> because FatFs was ruled out.
>
> `VOLINFO.COM` on A: reports the live mode. `IOC_FATFS=1` links FatFs,
> `src/sdfs.c`, `src/diskio.c` and `src/fs_share.c` and re-enables the eight
> `CMD_FS_*` commands, for Part 2.
>
> ### 4. One more bug, and the one that cost the most for the least reason
>
> `external_sync.c`'s `is_command_class()` is a whitelist the RECEIVER uses to
> validate a frame, and an unlisted class is dropped *silently* -- no reply at
> all, because `service_command_request()` sends nothing when the receive fails.
> The host sees `IOC_XPORT_TIMEOUT_REPLY_MARKER`, which reads as a dead
> controller, rather than `RSP_UNKNOWN_COMMAND`, which would name the problem.
>
> `CMD_VOL_INFO` was added to `ioc_frame.h` and `dispatch.c` and not to that
> list. **A new command needs all three.**
>
> ---
>
Status: **implemented, not yet run on hardware.** Phases 2-4 of the sequence at
the end of this document are done; every gate in them is still outstanding,
because they all require a card and a machine. Nothing below has been changed
to describe the implementation -- the design held as written, and the one
correction is in the table immediately under this line.

### What the implementation changed about the numbers

The measured costs below were taken against a working tree that has since
shrunk. They are still directionally right and the conclusion is unchanged, but
do not compare against them directly:

| | Design doc | As built |
|---|---:|---:|
| Baseline flash | 65,095 (49.7%) | 60,042 (45.8%) |
| Baseline RAM | 7,442 (58.1%) | 7,379 (57.6%) |
| Flash with both features | 94,845 (72.4%) | 100,635 (76.8%) |
| RAM with both features | 8,433 (65.9%) | 9,388 (73.3%) |

The built figures are higher than the projection because the four spike builds
linked FatFs and a harness only -- they measured the library, not the volume
layer, the eight filesystem commands, the extent tables or the 512-byte chunk
buffer. 30 KB of flash and 3.4 KB of RAM remain.

### Where the code went

| Piece | File |
|---|---|
| FatFs R0.15, own copy, own ffconf.h | `Code/MCU/IOController/third_party/fatfs/` |
| Media layer, through the block cache | `src/diskio.c` |
| The one FATFS object and its mount | `src/sdfs.c`, `include/sdfs.h` |
| Extent table, mapping, mount policy | `src/volume.c`, `include/volume.h` |
| The eight `CMD_FS_*` commands | `src/fs_share.c`, `include/fs_share.h` |
| `CMD_VOL_MOUNT` / `CMD_VOL_INFO` | `src/handlers.c` |
| Card status to wire status, shared | `src/ioc_status.c` |
| Transients | `Code/HOST/HelloWorld/src/sd{dir,get,put,del}.asm`, `sdfs.inc` |

The transients ship on the ROM rescue disk (A:) in the **normal** profile, added
to the manifest in `tools/build_rom_disk.py`. No `.cpm` volume was touched.

### Two things the design did not cover, decided during implementation

**A lost card session invalidates every mount.** `vol_ensure_mounted()` checks
`sd_card_is_initialized()` on every call, and discards all mount state when the
session has gone. An extent table is a snapshot of one card's cluster chain; if
the card is swapped, that table addresses arbitrary data on the new one while
reporting success. The check sits before `sd_card_init()`, so a card that stays
dead costs one init attempt per access exactly as it did before volumes existed,
and no FatFs work at all.

**The record commands report volume failures distinctly.** `vol_read_record()`
and `vol_write_record()` return a wire status rather than an `SdStatus`, because
the two ways they fail without the card being at fault -- no volume on that unit
(`IOC_STATUS_VOL_UNMOUNTED`), and a record past the end of one
(`IOC_STATUS_VOL_RANGE`) -- have no `SdStatus` to carry them. Reporting either
as `SD_ERR_READ` would send somebody chasing a card problem that is not there.

---

Original design follows, unedited.

All memory figures below are measured against the working tree at the time of
writing, not estimated.

Two related proposals:

1. Stop `dd`-ing an image onto the raw card. Keep the 8 MiB volumes as ordinary
   files (`CPM_1.DRV`, `CPM_2.DRV`) on a FAT32 card, and have the controller
   serve CP/M records out of a named file.
2. Add a small set of controller commands so a CP/M transient can list, read and
   write files in one shared directory on that same card. Not a BIOS feature —
   user space only.

## Executive summary

Both fit, with room left over. FatFs R0.15 is already vendored in the tree under
`Code/MCU/IOController/third_party/tinyusb/lib/fatfs`.

| | Value |
|---|---|
| Flash after both features | 94,845 of 131,072 bytes (72.4%) |
| RAM after both features | 8,433 of 12,800 bytes, plus the 512-byte data stack (65.9%) |
| CP/M sector hot path | Unchanged — FatFs never runs per record |
| Required BIOS changes | None |

The design point that makes this cheap is not the library choice. It is that
**FatFs resolves the image file once, at mount, and is then out of the picture.**
Every CP/M record afterwards goes through exactly the code that runs today, with
one addition to the address calculation. The block cache, the write-back policy,
the bulk lane and the READY/DONE lifecycle never learn that a filesystem exists.

## Measured cost

Four builds of the current firmware against XC8 v3.10, `-mstack=hybrid:512:0:0`,
`PIC18F57Q84`. Each build links a harness that calls every FatFs entry point the
design needs, so nothing is dead-stripped — an earlier attempt without the
harness reported a misleadingly small +193 bytes because the linker had removed
the whole library.

| Build | Program | Flash left | Data | RAM left |
|---|---:|---:|---:|---:|
| Today (HEAD) | 65,095 (49.7%) | 65,977 | 7,442 (58.1%) | 4,846 |
| + FatFs, read-only | 80,615 (61.5%) | 50,457 | 8,204 (64.1%) | 4,084 |
| + FatFs, read/write | 92,709 (70.7%) | 38,363 | 8,260 (64.5%) | 4,028 |
| + read/write and fast-seek | 94,845 (72.4%) | 36,227 | 8,433 (65.9%) | 3,855 |

Deltas against baseline: read-only costs **+15,520 bytes flash, +762 bytes RAM**;
the full configuration costs **+29,750 bytes flash, +991 bytes RAM**. "RAM left"
subtracts the 512-byte data stack, which XC8 reports separately and which already
sits at 100% of its own allocation.

Harness entry points: `f_mount`, `f_open`, `f_lseek(CREATE_LINKMAP)`, `f_read`,
`f_write`, `f_truncate`, `f_sync`, `f_opendir`, `f_readdir`, `f_stat`,
`f_unlink`.

### Configuration

Long filenames off, exFAT off, `FF_FS_TINY` on, one volume, no `mkfs`, no
locking, no RTC. That combination is what holds the RAM cost under 1 KiB: in tiny
mode the single 512-byte sector window lives in the `FATFS` object and every
`FIL` and `DIR` shares it. Turning LFN off also drops `ffunicode.c` entirely —
with `FF_USE_LFN 0` nothing in `ff.c` references it.

**Recommend against exFAT.** FatFs requires LFN to enable it, which pulls the
Unicode tables back in, and it buys nothing at this scale: 8 MiB files on a card
of 32 GB or less are squarely FAT32 territory. FAT16 comes along for free, so a
small card formatted the obvious way also works. If a 64 GB card ever has to be
used exactly as it shipped, exFAT is two lines in `ffconf.h` and a re-measure.

## Part 1 — drive images as files

The controller opens `/CPM/CPM_1.DRV` once, checks it is exactly 8 MiB, and asks
FatFs for its cluster link map. From that it builds a small extent table: a start
LBA and a block count per fragment. A file copied onto a freshly formatted card
is one extent; the table caps at sixteen, which is far more than a real card
produces.

After that, a CP/M record maps to a card block by table lookup and an add. The
image's cluster chain never changes while CP/M is running, because the file's
*size* never changes — CP/M writes into a fixed 8 MiB volume, it does not extend
a file. The map therefore stays valid for the whole session and FatFs is never
re-entered on the image.

```text
  EVERY CP/M RECORD                        ONCE, AT MOUNT

  CMD_SD_READ_REC(unit, record)            CMD_VOL_MOUNT(unit, "CPM_1.DRV")
          |                                            |
          v                                            v
   +---------------+   <-- fills the table --   +---------------+
   |  volume map   |                            |     FatFs     |
   | 16 extents/u  |                            | f_open +      |
   +---------------+                            | CREATE_LINKMAP|
          |  absolute LBA                       +---------------+
          v                                            |
   +------------------------+   <-- disk_read/write ---+
   |  sd_cache  8 x 512 B   |
   +------------------------+
          |
          v
   +------------------------+
   |  sd_card  SPI1, 4 MHz  |
   +------------------------+
          |
          v
      SD card, FAT32
```

Routing FatFs's own `disk_read`/`disk_write` through `sd_cache` keeps exactly one
cached copy of any block, so the two paths cannot disagree and there is no
coherency argument to make.

### Why not read the image through FatFs

Because `f_read` would become the innermost thing in the CP/M sector path. That
means a second 512-byte buffer, a second caching policy sitting on top of a
working one, and a library on the code path whose failure modes nobody here has
characterised — all to compute an address that an add already computes. It would
also put FatFs writes on the same path as CP/M writes, which is where the
write-back cache and FAT metadata start needing to be reasoned about together.

The extent map keeps every one of those questions closed. It is also the
supported way to do this: `f_lseek(fp, CREATE_LINKMAP)` is FatFs's own fast-seek
API, and `fs->database` and `fs->csize` are public fields, so no internals are
reached into.

### Protocol change

| Command | Payload | Reply |
|---|---|---|
| `CMD_VOL_MOUNT` (10h) | `unit`, `name[11]` (8.3, FCB-packed) | status, base LBA, extent count, size in records |
| `CMD_VOL_INFO` (11h) | `unit` | mode (`file`/`raw`/`none`), name, base LBA, size, extents |
| `CMD_SD_READ_REC` (08h) | `record[4]`, `unit` *(new, optional)* | unchanged |
| `CMD_SD_WRITE_REC` (09h) | `record[4]`, `unit` *(new, optional)* | unchanged |

The unit byte lands at payload offset 4, which the 32-byte mailbox already has
room for (`IOC_COMMAND_MAX_DATA` is 26). The firmware reads it only when the
frame's `LEN` is 5 or more and defaults to unit 0 otherwise, so a BIOS built
before this change keeps working against unit 0 with no edit at all.

Who mounts, and when: have the controller auto-mount by convention on first SD
use — the same lazy point at which it initialises the card today — with
`/CPM/CPM_1.DRV` as unit 0 and `CPM_2.DRV` as unit 1. `CMD_VOL_MOUNT` then exists
for a `MOUNT.COM` to swap volumes at runtime, not as something boot depends on.
That ordering matters given how little spare BIOS space there is: the default
path needs zero Z80 code.

### Three things that will bite

**1. The write-through rule is an absolute-LBA rule.**
`sd_cache_write_record()` commits synchronously when `lba == 0`, because LBA 0 is
where the CP/M directory starts. Once the image is based somewhere else, relative
record 0 is no longer LBA 0 — and LBA 0 is now the card's boot sector. Get this
wrong and nothing appears to break: the directory head quietly loses its
synchronous commit and rides the flush timer like everything else. It has to
become a per-unit *relative* test. This is the single highest-value line in the
change.

**2. `SD_CACHE_MAX_RECORD` stops meaning what it says.**
It is `0xFFFF` today because the volume is the card. Absolute records on a 32 GB
card run to about 2^28, so the constant is simultaneously too small for the
address space and no longer a statement about volume size. Move the bound to the
volume layer as a check of the *relative* record against the mounted image's
length, and widen the cache's own arithmetic. Do not simply delete the check: the
header in `sd_cache.h` is right that a wrapped record is the one failure that
destroys data while reporting success.

**3. Raw mode has to survive, and has to be reported.**
A card with an image written straight to LBA 0 has no filesystem to find. The
mount should fall back to today's behaviour — base 0, 65,536 records — and
`CMD_VOL_INFO` must say which mode is live so it is read rather than inferred.
That fallback is also what keeps every existing card and every existing `ioc_sd*`
test working through the transition.

### Invariant worth writing down

Nothing may ever write a mounted image *through* FatFs. The extent map is a
snapshot of the cluster chain; a FatFs write that reallocated or freed those
clusters would leave CP/M addressing blocks the filesystem has handed to
something else. Keeping images in `/CPM/` and confining every filesystem command
to `/SHARED/` makes it structurally impossible rather than a rule someone has to
remember.

## Part 2 — a shared folder for user space

Cheaper than it looks, because the transport a transient needs already exists and
is already published ABI: `IOCALL` at DA3Fh, `IOCBULK` at DA45h, `IOCBULKW` at
DA48h. `IOC_SDREC.COM` and `HIDSTAT.COM` drive the controller through them today
without going near the storage driver. The entire feature is therefore new
firmware commands plus a few transients — **no BIOS change, no jump-table change,
no memory-layout change.**

| Command | Payload | Returns |
|---|---|---|
| `CMD_FS_OPENDIR` (20h) | — | status |
| `CMD_FS_READDIR` (21h) | — | `name[11]`, attr, `size[4]`, more flag |
| `CMD_FS_OPEN` (22h) | mode, `name[11]` | handle, `size[4]` |
| `CMD_FS_READ` (23h) | handle, `offset[4]`, `len[2]` | READY, then bulk out (max 512 B) |
| `CMD_FS_WRITE` (24h) | handle, `offset[4]`, `len[2]` | READY, then bulk in, then DONE |
| `CMD_FS_CLOSE` (25h) | handle, `final_size[4]` | status after truncate and flush |
| `CMD_FS_STAT` (26h) | `name[11]` | `size[4]`, attr |
| `CMD_FS_DELETE` (27h) | `name[11]` | status |

Eight commands, all fitting the existing 32-byte mailbox, all reusing the READY /
BULK / DONE lifecycle unchanged. Responses follow the established `CMD | 80h`
convention. Tools: `SDDIR.COM`, `SDGET.COM`, `SDPUT.COM`, `SDDEL.COM`.

### Five decisions inside that table

**Chunked, never whole-file.** This is load-bearing rather than tidy.
`hid_host_task()` runs only on the idle branch of the controller's main loop,
after any command in flight has fully completed — that placement is deliberate
and documented in `src/main.c`. A "copy this file" command would therefore hold
USB off for the length of the whole copy, and the keyboard would drop keystrokes
exactly while somebody is watching a transfer. Capping every data command at 512
bytes returns to the loop between chunks and keeps HID alive.

**An explicit offset on every read and write.** Four bytes out of a payload with
room for twenty-six, and it makes reads idempotent. With an implicit file
position, a retried transaction — which is a thing this link does — silently
advances twice and corrupts the copy in a way that only shows up in the middle of
a file. Cache the current position and skip the `f_lseek` when the offset already
matches, so sequential access pays nothing.

**Names in packed 8.3, not C strings.** Eleven bytes, space-padded, no dot: the
FCB layout. CP/M cannot express anything longer anyway, and this way the transient
drops the reply straight into an FCB with no parsing. The conversion from FatFs's
`"NAME.EXT"` is a few lines of C on the PIC instead of a few dozen of Z80.

**The exact length goes on close.** CP/M files are 128-byte granular and carry no
true length, so a naive copy out lands padded. `CMD_FS_CLOSE` taking a final size
and calling `f_truncate` means a text file written from CP/M arrives on the host
at the byte the user meant.

**The controller builds the path, never the caller.** The firmware prepends
`/SHARED/` and rejects any name containing a separator or a traversal. This is not
hypothetical hardening — the same card holds the boot images, and a path
parameter is the one way a user program could reach them.

### Housekeeping

One directory session and one file handle is enough; the controller serves one
command at a time and there is one Z80. Have `CMD_FS_OPEN` implicitly close
whatever was open, so a transient that dies mid-copy cannot leak a handle, and
flush the cache on `CMD_FS_CLOSE` so FAT and directory updates do not sit dirty
behind a write-back timer.

## Risks

### XC8's overlay allocator

`Code/MCU/IOController/docs/max3421-bring-up-debug.md` records six silent
corruptions traced to XC8 overlaying live state across calls, and the standing
`(1393) estimated stack depth: unknown (due to recursion)` warning is the same
defect reporting itself. Adding 7,000 lines of new code to that allocator is not
free.

The mitigating fact is specific: those failures came from TinyUSB's
function-pointer driver tables, which make the call graph look cyclic. FatFs has
no function pointers and no recursion, so its own call graph is analysable, and
the spike build added no new recursion warning. That is reassuring, not proof.
The cheap insurance is a `CMD_FS_SELFTEST` that mounts, reads a file of known
content and returns a checksum — run before anything is trusted, and kept
afterwards.

### Flash headroom

72.4% leaves 36 KB, and the MAX3421E work still has to fit in it. If that gets
tight, the read-only configuration lands at 61.5% and still delivers all of
Part 1 and the `SDDIR`/`SDGET` half of Part 2; only writing back to the shared
folder would wait.

### Latency

A filesystem command that touches a cold FAT or directory sector costs a real
card read, and a card that has to re-initialise costs a full CMD0/ACMD41 sequence
at 125 kHz. The Z80's `IOCALL` timeout already has to cover card init, so it is
probably fine — but that is a thing to measure on the first mount, not assume.
Mount happens once; it is allowed to be slow.

### Fragmentation and power loss

A sixteen-extent cap refuses a pathologically fragmented image rather than
silently mis-addressing it, and the remedy — copy it onto a freshly formatted
card — is one the user can act on if the error says so. Separately, there is now
FAT metadata that a power cut can damage, where before there was only image
content. The shutdown flush on `/SHUTDOWN_RQ` already exists and covers the
ordinary case; `CMD_FS_CLOSE` flushing covers the rest.

## Suggested sequence

Each phase ends somewhere the system is shippable and the previous behaviour is
still reachable. The ordering settles the riskiest unknown — whether FatFs and
XC8 get along — before any protocol is designed around it.

1. **Prove it fits.** Done; the four builds above. Nothing committed, spike in
   scratch.
2. **Vendor FatFs, change nothing else.** Copy `ff.c`, `ff.h`, `ffconf.h`,
   `ffsystem.c` out from under `third_party/tinyusb/lib/` into their own
   third-party directory so the TinyUSB pin and the FatFs config stay
   independent. Add a `diskio.c` that routes through `sd_cache`, and one
   `CMD_FS_SELFTEST`. No protocol change, no storage change.
   *Gate:* selftest mounts a real card; `IOC_SDREC`, `IOC_SDBLK` and the HID path
   still pass unchanged.
3. **The volume layer.** Extent table, `CMD_VOL_MOUNT`/`CMD_VOL_INFO`, the
   optional unit byte, raw-mode fallback, and the three traps above.
   *Gate:* `IOC_SDREC.COM` passes against a based image byte-for-byte as it does
   against a raw card; then CP/M boots B: from `CPM_1.DRV`.
4. **The shared folder.** The eight `CMD_FS_*` commands and the transients.
   *Gate:* round-trip a file out to the card and back in, byte identical, with a
   keyboard attached and responsive throughout.

## Open decisions

1. **Convention or configuration?** This assumes the controller auto-mounts
   `/CPM/CPM_1.DRV` as unit 0 by convention, because that needs no Z80 code. The
   alternative is a small text file on the card, friendlier but it adds a parser.
2. **How many units?** Two covers A: and B:. The extent table is 128 bytes per
   unit, so four is affordable, but only if the BIOS is going to grow drive
   letters to use them.
3. **Does A: stay in ROM?** The recent ROM filesystem work suggests yes, and that
   keeps a recovery volume no bad card can damage.
4. **Chunk size for the file tools.** 128 bytes lets `SDGET.COM` hand each chunk
   straight to a BDOS record write with no buffer; 512 is four times fewer round
   trips for a 512-byte TPA buffer. The protocol carries the length either way,
   so this is only a default.

## Related

- `docs/z80-banked-disk-caching.md` — the Z80-side banked cache proposal, which
  shares the record/block addressing model and needs a unit field in its tags
  once more than one image can be mounted.
- `Code/MCU/IOController/include/sd_cache.h` — the record/block bridge whose
  write-through and bounds rules Part 1 changes.
- `Code/MCU/IOController/docs/max3421-bring-up-debug.md` — the XC8 overlay
  history the risk section refers to.
