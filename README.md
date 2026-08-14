# Zephyr-80

**Retro Soul, Modern Flow**

Zephyr-80 is a modular homebrew Z80 computer built from real retro-style
components and modern support hardware. It runs CP/M 2.2, provides 512 KiB each
of banked SRAM and ROM, and uses expansion cards for video, sound, and peripheral
control.

It is the Z80 member of the broader pBITz / coffee-machine family of homebrew
computers.

The project combines a conventional Z80 bus with a protected common-memory
region, a driver-oriented BIOS, programmable serial and timer hardware, and an
MCU-based I/O Controller for storage and human-interface devices. The same
firmware is also used by the project's MAME implementation.

Zephyr-80 is an active hobby project and a hardware/software development
platform, not a finished consumer product. Some subsystems are working on the
physical machine, while others remain under bring-up or development.

## Current status

| Subsystem | Status |
| --- | --- |
| Z80 CPU board and memory banking | Working on physical hardware |
| ROM-to-RAM boot transition | Working |
| CP/M 2.2 and Zephyr CBIOS | Working |
| SIO serial console at 115200 baud | Working |
| Virtual Drip V9958 console | Working development backend |
| Virtual Drip 8 MiB CP/M disk | Working development backend |
| MAME machine and V9958 video | Boots the Zephyr firmware; active development |
| ColecoVision compatibility mode | Target architecture defined; launcher, memory mapping, and system integration in development |
| IOCALL fixed-frame transport | Implemented in the BIOS and MCU firmware; hardware integration in progress |
| Percolator Lunch Crema V9958 card | Hardware and firmware bring-up |
| SD-card and USB HID services through the I/O Controller | In progress |
| Percolator Afternoon Blend four-chip SN76489 card | Hardware subsystem; software integration in progress |

## Hardware architecture

### Processor and memory

- Z80-family CPU, with a current hardware target of 10 MHz
- 512 KiB SRAM arranged as eight 64 KiB physical banks
- 512 KiB ROM arranged as eight 64 KiB pages
- ATF22V10-based memory and I/O decoding
- Memory-control latch at I/O port `00h`
- 48 KiB banked application region plus a protected 16 KiB common region in
  the normal RAM-only runtime configuration

At reset, ROM is visible and writes are directed to SRAM underneath it. The
firmware copies the ROM image into RAM, disables ROM, and continues from RAM.
The common region at `C000h-FFFFh` remains mapped to SRAM bank 0 while the lower
48 KiB selects one of the eight RAM banks.

See [Memory Management.md](Memory%20Management.md) for the decoder equations,
memory modes, banking-latch format, and I/O map.

### Serial and timer hardware

The system uses two Z80 SIO devices and a Z80 CTC. The BIOS currently owns:

- SIO0/B for the 115200-baud console and Virtual Drip transport
- SIO1/B for the synchronous I/O Controller command channel
- an explicit Z80 IM2 vector entry for the interrupt-driven console receive path

The I/O Controller supplies the external clock and synchronization signals for
its synchronous SIO link. The initial IOCALL implementation is deliberately
simple and uses a polled, fixed-size transaction.

### Expansion bus

