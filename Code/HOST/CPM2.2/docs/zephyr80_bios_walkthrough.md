# Zephyr-80 BIOS Walkthrough

This note documents the shape of the Zephyr-80 CP/M 2.2 BIOS under the banked
operating system. It is maintenance context for the code in `src/`. For exact
addresses use the generated `docs/memory-map.md` and `docs/symbol-map.md`; for
the design and its invariants use
`docs/Zephyr-80_OS_Execution_Memory_Architecture.md`.

## The Two Halves

The operating system — ZSDOS, the BIOS and its drivers — runs from SRAM bank 7.
Bank 7 is visible at `2000h-DFFFh` only in latch mode 11. Programs run in mode
10, where `0000h-DFFFh` is their own bank. Both modes map `E000h-FFFFh` to SRAM
bank 0, and `0000h-1FFFh` stays on the program's bank in both, so ZSDOS reads
the program's page zero directly.

Every piece of BIOS code therefore lives in one of two places:

- **Bank 7** holds everything that runs only in mode 11: ZSDOS, the console and
  storage facades and backends, the IO Controller transport, HID input, and the
  disk structures. It also holds the font and the BIOS private stacks.
- **Common memory** holds what must be visible in both modes or when an
  interrupt arrives:
  - the BDOS facade and the CP/M BIOS table
  - cold and warm boot, and the banking services
  - the SIO core and the interrupt path
  - the crossing gates, the staging buffer and the IM2 page
  - the stacks that survive a mapping change

Common memory is 8 KiB and every byte of it comes out of every program's address
space, so code goes there only when it has to.

## Source Boundaries

`src/zephyr.asm` is the one assembly. It sets `CBASE`, includes
`platform_zephyr80.inc` and `cbios_defs.inc`, assembles the two jump tables at
`CBIOS_BASE`, and includes the modules in this order:

```text
src/zephyr.asm
-> boot_shadow_copy.asm      reset copy                                common
-> cbios_bank_select.asm     low-level bank helpers                    common
-> cbios_boot.asm            cold boot, warm boot, CCP restore         common
-> cbios_console.asm         console facade                            bank 7
-> sio_core.asm              SIO0/B, SIO1, SIO interrupt body          common
-> cbios_xing.asm            xing_isr, mode-preserving bank select     common
-> vdrip_transport.asm       VDrip builds only
-> cbios_bios_ext.asm        VIDEO_SEND                                bank 7
-> cbios_iocall.asm          IOCALL                                    bank 7
-> cbios_ioc_command.asm     IOC command and bulk lanes                bank 7
-> cbios_hid_input.asm       USB keyboard input                        bank 7
-> cbios_sercon.asm          serial console fallback (direct console)  common
-> cbios_console_<backend>   v9958 or vdrip, from CONSOLE              bank 7
-> cbios_storage.asm         storage facade                            bank 7
-> cbios_storage_<backend>   rom, vdrip or ramdisk, from STORAGE_A     bank 7
-> cbios_storage_sd.asm      SD backend and drive dispatcher           bank 7
-> cbios_bank.asm            SELMEM, SETBNK, XMOVE, MOVE               common
-> cbios_gate.asm            crossing gates, warm-boot trap            common
-> cbios_irq.asm             CTC dispatch, registration, IM2 page      common
-> cbios_facade.asm          BDOS facade, Zephyr functions             common
```

ZSDOS's BIOS table is assembled at `BIOS7_BASE` at the end of `zephyr.asm`.

`src/cbios_defs.inc` is the address authority: its "Banked OS layout" block
declares the layout, and each module `.org`s at a base declared there. Some
region comments further down still describe the fixed-slot layout from before
the banked OS; the values are authoritative, the comments are not.

The build cuts the link in two with `tools/split_banked_image.py`: ROM page 0
gets the reset vector and common memory, with ZCPR2 installed at `CBASE`, and
ROM page 7 gets the bank 7 payload, with ZSDOS installed at `2000h`.
`tools/generate_memory_docs.py` then validates the result and regenerates the
two maps.

## Boot Flow

Cold boot:

