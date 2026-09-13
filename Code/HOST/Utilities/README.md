# Zephyr-80 Utilities

The programs that are **part of the machine**, as opposed to programs that run
on it. Everything here speaks the IO Controller protocol, drives BIOS-owned
hardware, or exists to recover a machine that is misbehaving — so it is
versioned with the BIOS and the controller firmware, not with your software.

Programs that merely run on Zephyr-80 belong in `../Software`; demos,
experiments and bring-up sketches belong in `../HelloWorld`.

## Building

```sh
make              # both profiles
make normal       # just the ROM rescue set
make diagnostic   # just the diagnostics
make list         # show which is which
```

Output is `build/*.com`. `../CPM2.2` collects them from there when it builds the
ROM A: volume — it does not build them itself.

## Calling the operating system

The operating system runs from its own SRAM bank and publishes no fixed
addresses, so every tool reaches it through `CALL 5`. `src/zbdos.inc` provides
the Zephyr BDOS functions under the names tools already used:

| Name | Function | What |
|---|---:|---|
| `IOCALL` | 214 | IO Controller command/reply |
| `VIDEO_SEND` | 215 | video command stream |
| `IOCBULK`, `IOCBULKW` | 216, 217 | IO Controller bulk receive and transmit |
| `zb_move`, `zb_xmove`, `zb_selmem` | 210-212 | bank primitives; call `zb_selmem` from common memory only |
| `zb_xport_level` | 203 | `A` = the BIOS IO Controller transport level |
| `zb_diag_iy`, `zb_sercon_iy` | 203 | `IY` = the IOC link failure record, or the serial console flags byte |

Include it at the end of a program: it assembles code. Buffers passed to these
calls can be anywhere in the program's memory, because the BIOS copies them
through common memory. `IY` survives BDOS calls, so a tool can load it once.

A tool that needs a timer interrupt registers a CTC callback with BDOS function
200. The callback, and everything it touches, must be copied into
`E000h-E3FFh` first. `SDSOAK` is the worked example.

## The two profiles

**`normal`** is the ROM rescue disk: what you want present when the machine is
in trouble and A: is the only volume you can trust.

| | |
|---|---|
| `PING` | Version, transport, power and controller health. Non-destructive. |
| `RESET` | Resets host and controller together. |
| `SDREAD` | Command-lane SD read; separates controller/SD failure from CP/M filesystem failure. |
| `SDFMT` | **Destructive.** Provisioning — a fresh SD volume needs its directory initialised, and without this a new card cannot be made usable at all. |
| `HIDKEY` | Separates IOC key translation and queueing from BIOS `CONST`/`CONIN`. |
| `PADSTAT` | Passive USB/gamepad enumeration status. |
| `SERCON` | Arms or disarms the serial console tee — what you reach for when the screen is dark. |
| `NOWRAP` / `WRAPON` | Console line-wrap configuration. |
| `VOLINFO` | Which addressing mode each storage unit is really using: an image file on a FAT card, or the raw card. |
| `SDDIR` `SDGET` `SDPUT` `SDDEL` | The `/SHARED/` folder tools. With a FAT card in the socket, these are how a file gets off this machine or onto it when nothing else works. |

**`diagnostic`** is bring-up and benchmark work, and most of it is
**destructive**: `SDWRITE`, `SDREC`, `SDSOAK` and `SDBENCH` act on whatever card
is inserted, with no drive letter to get wrong. They have no business on the
disk you reach for when the machine is already in trouble, which is why the ROM
manifest in `../CPM2.2/tools/build_rom_disk.py` carries them only on the
diagnostic profile. Nothing is deleted by that split — everything here always
builds.

## `src/ioc_diag_record.inc` is a mirror, not an original

The IOC failure-record layout is owned by `../CPM2.2/src/cbios_defs.inc`. This
copy gives the tools the record's field offsets, and `make` checks the two agree
before building anything. The record's address is not compiled in: tools read it
from BDOS function 203 at run time (`zb_diag_iy`).

That check is not ceremony. A tool built against a stale layout **assembles
cleanly and only lies at runtime** — in the one report anybody consults when the
link is dead. The mirror has drifted from the BIOS once already.

## Adding a command to the protocol

Three edits, not two:

1. `../MCU/IOController/include/ioc_frame.h` — the opcode
2. `../MCU/IOController/src/dispatch.c` — the handler
3. `../MCU/IOController/src/external_sync.c` — **`is_command_class()`**

That third one is a receiver-side whitelist. An unlisted class is dropped
*silently*, with no reply at all, so the host reports
`IOC_XPORT_TIMEOUT_REPLY_MARKER` — which reads as a dead controller rather than
"unknown command".
