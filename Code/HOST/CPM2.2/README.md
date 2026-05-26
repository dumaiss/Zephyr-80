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
- A legacy SIO console backend exists in driver slot 1.
- SIO console receive now uses maskable interrupts and a BIOS RX buffer.
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
  - core BIOS occupies `DA00h-DDFFh`
  - driver slots occupy `DE00h-F5FFh`
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
FA00h +----------------------------------------------+
F9FFh | Runtime state end                            |
F900h | Runtime state start                          |
      |   CURRENT_BANK / DMA / XMOVE                 |
      |   storage state                              |
      |   console driver state                       |
      +----------------------------------------------+
F7FFh | Scratch / staging end                        |
F780h |   free scratch window                        |
F700h |   RAMDISK_DIRBUF                             |
F680h |   free scratch window                        |
F600h |   MOVE_BUFFER                                |
      +----------------------------------------------+
F5FFh | Driver slot 5 end                            |
F200h | Driver slot 5 start                          |
      |                                              |
F1FFh | Driver slot 4 end                            |
EE00h | Driver slot 4 start                          |
      |                                              |
EDFFh | Driver slot 3 end                            |
EA00h | Driver slot 3 start                          |
      |                                              |
E9FFh | Driver slot 2 end                            |
E600h | Driver slot 2 start                          |
      |                                              |
E5FFh | Driver slot 1 end                            |
E500h |   SIO IM2 repeated-byte table, 256 bytes     |
E4E4h |   SIO IM2 trampoline: JP sio_console_isr     |
E200h | Driver slot 1 start: legacy SIO console      |
      |                                              |
E1FFh | Driver slot 0 end                            |
DE00h | Driver slot 0 start: RAM disk backend        |
      +----------------------------------------------+
DDFFh | Core BIOS end                                |
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
- `src/cbios_storage_stub.asm` owns the storage facade.
- Driver backends provide tables or entry points behind those facades.

Current transitional allocation:

| Slot | Range | Current owner |
|---:|---:|---|
| 0 | `DE00h-E1FFh` | RAM disk backend |
| 1 | `E200h-E5FFh` | legacy SIO console backend, including IM2 trampoline/table |
| 2-5 | `E600h-F5FFh` | available |

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

The current console backend uses SIO channel B with Z80 maskable interrupts:

- Boot and warm boot initialize the SIO, install runtime state, and then enable
  the console interrupt path.
- SIO RX interrupts store received bytes into a foreground-safe BIOS ring
  buffer.
- `CONST` checks the BIOS RX buffer.
- `CONIN` blocks until a buffered byte is available, then consumes it.
- `CONOUT` still performs blocking/polled transmit for now.

The current IM2 setup is transitional and SIO-only:

- `I = E5h`
- SIO WR2 vector byte is `00h`
- the IM2 table lives at `E500h-E5FFh`
- table bytes are `E4h`, so the CPU vectors to `E4E4h`
- `E4E4h` contains `JP sio_console_isr`

Because this build only uses the SIO interrupt source, the table is a compact
256-byte repeated-byte table inside slot 1. A future real video-card driver or
other interrupting hardware may need global IM2 ownership or a 257-byte FF-safe
table.

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