```text
reset_vector (0000h, ROM page 0)
-> cpm_rom_entry_high
-> copy every ROM page into the matching SRAM bank; page 7 becomes the OS
-> BOOT
-> latch 18h: mode 11 over bank 0, then SP = bank 7 boot stack
-> reset the CTC, clear interrupt registrations, silence the PSGs
-> sio_core_init
-> bank7_check: the BANK7OS1 marker, reported over SIO0/B and halt if absent
-> sio1_ioc_init, ioc_link_bringup
-> console backend cold init, serial console init, banner
-> page zero, facade reset
-> enable SIO interrupts: I = FDh, IM2
-> SP = facade stack (common), latch 10h: mode 10 over bank 0
-> CCP clear-buffer entry with C = 0
```

Nothing in bank 7 is called before `bank7_check` passes.

Warm boot enters through the CP/M table's `WBOOT`, through page zero's
`JP WBOOT`, or through `wbtrap` when ZSDOS warm-boots:

```text
WBOOT
-> wboot_resident
-> latch 18h before any stack use, then SP = bank 7 boot stack
-> reset the CTC, clear interrupt registrations, silence the PSGs
-> sio_core_init (SIO1 is left alone: it keeps its External Sync boundary)
-> restore_ccp_from_rom: CBASE..FBASE-1 from ROM page 0 in boot mode
-> page zero, facade reset
-> console init, serial console rebind
-> enable SIO interrupts
-> SP = facade stack, latch 10h
-> CCP clear-buffer entry with C = TDRIVE
```

Bank 7 is not reloaded on warm boot.

The final switch to mode 10 moves to a common stack first. An interrupt between
the latch write and the CCP's own stack would otherwise push onto bank 0's
`C000h-DFFFh`, which is where the bank 7 stack's address points in mode 10.

## How a Program Reaches the BIOS

```text
program, mode 10
  | CALL 5
  v
BDOS facade (common)          save SP, facade stack
  | stage hidden FCB / DMA / buffers into common memory
  | latch |= SHADOW_BIT       mode 11
  v
ZSDOS (bank 7)
  | its own BIOS table at BIOS7_BASE
  v
console / storage facades and backends (bank 7)
  |
  v
facade: restore latch, copy results back, restore SP, return
```

The facade decides visibility on the whole range: an object wholly in
`0000h-1FFFh` or wholly in `E000h-FFFFh` is visible in mode 11. The build
currently forces staging for every eligible call (`FACADE_FORCE_STAGE`), except
the console buffer of function 10, which is staged only when hidden. Functions
27 and 31 return copies in common memory, because a program cannot follow a
pointer into bank 7.

Zephyr functions 200-203 are handled in common code. Functions 210-217 copy the
seven-byte register block into common memory and call the extension table:

- `MOVE`, `XMOVE`, `SELMEM` and `SETBNK` are common code and run in the caller's
  mode.
- `IOCALL`, `VIDEO_SEND`, `IOCBULK` and `IOCBULKW` go through gates. Each gate
  moves to the gate stack and stages the buffers through the 512-byte staging
  buffer. It then calls the bank 7 routine with `xing_os_call_ix` and restores
  the latch it found.

A program calling the CP/M BIOS table directly reaches the console gates, which
work the same way. The disk and auxiliary entries are inert: the disk
structures live in bank 7, and ZSDOS uses its own table.

ZSDOS never calls `RST 0`. Both of its warm-boot exits jump to `wbtrap`, which
switches to the facade stack and restores mode 10 before `JP 0000h`. A program
that replaced page zero's vector then gets its handler in the mode it expects.

## Jump Tables

The CP/M BIOS table at `CBIOS_BASE` keeps the CP/M 2.2 order. Do not reorder
it:

| Entry | Target | Contract |
|---|---|---|
| `BOOT` | `boot` | Cold boot. Does not return. |
| `WBOOT` | `wboot` | Warm boot. Does not return. |
| `CONST` | `gate_const` | `A=FFh` when console input is available, `A=00h` otherwise. |
| `CONIN` | `gate_conin` | Blocking console input, byte in `A`. |
| `CONOUT` | `gate_conout` | Blocking console output of `C`. |
| `LIST`, `PUNCH`, `HOME`, `SETTRK`, `SETSEC`, `SETDMA` | `bios_inert_ret` | No effect. |
| `READER` | `bios_inert_reader` | Returns `^Z`. |
| `SELDSK` | `bios_inert_seldsk` | Returns `HL = 0`. |
| `READ`, `WRITE` | `bios_inert_error` | Returns an error. |
| `LISTST` | `bios_inert_listst` | Not ready. |
| `SECTRAN` | `bios_inert_sectran` | Identity. |