The latest Zephyr-80 respin uses DIN connectors for the pBITz expansion bus.
The shared backplane, bus, and mezzanine-card designs are maintained separately
in the [pBITzPlatform repository](https://github.com/dumaiss/pBITzPlatform).

## Memory model

The memory hardware provides three useful operating modes:

| Mode | Read behavior |
| --- | --- |
| Normal ROM mode | ROM at `0000h-5FFFh` and `C000h-FFFFh`; SRAM at `6000h-BFFFh` |
| Shadow/copy mode | ROM at `0000h-BFFFh`; common SRAM bank 0 at `C000h-FFFFh` |
| RAM-only mode | Selected SRAM bank at `0000h-BFFFh`; common SRAM bank 0 at `C000h-FFFFh` |

Writes always reach SRAM. This permits the firmware to populate RAM underneath
ROM-visible addresses before switching to RAM-only operation.

In the current CP/M build, the lower 48 KiB is the banked transient program
area. The high common region contains a small application-owned common TPA,
CCP, BDOS, the Zephyr BIOS, fixed driver slots, runtime state, and the firmware
stack. Exact addresses are generated from each firmware build and recorded in
the [CP/M memory map](Code/HOST/CPM2.2/docs/memory-map.md).

## CP/M firmware

The current system boots CP/M 2.2 with a Zephyr-specific CBIOS. The firmware
separates core BIOS services from console and storage drivers and validates its
resident memory layout as part of the build.

Zephyr BIOS extensions currently include:

- `MOVE` and `XMOVE` for bank-aware memory transfers
- `SELMEM` for selecting the execution bank
- `SETBNK` for selecting the disk DMA bank
- `IOCALL` for I/O Controller command/reply transactions
- `VIDEO_SEND` for submitting video command streams

The current IOCALL transport sends one caller-owned 32-byte frame and receives
one 32-byte reply frame over SIO1/B. The BIOS owns the transport but does not
interpret individual I/O Controller commands.

For firmware architecture, build artifacts, and the current driver layout, see
[Code/HOST/CPM2.2/README.md](Code/HOST/CPM2.2/README.md).

## Console and storage

### Virtual Drip development backend

Virtual Drip is the current development proxy for console, video, keyboard
input, and CP/M storage. It lets the physical Z80 machine exercise the BIOS and
V9958-oriented software before all replacement hardware paths are complete.

The active console is an 80-column V9958 GRAPHIC 6 terminal. Terminal state is
kept in V9958 VRAM, with a CP850 font atlas, color-aware logical cells, and a
sprite-based cursor. See the
[Virtual Drip V9958 console notes](Code/HOST/CPM2.2/docs/vdrip9958-console.md).

CP/M Drive A is currently backed by an 8 MiB flat image on the proxy side. The
BIOS exposes normal 128-byte CP/M disk records and maps them to proxy storage
transactions. See the
[Virtual Drip disk format](Code/HOST/CPM2.2/docs/zephyr80_vdrip_disk.md).

Virtual Drip is a bring-up tool rather than the intended final storage and HID
architecture. Those functions are moving to the onboard I/O Controller.

### I/O Controller

The I/O Controller offloads modern peripheral protocols from the Z80. Its
eventual responsibilities include:

- SD-card storage
- USB keyboard and controller input
- system reset and power-management coordination
- asynchronous input/event delivery to the host

The current firmware implements the synchronous SIO command transport and
fixed 32-byte IOCALL frames. Basic PING and RESET commands exist for link
bring-up. Storage, HID, and unsolicited event delivery remain under development.

## Video

Video is provided by expansion hardware rather than being fixed on the CPU
board. The physical multimedia cards belong to the Percolator Series and are
maintained in the
[PercolatorLabs repository](https://github.com/dumaiss/PercolatorLabs):

- **Morning Joe**: TMS9918-family video for classic software and ColecoVision
  video compatibility
- **Lunch Crema**: V9958 video with 128 KiB VRAM and RGB output

Zephyr-specific development paths also include:

- Virtual Drip, a serial development proxy that models VDP operations on a
  modern host
- a V9958 implementation in the Zephyr MAME machine

The current CP/M graphical console targets V9958 GRAPHIC 6 semantics. Original
9918-family tests remain in the repository, but that hardware is no longer the
only or primary description of Zephyr-80 video.

## ColecoVision compatibility

Zephyr-80 is intended to run ColecoVision software through a dedicated
compatibility mode—not merely provide a collection of similar video and sound
chips. The planned compatibility path combines:

- the Percolator Series **Morning Joe** TMS9918-family video card
- one SN76489-compatible voice from the **Afternoon Blend** sound card
- the controller-input decode provided by the Zephyr I/O architecture
- launcher and memory-mapping support to install a ColecoVision BIOS and
  cartridge image before transferring control

This work remains under development, so the project does not yet claim blanket
game compatibility. Software that depends closely on the original console's CPU
timing may require adaptation because Zephyr-80 runs its Z80 at 10 MHz.

## Sound

The Zephyr-80 sound card is the Percolator Series **Afternoon Blend**, which
uses four SN76489 programmable sound generators with analog mixing and
amplification. The card design is maintained in the
[PercolatorLabs repository](https://github.com/dumaiss/PercolatorLabs), while
Zephyr-side drivers and applications belong here. Software support and
higher-level music tooling are continuing areas of development.

## MAME emulation

The repository includes Zephyr-80 MAME development under
`Code/MODERN/Emulator/`. The goal is to run the same firmware used by the
physical machine rather than maintain a separate emulator-only BIOS.

Current emulator work includes the banked ROM/RAM architecture, Z80 peripheral
topology, and V9958 video. I/O Controller, storage, and host-HID integration are
being added incrementally.

The MAME source tree and CP/M source are included as Git submodules. Clone with
submodules enabled when working on those areas:

~~~sh
git clone --recurse-submodules https://github.com/dumaiss/Zephyr-80.git
~~~

## Repository layout

| Path | Contents |
| --- | --- |
| `Schem/` | KiCad schematics and board-specific validation notes |
| `Code/HDL/` | PLD and programmable-logic source |
| `Code/HOST/CPM2.2/` | CP/M 2.2, Zephyr CBIOS, drivers, image tools, and generated memory documentation |
| `Code/HOST/Monitor/` | Interactive Zephyr monitor application |
| `Code/HOST/HelloWorld/` | Hardware bring-up and subsystem test programs |
| `Code/MCU/` | Power-management and I/O Controller firmware |
| `Code/MODERN/Emulator/` | MAME machine development and emulator ROM tests |

## Related repositories

| Repository | Scope |
| --- | --- |
| [pBITzPlatform](https://github.com/dumaiss/pBITzPlatform) | DIN-connected pBITz backplane, bus, and mezzanine-card hardware |
| [PercolatorLabs](https://github.com/dumaiss/PercolatorLabs) | Percolator Series video and sound cards, including Morning Joe, Lunch Crema, and Afternoon Blend |

## Building the CP/M firmware

Initialize the submodules, then build from the CP/M directory:

~~~sh
git submodule update --init --recursive
cd Code/HOST/CPM2.2
make
~~~

The build requires Python 3, GNU Make, and the SDCC Z80 tools `sdasz80`,
`sdldz80`, and `makebin`.

Primary outputs include:

| Artifact | Purpose |
| --- | --- |
| `build/firmware.bin` | 64 KiB logical firmware image |
| `build/zephyr80.pre-swap.bin` | assembled logical ROM image before the CPU-board data-bit correction |
| `build/zephyr80.bin` | final burnable image with the required data-bit swap applied |
| `docs/memory-map.md` | generated and validated runtime memory map |
| `docs/symbol-map.md` | generated project-facing firmware symbol map |

Additional build and backend-selection details are documented in the
[CP/M firmware README](Code/HOST/CPM2.2/README.md).

## Development notes

- Treat the PLD equations and generated firmware memory map as authoritative
  when older narrative documents disagree.
- Treat exported BIOS entry points and memory constants as firmware ABI.
- Several older architecture notes remain in the repository for design history
  and may describe superseded clock, I/O, or memory arrangements.
- Hardware revisions and experimental subsystems may require matching firmware
  branches or configuration. Check the board-specific notes before programming
  devices or applying power.

## License

Zephyr-80 is licensed under the
[Solderpad Hardware License v2.1](Licence.md), with the option described there
to treat the work as Apache License 2.0.
