# Zephyr-80 BIOS Walkthrough

This note documents the current Zephyr-80 CP/M 2.2 BIOS shape. It is intended
as maintenance context for the local BIOS code in `src/`, not as a replacement
for the generated address report in `docs/memory-map.md`.

## Source Boundaries

The project keeps the stock CP/M 2.2 source under `cpm-2.2/` and layers local
Zephyr-80 runtime code under `src/`.

Current top-level assembly entry:

```text
src/zephyr.asm
-> cpm-2.2/src/cpm22.asm
-> boot_shadow_copy.asm
-> cbios_bank_select.asm
-> cbios_boot.asm
-> cbios_console.asm
-> sio_core.asm
-> cbios_iocall.asm
-> cbios_console_vdrip.asm
-> cbios_storage.asm
-> cbios_storage_vdrip.asm
-> cbios_bank.asm
```

`src/cbios_defs.inc` is the address and geometry authority for the BIOS side.
`tools/generate_memory_docs.py` validates the assembled image and regenerates
`docs/memory-map.md` and `docs/symbol-map.md`.

`src/cbios_storage_ramdisk.asm` preserves the old banked RAM disk backend as
inactive source. It is not linked by the active VDrip build.

## Boot Flow

Cold boot enters through the ROM reset vector at `0000h`, then through the ROM
shadow-copy path before reaching `BOOT`.

Current cold boot sequence:

```text
reset_vector
-> cpm_rom_entry_high
-> ROM image copied into RAM
-> BOOT
-> select RAM bank 0
-> disable CTC interrupts
-> initialize BIOS-owned SIO core
-> initialize active console backend
-> print CP/M banner
-> install CP/M page-zero vectors
-> record and clear default DMA at 0080h
-> enable SIO interrupts
-> enter CCP clear-buffer entry with C = 0
```

Warm boot enters through the BIOS jump-table `WBOOT` entry or the page-zero
`JP WBOOT` vector at `0000h`.

Current warm boot sequence:

```text
WBOOT
-> wboot_resident
-> select RAM bank 0 without using stack or CALL
-> install protected BIOS stack
-> disable CTC interrupts
-> initialize BIOS-owned SIO core
-> initialize active console backend
-> restore CCP range from ROM
-> reinstall page-zero vectors and default DMA
-> enable SIO interrupts
-> enter CCP clear-buffer entry with C = TDRIVE
```

Storage is not required before the proxy is ready enough to run the console
handshake. CP/M disk access begins only after the CCP/BDOS path asks the BIOS
storage facade to select and read drive A.

## CP/M Page Zero

The BIOS installs the standard CP/M vectors in the active runnable bank:

```text
0000h: JP WBOOT
0005h: JP FBASE
0080h: default DMA buffer / command tail
```

`DEFAULT_DMA` is recorded in `cbios_dma_addr`, and `DMA_BANK` is initialized to
the current bank. The command-tail/default-DMA region is cleared during boot and
warm boot.

## BIOS Jump Table

The CP/M-visible BIOS jump table starts at `CBIOS_BASE` (`DA00h` in the current
build). Do not reorder it.

Standard CP/M entries:

| Entry | Contract |
|---|---|
| `BOOT` | Cold boot. Does not return. |
| `WBOOT` | Warm boot. Does not return. |
| `CONST` | Return `A=FFh` when console input is available, `A=00h` otherwise. |
| `CONIN` | Blocking console input. Return byte in `A`. |
| `CONOUT` | Blocking console output. Byte is passed in `C` by CP/M facade code. |
| `LIST` | Auxiliary list output stub/backend entry. |
| `PUNCH` | Auxiliary punch output stub/backend entry. |
| `READER` | Auxiliary reader input stub/backend entry. |
| `HOME` | Select track zero for active disk backend. |
| `SELDSK` | Select disk in `C`; return DPH in `HL` or `0000h`. |
| `SETTRK` | Record track in `BC`. |
| `SETSEC` | Record sector in `BC`. |
| `SETDMA` | Record DMA address in `BC`. |
| `READ` | Read one 128-byte record to DMA. Return `A=0` on success. |
| `WRITE` | Write one 128-byte record from DMA. Return `A=0` on success. |
| `LISTST` | Return list-device status. |
| `SECTRAN` | Translate logical sector. Current VDrip disk is identity-mapped. |

`ZBIOS_EXT_BASE` follows the CP/M 2.2 entries and is Zephyr-specific:

| Entry | Contract |
|---|---|
| `MOVE` | Copy bytes, using pending `XMOVE` bank selection when present. |
| `XMOVE` | Select source/destination banks for the next `MOVE`. |
| `SELMEM` | Select the current execution bank. |
| `SETBNK` | Select the bank used by disk DMA. |
| `LAUNCH` | Restore and enter an application bank. |
| `IOCALL` | Run a BIOS-owned SIO1 IO Controller transaction. |

## Memory Layout

The generated memory map is the authority for exact addresses. Current major
regions:

| Range | Owner |
|---|---|
| `0100h-BFFFh` | Banked transient program area. |
| `C000h-C3FFh` | Protected/common TPA, application-owned. |
| `C400h-D9FFh` | CCP/BDOS region in the current MEM=56 build. |
| `DA00h-DFFFh` | Core BIOS: jump table, boot, facades, banking, SIO, IOCALL. |
| `E000h-FA7Fh` | Fixed driver/code slots. |
| `FA80h-FDFFh` | BIOS scratch and CP/M storage buffers. |
| `FE00h-FE7Fh` | Persistent BIOS runtime state. |
| `FE80h-FFFFh` | BIOS stack/reserve. |

