# Zephyr-80 CP/M 2.2

Zephyr-80 is a Z80-based CP/M 2.2 machine and firmware target. This repository
builds a CP/M 2.2 firmware image with a local Zephyr-80 CBIOS, banked RAM
support, a VDrip-backed CP/M drive, and a driver-facing layout for console
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
- Drive A is backed by a VDrip proxy flat image using the standard CP/M BIOS
  disk call model.
- A BIOS-owned SIO core exists in core BIOS for SIO0/B and SIO1/A plumbing.
- The Virtual Drip console backend is a client of the SIO core.
- SIO0/B receive uses maskable interrupts and a console RX sink/buffer.
- SIO0/B transmit checks CTS, and SIO0/B RTS is exposed for software-managed
  RX backpressure by the console client.
- SIO1/A is initialized as a BIOS-owned synchronous IO Controller link.
- `IOCALL` is exposed as a Zephyr extended BIOS call for simple IO Controller
  command/reply transactions.
- `CONST` checks buffered input, and `CONIN` consumes from the buffer.
- `CONOUT` remains a blocking/polled transmit path.
- The old NMI/debug path has been removed.
- Banking, `XMOVE`, `MOVE`, `SELMEM`, `SETBNK`, and `LAUNCH` are core BIOS
  services.

Planned later:

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
  - driver slots occupy `E000h-FA7Fh`
  - scratch, runtime state, and stack live above the driver slots

Warm boot restores the CCP range from ROM page 0 before returning to the CCP
warm-entry path. BDOS and BIOS are left intact.

## Memory Map

The current fixed-slot layout is declared in `src/cbios_defs.inc` and reproduced
by `tools/generate_memory_docs.py`. The generated `docs/memory-map.md` is the
address authority after each build.

Major regions:

| Range | Owner |
|---|---|
| `0100h-BFFFh` | Banked transient program area |
| `C000h-C3FFh` | Protected/common TPA, application-owned |
| `C400h-D9FFh` | CCP/BDOS in the current MEM=56 build |
| `DA00h-DFFFh` | Core BIOS |
| `E000h-FA7Fh` | Fixed driver/code slots |
| `FA80h-FDFFh` | BIOS scratch and CP/M storage buffers |
| `FE00h-FE7Fh` | Persistent BIOS runtime state |
| `FE80h-FFFFh` | BIOS stack/reserve |

Hand-written walkthroughs:

- `docs/zephyr80_bios_walkthrough.md`
- `docs/vdrip_protocol.md`
- `docs/zephyr80_vdrip_disk.md`

## Driver Model

The BIOS presents stable CP/M entry points and dispatches through facades:

- `src/cbios_console.asm` owns the console facade.
- `src/cbios_storage.asm` owns the storage facade.
- `src/sio_core.asm` owns BIOS SIO hardware plumbing.
- Driver backends provide tables or entry points behind those facades.

Current transitional allocation:

| Slot | Range | Current owner |
|---:|---:|---|
| 0-4 | `E000h-F3FFh` | Virtual Drip console driver |
| 5 | `F680h-FA7Fh` | Virtual Drip console tail and VDrip storage backend |

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
- The Virtual Drip console sink stores raw terminal input bytes in `textq`.
- `CONST` checks `textq`.
- `CONIN` blocks until a buffered byte is available, then consumes it.
- `CONOUT` emits framed VDrip display/control packets and keeps input and
  output paths separate.
- SIO0/B RTS is software-managed by the Virtual Drip console owner.
- During SIO core init, RTS is held released and stale SIO0/B RX bytes are
  discarded before the console sink is registered.
- DTR/DCD are not required, and WR3 Auto Enables remain off to avoid depending
  on DCD.

The current IM2 setup is SIO-only and uses an exact two-byte table entry:

- `I = DDh`
- SIO0/B WR2 vector byte is `10h`
- the IM2 table entry lives at `DD10h-DD11h`, inside the SIO core
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

`IOCALL` lives at `ZBIOS_EXT_BASE + 0Fh`; its transport code is part of core
BIOS, not a driver slot occupant. The caller passes `DE` pointing to a
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
images/     payload and disk-format inputs
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
- Virtual Drip work should clearly distinguish proxy-visible packet protocol
  changes from common core BIOS behavior.
