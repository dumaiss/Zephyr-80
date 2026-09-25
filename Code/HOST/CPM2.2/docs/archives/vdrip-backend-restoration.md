# Restoring the VDrip Backends

`CONSOLE=vdrip` does not build. This note records why, what it would take, and
which numbers are measured rather than inherited, so the work can be picked up
without re-deriving it.

The motivation is video development: a working VDrip display backend is how a
new video card gets exercised from CP/M before the hardware exists. Nothing
here is needed for the current machine — ROM A:, the V9958 console and SD
through the IO Controller all work.

Measured against the tree at the time of writing. Every size below came from a
build, not from a comment; see **Stale numbers** for why that distinction is
laboured.

## Target configuration

- ZSDOS + ZCPR2 — already the only supported combination
- Current memory and IRQ management — unchanged
- ROM as drive A: — the rule for all builds
- VDrip storage (drive B:) and VDrip display selectable **independently** at
  build time — *as originally framed; see* **Scope**, *which questions whether
  the storage half is wanted at all*

## Current state

`CONSOLE=vdrip` fails for both `STORAGE_A=rom` and `STORAGE_A=vdrip`, at the
same place. Storage is not the variable; the console is.

Until recently it failed earlier still, on three undefined symbols: `GETCHAR`
and `NBYTES`, referenced by `ccp_read_up_sequence` in
`src/cbios_console_vdrip.asm`. Those are internals of the stock CP/M 2.2 CCP,
defined only in `cpm22/cpm22.asm`, which `Makefile:267` no longer assembles.
That routine's only caller was `cpm22.asm:1539`, and
`Zephyr-80_OS_Execution_Memory_Architecture.md` already described both it and
`ccp_clear_redraw` as removed — `ccp_clear_redraw` genuinely was, this one was
missed in the VDrip console only. It has since been deleted. Cursor-up history
recall belonged to a command processor that no longer exists; it does not need
reimplementing in any form.

With that gone, assembly and linking succeed and the build fails in
`check_overlap`.

## The blocker: the transport is in the wrong bank

Common memory, `E000h`-`FFFFh`, **is SRAM bank 0** in both latch modes. Every
other driver has already moved to bank 7:

| Driver | Where | Bank |
|---|---|---|
| Console backend, driver slot 0 | `4800h`-`5FFFh` | 7 |
| SD-card backend | `4000h`-`42FFh` | 7 |
| Drive A: backend | `4330h`-`43FFh` | 7 |
| Drive dispatcher | `4400h`-`47FFh` | 7 |
| IOC command lane | `3400h`-`38FFh` | 7 |
| IOC bulk lane | `3A00h`-`3CFFh` | 7 |
| **VDrip transport** | `F680h`-`F90Dh` | **0** |

Driver slot 0 holds *one* console backend. `cbios_console_v9958.asm` and
`cbios_console_vdrip.asm` both `.org` at `CBIOS_DRIVER_SLOT0_BASE` and the
Makefile links exactly one (`CONSOLE_SRC`), the same way the drive A: backends
share `CBIOS_STORAGE_A_CODE_BASE`. VDrip **replaces** the V9958 console; it does
not sit beside it. Measured: V9958 3191 bytes, VDrip 3296 (`4800h`-`54E0h`), in
a 6144-byte slot.

So the VDrip *console driver* is not the problem — it already builds, in bank 7,
in the slot it is meant to occupy. The straggler is the 654-byte transport, the
last driver body still resident in bank 0.

So this is a misplacement, not a wall. The reason it cannot simply stay where
it is: bank 0 has no room left for it. Driver slot 5 (`F680h`-`FA7Fh`) is
vestigial — the generated map does not mention it, because the range was
reallocated:

| Range | Owner | Free |
|---|---|---:|
| `F538h`-`F72Fh` | Crossing gates | 16 |
| `F730h`-`F82Fh` | Interrupt dispatch | 18 |
| `F830h`-`F957h` | Serial console tee | 1 |

Bank 0 has 243 bytes free in total, largest run 62. A transport starting at
`F680h` lands on the IRQ dispatcher and the sercon tee, which is what
`check_overlap` reports:

```
F680-F68C ( 13 bytes)  near vdrip_tr@F680
F68E-F71F (146 bytes)  near vdrip_tr@F684
F730-F789 ( 90 bytes)  near ctc0_isr@F730
F78B-F793 (  9 bytes)  near vdrip_se@F780
F797-F7C5 ( 47 bytes)  near vdrip_se@F794
F7F7-F81D ( 39 bytes)  near irq_ff_u@F7F7
```

A VDrip-console build does not link the sercon tee, freeing `F830h`-`F957h`,
but that is 296 contiguous bytes against 654 needed. Bank 0 cannot hold it and
should not: it belongs in bank 7 with the drivers it serves.

`STORAGE_A=vdrip` adds a second, independent overlap at `4400h`-`4493h`: the
VDrip storage backend is 356 bytes and the drive A: slot (`4330h`-`43FFh`) has
208, so it runs into the drive dispatcher. See item 4.

## Scope: is VDrip storage still wanted?

**Decide this first — it halves the work.**

The motivating goal is testing video backends, which needs `CONSOLE=vdrip` and
nothing else. VDrip storage is an escape hatch, not a working storage backend:
the SD card through the IO Controller works, and `SDGET`/`SDPUT`/`XFER` cover
moving files onto the machine.

