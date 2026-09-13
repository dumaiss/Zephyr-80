# Zephyr-80 CP/M 2.2

Zephyr-80 is a Z80-based CP/M 2.2 machine and firmware target. This directory
builds its ROM: ZSDOS and ZCPR2 on a local Zephyr-80 CBIOS, with banked RAM,
ROM/SD storage, and build-selectable physical-V9958 or Virtual Drip console
backends.

The project is part of the broader pBITz / coffee-machine retro-computing
family. It is hobby and experimental firmware, but the code tries to keep the
low-level contracts explicit: memory ownership is declared in one place, region
limits are checked by the assembler and the build, and the program interface is
a short, documented list.

## Current Status

Implemented now:

- CP/M 2.2 boots with ZSDOS as the BDOS and ZCPR2 as the command processor.
- The operating system — ZSDOS, the BIOS and its drivers — runs from SRAM bank
  7, behind a BDOS facade in common memory. It needs memory decoder revision 11.
- Programs get a 59 KiB transient area, `0100h-EC05h`.
- Drive A is a read-only ROM volume by default; drive B is backed by SD card.
- The default console drives the LunchCrema V9958 directly and reads terminal
  bytes only from the IOC HID queue.
- The Virtual Drip console remains available as a build-time compatibility
  backend and retains its SIO0/B flow control and proxy keyboard behavior.
- SIO1 is initialized as a BIOS-owned synchronous IO Controller link.
- `IOCALL`, `IOCBULK`, `IOCBULKW`, `VIDEO_SEND` and the banking services are
  Zephyr BDOS functions.
- The BIOS owns IM2; programs get CTC interrupts by registering a callback.

Planned later:

- Measure the BIOS stacks on this layout; their sizes are hand-assigned.
- Move the programs that still install private IM2 tables — the VGM player, the
  trackers and `ctctest_interrupts` — to callback registration.

## Architecture Summary

`src/zephyr.asm` assembles the whole address space in one link and includes the
local CBIOS modules. `tools/split_banked_image.py` cuts the result in two:

- ROM page 0: the reset vector and common memory, with ZCPR2 installed at
  `CBASE`
- the bank 7 payload, ROM page 7: the BIOS and drivers, with ZSDOS installed at
  `2000h`

The split refuses to emit anything that would land in the wrong place: code in
`0003h-1FFFh`, code in bank 7's runtime-only `C000h-DFFFh`, or a ZSDOS or CCP
image without its expected entry jumps.

At reset the ROM copy loads each page into the matching SRAM bank, so page 7
becomes bank 7 with no loader of its own. Cold boot checks bank 7's image marker,
initializes everything in operating-system mode, and enters the CCP in
application mode.

Warm boot restores the CCP range from ROM page 0, reinitializes the console,
resets the CTC and clears interrupt registrations. ZSDOS and the BIOS in bank 7
are left intact.

## Program Interface

Programs call the operating system in three ways.

**`CALL 5`**, the BDOS. `0005h` jumps to `FBASE` (`EC06h`), the BDOS facade in
common memory. The facade switches to its own stack and enters operating-system
mode, then calls ZSDOS in bank 7 and returns to the program's mapping. ZSDOS
handles functions 0-47 and 98-103 as usual. A program's FCB, DMA, console buffer
or time buffer can be anywhere in its memory: the facade copies it across when
ZSDOS cannot see it. Functions 27 and 31 return pointers to copies in common
memory.

**Zephyr BDOS functions**, handled by the facade:

| Function | Service | Inputs | Output |
| ---: | --- | --- | --- |
| 200 | Register CTC callback | `B` = channel 0-3, `DE` = entry in `E000h-E3FFh` | `A` = `00h`, or `FFh` refused |
| 201 | Unregister CTC callback | `B` = channel | `A` = `00h`, or `FFh` |
| 202 | Program exit | — | Clears all registrations; ZCPR2 calls it |
| 203 | System information | — | `HL` = system information block |
| 210-217 | `MOVE`, `XMOVE`, `SELMEM`, `SETBNK`, `IOCALL`, `VIDEO_SEND`, `IOCBULK`, `IOCBULKW` | `DE` = register block | Register block updated; `A` = status |

The register block for 210-217 is seven bytes: `A`, `C`, `B`, `E`, `D`, `L`,
`H`. The services keep their BIOS register contracts, and their buffers can be
anywhere in the program's memory.

