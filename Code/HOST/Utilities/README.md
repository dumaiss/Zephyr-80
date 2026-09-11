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

A: also carries `PIP`, `STAT`, `ZSID`, `DUMP` and `MONITOR`, which come from
elsewhere in the tree, and four Z-System tools from `zsys/` — see below.

**`diagnostic`** is bring-up and benchmark work, and most of it is
**destructive**: `SDWRITE`, `SDREC`, `SDSOAK` and `SDBENCH` act on whatever card
is inserted, with no drive letter to get wrong. They have no business on the
disk you reach for when the machine is already in trouble, which is why the ROM
manifest in `../CPM2.2/tools/build_rom_disk.py` carries them only on the
diagnostic profile. Nothing is deleted by that split — everything here always
builds.

Not everything on that profile is destructive. `STKCHK` reads memory and prints:
it reports how deep each of the three BIOS private stacks in `FE80h`-`FFFFh` has
actually gone, measured against the fill that cold boot paints across the window.
It is diagnostic rather than normal because it answers one question, and only
while the resident memory layout is being changed — which it currently is, by
`../CPM2.2/docs/Zephyr80_Executable_ROM_Service_Architecture.md`. The figures are
cumulative since cold boot and warm boot does not repaint, so cold boot, run the
workload you care about, then run `STKCHK`.

## `zsys/` — the Z-System set, and why only four of it ships

`zsys/` holds Richard Conn's **ZCPR2 utility set** plus NSWEEP, as prebuilt
binaries. Nothing here builds them; there is no source for them in this tree,
and they are third-party CP/M software rather than part of the machine. They
live here rather than in `../Software` because the ones that ship are carried on
the ROM A: volume alongside the rescue tools, and that manifest reads from this
directory.

They ship **uninstalled** — GENINS has never been run on them, so every external
address in their ZCPR2 configuration block is `0000h`. That is the correct state
for this machine rather than an oversight: `../CPM2.2/zcpr2` is built with
`MULTCMD=FALSE`, `INTPATH=TRUE`, `INTSTACK=TRUE` and `WHEEL=FALSE` specifically
so the CCP needs nothing outside its 2 KiB slot. There is consequently no
external path buffer, no named-directory buffer and no wheel byte for GENINS to
point at. The four tools carried need none of them and work from plain `DU:`
forms.

### Carried on A:

| | |
|---|---|
| `NSWP` | NSWEEP 2.07 — full-screen file manager: copy, erase, rename, view, tag, set attributes, across every user area. Copies with a per-file CRC check. The interactive half of the answer to PIP not working here. |
| `MCOPY` | Command-line multi-file copy with automatic verify, plus an interactive mode. `MCOPY b1:=a0:*.com` and the like. |
| `DU2` | Disk Utility II — sector-level disk editor. The classic repair tool for a damaged CP/M directory, and the only thing here that can put one back by hand. It goes through the standard BIOS jump table, so it reaches whichever drive is selected, and **it writes**. |
| `CRC` | File CRC. Directly relevant here: everything that arrives crosses the IO Controller link and the SD path, and this is how you learn whether it arrived intact instead of inferring it from whether the program runs. |

### Copying files: `MCOPY` and `NSWP`, not `PIP`

The stock DRI `PIP` (VERS 1.5) is still on A:, and it is still the documented
way to populate the card — `PIP B:=A:*.*` — but **only under the stock CCP and
BDOS**. It does not run under ZCPR2/ZSDOS, which is the configuration this
machine actually boots. The same ROM manifest builds all four CCP/BDOS
combinations, so `PIP` stays; it just is not the copy tool you reach for here.

Under ZCPR2/ZSDOS the two things on this volume that can move a file are
`MCOPY`, for a command line, and `NSWP`, for tagging a set and copying it with a
CRC check on each file. Both are period tools that predate the problem and
neither depends on anything `PIP` depends on.

Why `PIP` fails has not been run down. Two candidates are visible in the binary
and neither has been confirmed: it opens `$$$.SUB` on drive A, which here is a
read-only ROM, and it carries a `REQUIRES CP/M 2.0 OR NEWER FOR OPERATION`
abort on the BDOS version call.

### Not carried, because they cannot work on this machine

| | Needs |
|---|---|
| `PATH` `LD` `CD` `PWD` `MKDIR` | the external path buffer / named-directory buffer that `MULTCMD=FALSE`, `INTPATH=TRUE` deliberately removes |
| `WHEEL` | the wheel byte — `WHLADR=0` in ZSDOS, `WHEEL=FALSE` in ZCPR2 |
| `STARTUP` | the multiple-command-line buffer |
| `SUB` `ZEX` | `$$$.SUB` is hard-coded to drive A, which here is a read-only ROM — the same reason `SUBMIT` is absent. `ZEX` additionally recognises the CCP by the high bit on `CPRMPT`, which `zcpr2` clears on purpose for this 8-bit console |
| `DEVICE` `IOLOADER` `RECORD` | CHBIOSZ's SYSIO redirectable I/O drivers |
| `CONFIG` `TINIT` | a TVI 950 terminal |

### Not carried, because something already on the disk does the job

`CCPLOC` (`SYSID` reports the same thing from RAM, and is right about which CCP
is actually executing), `MENU` `MCHECK` (a shell, on a read-only disk), `LDIRZ`
`LRUNZ` (nothing here ships `.LBR` files), `GENINS` (see above — there is
nothing to install), `ECHO` (useful in `SUB`/`ZEX` files, which do not run here).

### Not carried, because of space

`XDIR` `ERASE` `RENAME` `PROTECT` `COMPARE` `DIFF` all work. They are out on
budget, not on function: NSWP covers erase/rename/attributes and lists sizes and
free space, CRC answers "is this the same file", and ZCPR2 has a resident `DIR`.

The ROM volume is 144 KiB in 1 KiB blocks — `DSM=143` in
`../CPM2.2/src/cbios_storage_rom.asm` — of which four blocks are the 128-entry
directory. 140 blocks of content, and that is a BIOS constant this manifest
cannot grow. The **diagnostic** profile is the real ceiling, because anything
added to the normal set is paid for twice:

| Profile | Blocks used | Free |
|---|---|---|
| `normal` | 116 / 140 | 24 |
| `diagnostic` | 132 / 140 | 8 |

Adding `XDIR` back would leave nothing on the diagnostic profile. That is why
the list is four tools and not ten.

## `src/ioc_diag_record.inc` is a mirror, not an original

The IOC failure-record layout is owned by `../CPM2.2/src/cbios_defs.inc`. This
copy is what the tools compile against, and `make` checks the two agree before
building anything.

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