If VDrip stays **display-only**, items 2, 3 and 4 are unnecessary. They exist
solely to let storage and display be chosen independently:

- item 2 is moot — today's rule, transport linked iff `CONSOLE=vdrip`, is
  already right when VDrip is display-only
- item 3 is moot for the same reason: `VDRIP_TRANSPORT_LINKED` continues to
  mean "driver slot 0 is VDrip", so the five conditionals stay correct by
  construction rather than by accident
- item 4 goes away, and takes the `4400h`-`4493h` overlap with it

That leaves **item 1 and item 5**, and item 5 is small.

The combination that motivated the split — `STORAGE_B=vdrip CONSOLE=v9958`,
VDrip storage with the real V9958 card driving the screen — is buildable in
principle but has no identified use case. Items 2-4 are kept below in case that
changes; they are not on the critical path.

## Work items

### 1. Move the VDrip transport to bank 7

Where the other drivers already are, following the pattern the tree uses for
the IOC lanes: body in bank 7, small shim in common. The IOC command and bulk
lanes do exactly this with 34 bytes of shim at `3900h`-`39FFh`.

Bank 7 has the room — the drive dispatcher region has 869 bytes free and the
image ends at `883Fh` with `8840h`-`BFFFh` open for growth.

**The one real question, and the first thing to settle:** what must stay
resident in bank 0. Anything on the SIO interrupt path cannot move, because an
interrupt can arrive while another bank is mapped. `sio_core.asm:92` conditions
VDrip receive-error state (`SIO0B_LAST_RR1`, `SIO0B_LAST_RX_ERROR`) on
`VDRIP_TRANSPORT_LINKED`, which suggests some receive handling is in the ISR —
but this has **not** been traced. The answer decides whether the transport
moves wholesale or splits into a bank 7 body plus a resident stub, and how big
that stub has to be. Bank 0 can afford a small one; it cannot afford 654 bytes.

### 2. Split the build axes

`VDRIP_TRANSPORT_LINKED` is derived solely from `CONSOLE=vdrip`
(`Makefile:57-65`), and `STORAGE_A=vdrip` is rejected unless the console is
VDrip too (`Makefile:51-53`). The target needs:

- `CONSOLE = v9958 | vdrip | sio`
- `STORAGE_B = sd | vdrip` — new
- transport linked if *either* asks for it
- `STORAGE_A` retired, or pinned to `rom`

### 3. Audit the conditionals that conflate the two axes

Five sites test `VDRIP_TRANSPORT_LINKED`: `cbios_boot.asm:16,79,176` and
`sio_core.asm:92,154`. While the flag means "the console is VDrip" they are
correct by accident; once the axes split they must each be reclassified as
console-dependent or transport-dependent.

At least one is already wrong under the target scheme: `cbios_boot.asm:16`
gates the serial console tee on the transport flag. That is a console question
— VDrip storage under a V9958 console links the transport but should still
install the tee.

### 4. Make drive B: selectable

B: is hardwired to the SD card; the dispatcher routes on the drive SELDSK last
selected. There is already a `stg_a_*` indirection to copy and a
`4300h`–`432Fh` "B: select probe" region.

- Size a B: backend slot for `max(SD, VDrip)`, not for ROM's 169 bytes
- Move the SD block-0 probe behind the backend selection
- Both backends `.org` at the new base and export identical `stg_b_*` entries

### 5. Pin A: to ROM

Retire `cbios_storage_ramdisk.asm`, repurpose `cbios_storage_vdrip.asm` as a B:
backend, and rewrite the "A: is a build-time choice" contract at the head of
`cbios_storage.asm`.

## Stale numbers

This tree has been bitten by trusted-but-stale figures before —
`LESSONS-LEARNED.md` §2 records the 633/338 case that caused the slot 5
realignment. The same thing had happened again to every number describing this
configuration:

| Claim | Where | Reality |
|---|---|---|
| Transport is 649 bytes | `cbios_defs.inc` | 654 (`F680h`–`F90Dh`) |
| Console bases are at `E000h` | `cbios_defs.inc:859-860` | `4800h`, bank 7 — the trailing comment predates the move |
| Fails by 29 bytes over driver slot 5 | `Makefile:24` | Slot 5 no longer exists as free space; the failure is ~344 bytes of overlap against the IRQ dispatcher and sercon |
| Fails by 22 bytes over driver slot 5 | `LESSONS-LEARNED.md` §7 | as above |
| `CONSOLE=vdrip STORAGE_A=rom` builds normally | `Makefile:38` | It does not, and did not before the `GETCHAR` fix either |
| Fails layout validation naming `STORAGE_A_CODE_END` | `Makefile:24-25` | Fails in `check_overlap`, naming `vdrip_tr`, `ctc0_isr` and `irq_ff_u` |

`cbios_defs.inc:114` says it plainly: the region comments below it "were
written for the fixed-slot common BIOS and still give old common addresses and
slot numbers for regions that moved". That warning covers most of the slot 5
text.

`docs/memory-map.md` is generated on every build and was accurate throughout.
**Prefer it to any prose comment**, including this document.

## Reproducing

```sh
# Both fail identically in check_overlap; BUILD_DIR keeps the ROM build clean.
make BUILD_DIR=/tmp/vd CONSOLE=vdrip STORAGE_A=rom
make BUILD_DIR=/tmp/vd CONSOLE=vdrip STORAGE_A=vdrip
```