The system information block is version 1:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 1 | Version, `01h` |
| 1 | 1 | IO Controller transport level |
| 2 | 2 | IOC link failure record |
| 4 | 2 | Serial console flags byte |
| 6 | 2 | CP/M BIOS jump table |
| 8 | 2 | Zephyr extension table |

`../Utilities/src/zbdos.inc` wraps all of this for assembly programs.

**The CP/M BIOS jump table**, found through page zero's `JP WBOOT`. Only `BOOT`,
`WBOOT`, `CONST`, `CONIN` and `CONOUT` are live. The disk structures live in
bank 7 and ZSDOS uses its own table there, so the disk and auxiliary entries are
inert. They fail cleanly: `SELDSK` returns `HL = 0`, `READ` and `WRITE` return
an error, `LISTST` reports not ready and `READER` returns `^Z`. BDOS list and
punch output still work.

## Memory Map

The layout is declared in the "Banked OS layout" block of `src/cbios_defs.inc`.
Each code region there has a limit. `tools/check_overlap.py` checks the link for
bytes emitted twice, and `tools/generate_memory_docs.py` checks every region
against its limit and the layout invariants, then writes `docs/memory-map.md`
and `docs/symbol-map.md`. Those two are the address authority after each build.

What a program sees:

| Range | Owner |
|---|---|
| `0000h-00FFh` | Page zero, in the program's bank |
| `0100h-DFFFh` | Banked transient program area |
| `E000h-E3FFh` | Program reservation: interrupt callbacks and their data |
| `E400h-EBFFh` | CCP (ZCPR2), restored on warm boot |
| `EC00h-EFFFh` | BDOS facade; serial number at `EC00h`, `FBASE` at `EC06h` |
| `F000h-F957h` | BIOS jump tables, boot, banking, SIO core, crossing gates, interrupt dispatch, serial console |
| `F958h-FC97h` | Staging buffer and the copies returned by BDOS functions 27 and 31 |
| `FD00h-FDFFh` | IM2 vector page |
| `FE00h-FE7Fh` | BIOS runtime state |
| `FE80h-FF5Fh` | Interrupt, gate and facade stacks |

SRAM bank 7, visible at `2000h-DFFFh` only in operating-system mode:

| Range | Owner |
|---|---|
| `2000h-2FFFh` | ZSDOS |
| `3000h-303Fh` | ZSDOS's BIOS jump table and the `BANK7OS1` image marker |
| `3040h-5FFFh` | Console dispatch, storage, IOC transport, HID, SD and ROM-disk backends, V9958 console |
| `6000h-7FFFh` | Disk parameter blocks, directory buffer and allocation vectors |
| `8000h-8FFFh` | Font and boot banner |
| `C000h-DFFFh` | Runtime only: BIOS private stacks at `C000h-C2FFh`, SD scratch buffer from `C300h` |

See [Memory Management](../../../Memory%20Management.md) for the decoder, the
latch modes and the boot copy.

Hand-written walkthroughs:

- `docs/Zephyr-80_OS_Execution_Memory_Architecture.md` — the banked design and
  its invariants
- `docs/zephyr80_bios_walkthrough.md`
- `docs/vdrip_protocol.md`
- `docs/zephyr80_vdrip_disk.md`
- `docs/ctc-and-real-time-programming.md`

The VDrip documents predate the banked operating system and give older
addresses.

## Driver Placement

The BIOS presents stable CP/M entry points and dispatches through facades:

- `src/cbios_console.asm` owns the console facade.
- `src/cbios_storage.asm` owns the storage facade.
- `src/sio_core.asm` owns BIOS SIO hardware plumbing.
- Driver backends provide tables or entry points behind those facades.

Driver code and private state belong in bank 7. Only what must be visible in
both memory modes, or when an interrupt arrives, belongs in common memory:

- interrupt handlers and everything they touch
- code that changes the memory mode, and the stacks it runs on
- buffers that carry a program's data across the mapping

Common memory is 8 KiB, and a byte moved there comes out of every program's
address space.

Bank 7's `C000h-DFFFh` holds only zero-initialized runtime state: the ROM copy
loads just `0000h-BFFFh` of each page. Nothing a drive A: read can target may
live there either, because the ROM-disk read uses shadow/copy mode, which maps
that range to bank 0.

## Interrupt Model

The BIOS owns IM2. `I` is `FDh` from cold boot on, and the vector page at
`FD00h` is a full 256 entries:

| Vector | Target |
|---|---|
| `00h-06h` | CTC channels 0-3: the callback dispatcher |
| `10h-1Eh` | SIO0: the BIOS SIO handler (`10h` is live; the rest cover status-affects-vector) |
| all others | `EI` / `RETI` stub |

Every handler lives in common memory and switches to the common interrupt stack
as its first action, so an interrupt is safe whichever bank is mapped. Handlers
end with `EI` / `RETI`.

CTC channels are programs' to use through registration (BDOS function 200). A
callback must live, with everything it touches, in `E000h-E3FFh`. It runs with
interrupts disabled on the interrupt stack, may use `AF`, `BC`, `DE` and `HL`,
and ends with `RET`. It never calls BDOS or the BIOS. Registrations are cleared
by warm boot and by the program-exit call ZCPR2 makes when a transient returns.
A channel that interrupts without a registration is reset.

The direct V9958 console does not register an SIO0/B receive sink. Its input
path is `IOC HID queue -> CONST/CONIN`, while CONOUT parses ANSI/VT100-light
output and renders through the V9958 command engine. The retained VDrip console
uses SIO0/B with Z80 maskable interrupts:

- Boot and warm boot initialize BIOS-owned SIO services, install runtime state,
  register the console RX sink, and then enable the SIO interrupt path.
- SIO RX interrupts dispatch received bytes to the registered console sink.
- `CONST` checks the input queue; `CONIN` blocks until a byte is available.
- SIO0/B RTS is software-managed by the Virtual Drip console owner, and WR3
  Auto Enables remain off to avoid depending on DCD.

SIO0/B WR1 keeps status-affects-vector disabled, so the SIO emits the exact WR2
vector byte `10h`.

SIO1 is initialized separately for the BIOS-owned IO Controller link:

- synchronous mode, 8-bit RX/TX
- external clock and external sync from the IO Controller MCU
- no parity, no CRC, no SIO1 interrupts

## Build

The default build uses the physical V9958 console, ROM drive A, and SD drive B:

```sh
make
```

It builds ZCPR2 and ZSDOS under a vendored copy of RunCPM (`tools/runcpm`),
which it compiles on first use. `CCP=zcpr2 BDOS=zsdos` is the only supported
combination: the stock CCP and BDOS cannot run behind the banked operating
system. The build also needs Python 3, GNU Make, and the SDCC Z80 tools
`sdasz80`, `sdldz80` and `makebin`.

Select the retained Virtual Drip console at build time with:

```sh
make CONSOLE=vdrip
```

Supported console values are `v9958` (default) and `vdrip`. `STORAGE_A`
selects the drive A backend: `rom` (default), `vdrip` or `ramdisk`. The
Makefile documents the limits on each.

Primary generated artifacts:

| Artifact | Meaning |
|---|---|
| `build/zephyr80.bin` | 512 KiB burnable ROM image |
| `build/zephyr80-zcpr2-zsdos.bin` | the same image, named for its CCP and BDOS |
| `build/firmware.bin` | ROM page 0: reset vector and common memory |
| `build/bank7.bin` | bank 7 payload: ZSDOS, the BIOS and drivers |
| `docs/memory-map.md` | generated memory map, free space and validation report |
| `docs/symbol-map.md` | generated jump tables, IM2 page and symbols |

`make` fails if the layout breaks a validated rule.

The ROM must be paired with memory decoder revision 11 from
`../../HDL/WinCUPL`.

## Repository Layout

```text
src/        Zephyr-80 CBIOS and platform-specific runtime source
zcpr2/      ZCPR2 command processor
zsdos/      ZSDOS, the BDOS
cpm22/      stock CP/M 2.2 CCP+BDOS source with the local patches; not in the banked ROM
cpm-2.2/    upstream submodule: manuals and stock .COM files, not built
tools/      image-building, conversion, and documentation tools
images/     payload and disk-format inputs
docs/       project documentation
build/      generated build outputs
```

## Development Notes

- The program interface is `CALL 5`, including the Zephyr functions, and the
  CP/M BIOS boot and console entries. Nothing else is published at a fixed
  address.
- Keep `src/cbios_defs.inc` the single authority for the layout.
- Never change the memory mode while executing from, or with `SP` in, a range
  the change remaps. Restore the mode bits that were found; never assume
  application mode.
- Bank 7 code never calls `CALL 5`, and interrupt handlers never call BDOS: the
  facade is not reentrant.
- `E000h-E3FFh` belongs to the running program. The operating system must not
  use it.
- Virtual Drip work should clearly distinguish proxy-visible packet protocol
  changes from common core BIOS behavior.