Driver slots are fixed allocation regions. Current slot ownership:

| Slot | Range | Current owner |
|---:|---|---|
| 0 | `E000h-E3FFh` | Virtual Drip console |
| 1 | `E400h-E7FFh` | Virtual Drip console |
| 2 | `E800h-EBFFh` | Virtual Drip console |
| 3 | `EC00h-EFFFh` | Virtual Drip console |
| 4 | `F000h-F3FFh` | Virtual Drip console |
| 5 | `F680h-FA7Fh` | Virtual Drip console tail and VDrip storage backend |

Persistent runtime state is split by owner in the `FE00h` window:

```text
CBIOS_WORK_AREA
CBIOS_CONSOLE_WORK_AREA
CBIOS_BANK_WORK_AREA
CBIOS_STORAGE_WORK_AREA
CBIOS_SIO_CORE_WORK_AREA
```

`MOVE_BUFFER` is scratch. The VDrip storage DPH/DPB, directory buffer, and ALV
live in declared scratch/storage-buffer addresses and must not overlap packet
scratch or resident code.

## Console Architecture

The CP/M console facade in `src/cbios_console.asm` dispatches through the active
console driver table. In the current build that table comes from
`src/cbios_console_vdrip.asm`.

Input and output are intentionally separate.

Input flow:

```text
SIO0/B RX interrupt or foreground kick
-> sio_core_dispatch_rx
-> vdrip_rx_sink
-> raw terminal byte enqueue into textq
-> CONST checks textq_count
-> CONIN dequeues oldest byte
```

Output flow:

```text
CP/M CONOUT byte
-> vdrip_console_conout
-> ANSI/VT100-light parser
-> text shadow buffer and cursor state
-> framed Virtual Drip VDP/control packets
-> proxy renderer
```

Keyboard input bytes do not draw characters inside the driver. Programs that
echo input do so by calling `CONIN` and then `CONOUT`.

The startup handshake is a packetized proxy readiness frame:

```text
A5 5A 01 00 0A
```

This is a zero-payload `PROXY_READY`. Normal VDP traffic is held until the
common transport parser completes the handshake.

## SIO Core

`src/sio_core.asm` owns the BIOS hardware boundary for Z80 SIO devices.

Current BIOS-owned channels:

| Logical channel | Hardware | Purpose |
|---|---|---|
| `SIO_CH_CONSOLE` | SIO0/B | VDrip console and storage serial link. |
| `SIO_CH_IOCTRL` | SIO1/A | Synchronous IO Controller transaction link. |

SIO0/B is asynchronous 115200 8N1 with CTS-polled transmit and
software-managed RTS. DTR/DCD are not required, and Auto Enables are kept off.

The SIO RX sink convention is:

```text
Input:  A = logical SIO channel
        C = received byte
May clobber: AF, BC, DE, HL
```

The interrupt path and foreground kick path converge at the same registered
sink:

```text
sio_core_isr or sio_rx_kick
-> read received byte
-> A = channel, C = byte
-> sio_core_dispatch_rx
-> registered sink
```

The current IM2 setup uses one exact two-byte vector entry in the SIO core:

```text
I register     = DDh
SIO0/B WR2     = 10h
CPU reads word = DD10h/DD11h
target         = sio_core_isr
```

SIO0/B WR1 status-affects-vector remains disabled, so the vector byte is exact.

## Storage Architecture

`src/cbios_storage.asm` owns the CP/M storage facade. It routes drive A to
`src/cbios_storage_vdrip.asm` and returns deterministic no-device behavior for
other drives.

Storage flow:

```text
BDOS
-> SELDSK drive A
-> SETTRK / SETSEC / SETDMA / SETBNK
-> READ or WRITE
-> storage facade switches to BIOS-owned stack
-> VDrip storage backend computes LBA
-> framed storage transaction over SIO0/B
-> DMA copy from/to requested bank
-> return CP/M BIOS status in A
```

The VDrip storage backend temporarily registers its own SIO RX sink during a
storage transaction, then restores the normal console raw-input sink. It saves
and restores the console RTS state around the transaction.

Only drive A (`drive=0`) is supported. Other CP/M drive numbers return no DPH
from `SELDSK`.

## Maintenance Notes

Use these checks after BIOS, driver, memory layout, or documentation-generator
changes:

```sh
make
```

Then inspect:

```text
docs/memory-map.md
docs/symbol-map.md
build/layout-report.md
build/layout.manifest
```

Keep these invariants intact:

- Do not reorder the CP/M BIOS jump table.
- Do not use `C000h-C3FFh` as BIOS scratch.
- Do not let storage scratch overlap the VDrip storage DPH/DPB.
- Do not let driver code grow past its declared slot/range.
- Do not interpret keyboard input inside the output parser.
- Do not reintroduce fixed startup delays in place of the readiness handshake.
- Do not change Virtual Drip packet type values without updating both BIOS and
  proxy.
- Do not treat the inactive banked RAM disk backend as the active drive A
  implementation unless the build is intentionally changed to link it.