ZCPR2 calls `CONST` and `CONIN` through this table directly, and is assembled
against its address.

`ZBIOS_EXT_BASE` follows it with eight entries, reached as BDOS functions
210-217: `MOVE`, `XMOVE`, `SELMEM`, `SETBNK`, `IOCALL`, `VIDEO_SEND`, `IOCBULK`,
`IOCBULKW`.

ZSDOS's table at `BIOS7_BASE` has the same seventeen entries. `BOOT` and
`WBOOT` point at `wbtrap`; the rest point straight at the bank 7 implementation.
The `BANK7OS1` marker follows it.

## Stacks

**Never change the latch mode while SP points at memory the change remaps.**

| Stack | Where | Used by |
|---|---|---|
| Boot | bank 7, `C000h-C0FFh` | cold boot, warm boot |
| Console and storage | bank 7, `C100h-C1FFh` | console dispatch, storage dispatch |
| Transport | bank 7, `C200h-C2FFh` | `IOCALL`, `IOCBULK`, `IOCBULKW` |
| ISR | common, `FE82h-FEBFh` | SIO and CTC interrupts, registered callbacks |
| Gate | common, `FEC0h-FEFFh` | program calls through the gates |
| Facade | common, `FF00h-FF5Fh` | the BDOS facade, `wbtrap`, the final boot switch |

ZSDOS has its own stack, grown by 192 bytes in place.

None of these is measured on this layout.

Every interrupt entry saves the interrupted SP at `FE80h` and switches to the ISR
stack before pushing anything, so only the return address lands on the
interrupted stack.

Shadow/copy mode forces `C000h-FFFFh` to bank 0. The drive A: ROM-disk read runs
in that mode with the storage stack's address in bank 7's `C000h-DFFFh`, so
`xing_rom_copy_record` keeps its saved latch and interrupt state in common
variables and does no stack operation inside the window.

## Interrupts

The BIOS owns IM2. `sio_core_enable_interrupts` loads `I` with `FDh`, and the
vector page at `FD00h`, in `cbios_irq.asm`, is a full 256 entries:

```text
00h-06h   ctc0_isr .. ctc3_isr     CTC channels 0-3
10h-1Eh   xing_isr                 SIO0 (10h is live)
others    irq_unexpected           EI, RETI
```

`ctc_disable_interrupts` programs the CTC vector base `00h`, and the SIO core
programs SIO0/B WR2 with `10h`.

The SIO path:

```text
xing_isr: save SP, ISR stack
-> sio_core_isr
-> read byte, A = channel, C = byte
-> registered receive sink
-> restore SP, EI, RETI
```

The receive-sink convention is `A` = logical SIO channel and `C` = received
byte; the sink may clobber `AF`, `BC`, `DE` and `HL`. `sio_rx_kick` reaches the
same sink from foreground code.

The CTC path:

```text
ctcN_isr: save SP, ISR stack, push AF
-> ctc_isr_dispatch: push BC DE HL
-> slot empty: reset the channel
-> slot set: CALL the program's callback in E000h-E3FFh
-> pop, restore SP, EI, RETI
```

`irq_register` (function 200) accepts a callback only for channels 0-3, only in
`E000h-E3FFh`, and only for an empty slot. `irq_unregister` (201) resets the
channel and clears the slot. `irq_program_exit` (202), which ZCPR2 calls when a
transient returns, and `irq_reset`, called at cold and warm boot, clear them
all.

Every handler here lives in common memory, because an interrupt can arrive in
either mode. Handlers end with `EI` / `RETI`; callbacks end with `RET`.

## Console Architecture

`src/cbios_console.asm` dispatches the CP/M console entries through the active
driver table, whose seven entries are `const`, `conin`, `conout`, `list`,
`punch`, `reader` and `listst`. The backend runs on the console stack. The
build links one backend (`CONSOLE`):

- **`v9958`** (default) drives the LunchCrema V9958 directly. Input comes only
  from the IO Controller keyboard queue: `CONST` samples the `/CTSB` doorbell and
  issues `CMD_HID_INPUT` only when it is asserted. `CONOUT` parses
  ANSI/VT100-light output and renders through the V9958 command engine.
