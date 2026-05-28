# Zephyr-80 CP/M 2.2

Zephyr-80 is a Z80-based CP/M 2.2 machine and firmware target. This repository
builds a CP/M 2.2 firmware image with a local Zephyr-80 CBIOS, banked RAM
support, a RAM-disk-backed CP/M drive, and a driver-facing layout for console
and storage backends.

The project is part of the broader pBITz / coffee-machine retro-computing
family. It is hobby and experimental firmware, but the code tries to keep the
low-level contracts explicit: memory ownership is declared in one place,
generated documentation is checked against the build, and BIOS symbols are
treated as ABI, not casual implementation details.

## Current Status

Implemented now:

- CP/M 2.2 boots on the Zephyr-80 firmware target.
- The CBIOS uses a cleaned-up fixed memory map with a core BIOS area and six
  fixed 1 KiB driver slots.
- Drive A is backed by a RAM disk stored across RAM banks 2-7.
- A BIOS-owned SIO core exists in core BIOS for SIO0/B and SIO1/A plumbing.
- The legacy SIO console backend is now a client of the SIO core.
- SIO0/B receive uses maskable interrupts and a console RX sink/buffer.
- SIO1/A is initialized as a BIOS-owned synchronous IO Controller link.
- `IOCALL` is exposed as a Zephyr extended BIOS call for simple IO Controller
  command/reply transactions.
- `CONST` checks buffered input, and `CONIN` consumes from the buffer.
- `CONOUT` remains a blocking/polled transmit path.
- The old NMI/debug path has been removed.
- Banking, `XMOVE`, `MOVE`, `SELMEM`, `SETBNK`, and `LAUNCH` are core BIOS
  services.

Planned later:

- A Virtual Drip console/storage driver is planned, but not implemented in this
  build.
- Real video-card interrupt handling may need a different IM2 ownership model
  or table layout.
- Additional drivers may occupy one or more whole fixed slots.

## Architecture Summary

The firmware keeps stock CP/M source under `cpm-2.2/` and adds local Zephyr-80
runtime code under `src/`. The top-level runtime wrapper assembles CP/M, installs
the BIOS jump table at `DA00h`, and includes the local CBIOS modules.

Important runtime areas:

- Page zero:
  - `0000h`: `JP WBOOT`
  - `0005h`: `JP FBASE`, the CP/M BDOS entry
  - `0080h`: default DMA buffer / command tail
- Banked TPA:
  - `0100h-BFFFh`, switched by the RAM bank latch
- Protected/common TPA:
  - `C000h-C3FFh`, common across banks and application-owned
  - this is not BIOS scratch space
- CCP/BDOS:
  - CCP begins at `C400h`
  - BDOS entry is currently `CC06h`
- CBIOS:
  - BIOS jump table begins at `DA00h`
  - core BIOS occupies `DA00h-DFFFh`
  - driver slots occupy `E000h-F7FFh`
  - scratch, runtime state, and stack live above the driver slots

Warm boot restores the CCP range from ROM page 0 before returning to the CCP
warm-entry path. BDOS and BIOS are left intact.

## Memory Map

The current fixed-slot layout is declared in `src/cbios_defs.inc` and reproduced
by `tools/generate_memory_docs.py`.

```text
FFFFh +----------------------------------------------+
      | BIOS stack / reserve                         |
FFF0h |   CBIOS_STACK_TOP                            |
      |   stack grows downward                       |
FB00h +----------------------------------------------+
FAFFh | Runtime state end                            |
FA00h | Runtime state start                          |
      |   CURRENT_BANK / DMA / XMOVE                 |
      |   storage state                              |
      |   SIO core state                             |
      |   console driver state                       |
      +----------------------------------------------+
F9FFh | Scratch / staging end                        |
F980h |   free scratch window                        |
F900h |   RAMDISK_DIRBUF                             |
F800h |   MOVE_BUFFER                                |
      +----------------------------------------------+
F5FFh | Driver slot 5 end                            |
F400h | Driver slot 5 start                          |
      |                                              |
F3FFh | Driver slot 4 end                            |
F000h | Driver slot 4 start                          |
      |                                              |
EFFFh | Driver slot 3 end                            |
EC00h | Driver slot 3 start                          |
      |                                              |
EBFFh | Driver slot 2 end                            |
E800h | Driver slot 2 start: IO Controller transport  |
      |                                              |
E7FFh | Driver slot 1 end                            |
E400h | Driver slot 1 start: legacy SIO console      |
      |                                              |
E3FFh | Driver slot 0 end                            |
E000h | Driver slot 0 start: RAM disk backend        |
      +----------------------------------------------+
DFFFh | Core BIOS end                                |
DD90h |   SIO core + exact IM2 vector entry          |
DC80h |   banking / XMOVE / LAUNCH                   |
DC00h |   storage facade                             |
DB80h |   console facade                             |
DA00h | CBIOS_BASE / jump table / boot / WBOOT       |
      +----------------------------------------------+
D9FFh | CP/M BDOS/state end                          |
CC06h | FBASE / BDOS entry                           |
C400h | CCP base                                     |
C000h | protected/common TPA, application-owned       |
      +----------------------------------------------+
BFFFh | banked TPA end                               |
0100h | transient program area                       |
0080h | default DMA / command tail                   |
0005h | JP FBASE                                     |
0000h | JP WBOOT                                     |
      +----------------------------------------------+
```