- **`vdrip`** is the retained Virtual Drip console. Input arrives on SIO0/B
  interrupts into a raw-byte queue; output is framed VDP/control packets. Normal
  traffic waits for the packetized `PROXY_READY` handshake.

Keyboard input never draws characters inside the driver. Programs that echo
input call `CONIN` and then `CONOUT`.

The serial console fallback (`cbios_sercon.asm`, direct-console builds) tees
`CONOUT` to SIO0/B once armed, and three ESCs on the serial port switch input
between the keyboard and the serial port. Its flags byte is found through BDOS
function 203.

## SIO Core

`src/sio_core.asm` owns the BIOS hardware boundary for the Z80 SIOs:

| Logical channel | Hardware | Purpose |
|---|---|---|
| `SIO_CH_CONSOLE` | SIO0/B | Console serial link: VDrip, or the serial console fallback. |
| `SIO_CH_IOCTRL` | SIO1 | Synchronous IO Controller link. |

SIO0/B is asynchronous 115200 8N1. SIO0/B WR1 keeps status-affects-vector
disabled, so the SIO emits exactly vector `10h`. SIO1 runs in synchronous mode
with external clock and sync from the IO Controller and no SIO1 interrupts.
`sio_core_init` runs at every boot; `sio1_ioc_init` runs only at cold boot, so a
warm boot does not destroy SIO1's persistent External Sync boundary.

## Storage Architecture

`src/cbios_storage.asm` owns the CP/M storage entries in bank 7. Each is a jump
into the dispatcher in `cbios_storage_sd.asm`, which routes on the drive
`SELDSK` last selected and runs the backend on the storage stack:

| Drive | Backend |
|---|---|
| A: | build-selected (`STORAGE_A`): `rom` (default), `vdrip` or `ramdisk` |
| B: | SD unit 0, through the IO Controller record cache |
| C: | SD unit 1, when the controller reports it mounted |

Every other drive returns no DPH.

Storage flow:

```text
ZSDOS, mode 11
-> SELDSK: dispatcher; B:/C: probe the card first
-> SETTRK / SETSEC / SETDMA
-> READ or WRITE: backend on the storage stack
-> ROM A: one LDIR in shadow/copy mode (xing_rom_copy_record)
   SD B:/C: CMD_SD_READ_REC / CMD_SD_WRITE_REC, 128 bytes on the bulk lane
-> return CP/M BIOS status in A
```

The DMA is ZSDOS's view of it. For a program's staged call that is the facade's
staging buffer in common memory; for a DMA in the caller window it is the
program's own memory. The ROM-disk read writes a DMA below `2000h` into the
program's bank, and one in `2000h-BFFFh` into bank 7. A DMA in `C000h-DFFFh` is
refused, because shadow/copy mode maps that range to bank 0.

The drive A: ROM volume is read only: `stg_a_write` returns an error. The SD
backend uses `MOVE_BUFFER`, in bank 7's runtime range, as transaction scratch.

## Maintenance Notes

After BIOS, driver, layout or generator changes:

```sh
make
```

`make` fails if the layout breaks a validated rule. Then inspect:

```text
docs/memory-map.md       regions, free space, validation report
docs/symbol-map.md       jump tables, IM2 page, symbols
build/layout-report.md
```

Keep these invariants intact:

- Do not reorder the CP/M BIOS jump table or ZSDOS's BIOS table.
- Never change the latch mode while executing from, or with SP in, a range the
  change remaps. Restore the mode bits you found; never assume mode 10.
- Bank 7 code never calls `CALL 5` or a common jump-table entry, and interrupt
  handlers never call BDOS: the facade and the gates are not reentrant.
- Everything an interrupt can reach lives in common memory.
- Keep the bank 7 image below `C000h`, and put only zero-initialized runtime
  state in `C000h-DFFFh`.
- Never use `E000h-E3FFh`: it belongs to the running program.
- No `RST` in bank 7 code.
- A pointer returned to a program never points into bank 7.
- Do not interpret keyboard input inside the output parser.
- Do not change Virtual Drip packet type values without updating both BIOS and
  proxy.