## Driver Model

The BIOS presents stable CP/M entry points and dispatches through facades:

- `src/cbios_console.asm` owns the console facade.
- `src/cbios_storage.asm` owns the storage facade.
- `src/sio_core.asm` owns BIOS SIO hardware plumbing.
- Driver backends provide tables or entry points behind those facades.

Current transitional allocation:

| Slot | Range | Current owner |
|---:|---:|---|
| 0 | `E000h-E3FFh` | RAM disk backend |
| 1 | `E400h-E7FFh` | legacy SIO console client |
| 2 | `E800h-EBFFh` | IO Controller transport |
| 3-5 | `EC00h-F7FFh` | available |

At a high level, adding a driver means:

1. Choose one or more whole driver slots.
2. Define start and end symbols for the driver's resident code.
3. Provide the facade-facing driver table or entry points.
4. Keep persistent state in the runtime state area or another declared,
   validated state block.
5. Use scratch only for temporary buffers.
6. Update validation expectations in the documentation generator.
7. Regenerate the memory documentation.

Fixed slots are intentional. They make driver growth and movement explicit
instead of letting later drivers slide upward unpredictably.

## Interrupt Model

The SIO core uses SIO0/B with Z80 maskable interrupts for the current console
transport:

- Boot and warm boot initialize BIOS-owned SIO services, install runtime state,
  register the console RX sink, and then enable the SIO interrupt path.
- SIO RX interrupts dispatch received bytes to the registered console sink.
- The legacy console sink stores received bytes in its foreground-safe terminal
  RX buffer.
- `CONST` checks the console RX buffer.
- `CONIN` blocks until a buffered byte is available, then consumes it.
- `CONOUT` calls the SIO core send-byte API, which remains blocking/polled for
  now.

The current IM2 setup is SIO-only and uses an exact two-byte table entry:

- `I = DDh`
- SIO0/B WR2 vector byte is `90h`
- the IM2 table entry lives at `DD90h-DD91h`, inside the SIO core
- the table word points directly at `sio_core_isr`

SIO0/B WR1 keeps status-affects-vector disabled, so the SIO emits the exact
WR2 vector byte and the BIOS no longer needs a 256-byte repeated IM2 table.
Future devices that use IM2 should allocate explicit table entries and program
their vector bytes directly.

SIO1/A is initialized separately for the BIOS-owned IO Controller link:

- synchronous mode, 8-bit RX/TX
- external clock and external sync from the IO Controller MCU
- no parity, no CRC, no SIO1 interrupts
- RTS starts inactive and is asserted only around an `IOCALL` transaction

`IOCALL` lives at `ZBIOS_EXT_BASE + 0Fh`. The caller passes `DE` pointing to a
caller-owned request block in currently visible application memory; the BIOS
reads TX bytes from the caller's TX pointer and writes reply bytes to the
caller's RX pointer.

## Build

The default build target creates the firmware image and regenerates the memory
documentation:

```sh
make
```

Primary generated artifacts:

| Artifact | Meaning |
|---|---|
| `build/firmware.bin` | 64 KiB firmware image before payload attachment |
| `build/zephyr80.pre-swap.bin` | logical ROM image after firmware and payload assembly |
| `build/zephyr80.bin` | final burnable bit-swapped image |
| `docs/memory-map.md` | generated memory map and validation report |
| `docs/symbol-map.md` | generated stable project-facing symbol map |

The memory documentation is generated by:

```sh
python3 tools/generate_memory_docs.py \
  --listing build/firmware.lst \
  --map build/firmware.map \
  --manifest build/layout.manifest \
  --firmware-bin build/firmware.bin \
  --pre-swap-image build/zephyr80.pre-swap.bin \
  --final-image build/zephyr80.bin \
  --symbol-map docs/symbol-map.md \
  --memory-map docs/memory-map.md
```

## Repository Layout

```text
src/        Zephyr-80 CBIOS and platform-specific runtime source
cpm-2.2/    CP/M 2.2 source and reference material
tools/      image-building, conversion, bit-swap, and documentation tools
images/     payload and disk-image inputs
docs/       generated and hand-written project documentation
build/      generated build outputs
```

## Development Notes

- Treat exported BIOS symbols and memory constants as firmware ABI.
- Prefer explicit layout declarations over implicit placement.
- Keep `src/cbios_defs.inc`, validation logic, and generated docs in sync.
- Do not casually move code between core BIOS and driver slots.
- Banking, `XMOVE`, `MOVE`, `SELMEM`, `SETBNK`, and `LAUNCH` are core BIOS
  services, not drivers.
- `C000h-C3FFh` is protected/common TPA and remains application-owned. It must
  not be used as BIOS scratch, runtime state, or interrupt/vector storage.
- Future Virtual Drip work should clearly distinguish what replaces the legacy
  SIO/RAM-disk paths from what remains common core BIOS behavior.
