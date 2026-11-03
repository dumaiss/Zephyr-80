# Zephyr-80 MAME — Build and run

The `zephyr80` machine is in the `pbitz` subtarget, registered in
`mame/src/mame/pbitz/pbitz.lst` and built using
`mame/scripts/target/mame/pbitz.lua`. The global `zephyr` entry is a different
machine.

## Build

From `Code/MODERN/Emulator/mame`:

```sh
make SUBTARGET=pbitz DEBUG=1 -j2   # ./mamepbitzd
make SUBTARGET=pbitz -j2           # ./mamepbitz
```

The debug binary supports `-debug` and Lua taps. Launch the binary just built;
the debug and release names differ. The subtarget lists device source files
explicitly in `pbitz.lua`. After changing that project file, regenerate the
build files:

```sh
make SUBTARGET=pbitz DEBUG=1 REGENIE=1 -j2
```

Generated build files can contain absolute paths. Regenerate them with the same
command after moving the tree if they refer to an old location.

## Images and operation

Build current images from their source checkouts. Existing MAME ROM copies
are archival and do not represent current guest builds.

```sh
KONAOS_ROOT=/path/to/ZephyrOS
ZEPHYR_ROOT=/path/to/Zephyr-80
make -C "$KONAOS_ROOT" build/konaos.bin
make -C "$ZEPHYR_ROOT/Code/HOST/CPM2.2" CCP=zshell BDOS=zsdos \
  CONSOLE=v9958 STORAGE_A=rom build/zephyr80.bin
```

From `Code/MODERN/Emulator/mame`, either image uses the same machine:

```sh
./mamepbitzd zephyr80 -flash "$KONAOS_ROOT/build/konaos.bin"
./mamepbitzd zephyr80 -flash "$ZEPHYR_ROOT/Code/HOST/CPM2.2/build/zephyr80.bin"
```

`-flash` is required. The image must contain 1–524288 bytes, loaded without
CRC/SHA1 pinning. Short images have an FFh tail; empty, oversized or unreadable
images fail explicitly. All CPU writes go to SRAM: flash is read-only and
MAME never writes the input file. The image manager/Lua `image:load()` replaces
flash contents immediately and clears the entire previous image, retaining
SRAM and the current latch. **Reset the machine after replacing media to boot
it** (`manager.machine:soft_reset()` in Lua); reset selects latch 00h.
Unloading or a failed replacement leaves erased flash. Save state registration
covers SRAM, the latch and the flash contents; mounting media is still required
when starting a machine.

A bounded headless run uses:

```sh
./mamepbitzd zephyr80 -flash "$KONAOS_ROOT/build/konaos.bin" \
  -video none -sound none -nothrottle -seconds_to_run 2
```

The [memory/flash probes](../tests/README.md) verify both reset copies and
entry into OS mode. Serial/keyboard prompt operation and the IOC connection
remain incomplete; loading an image does not imply full OS boot acceptance.

## Memory decode

The programmed `Code/HDL/WinCUPL/src/MEM_DECODER.pld` Rev 13 is authoritative.
The 74HC273 latch is mirrored at ports 00h–0Fh (high I/O address byte ignored):
Q=D2:D0, binary mode=D4:D3, P=D7:D5. Its masked mode values are
00h/08h/10h/18h. Reset sets every latch bit to zero.

| Binary mode | Latch mask | Reads | Writes |
|---|---|---|---|
| 00 | 00h | Flash page P, all 64 KiB | SRAM Q, all 64 KiB |
| 01 | 08h | SRAM Q, all 64 KiB | Same SRAM mapping |
| 10 | 10h | SRAM Q below E000h; bank 0 at E000h–FFFFh; if P≠0, 8000h–BFFFh selects bank 7−P | Same SRAM mapping |
| 11 | 18h | 0000h–1FFFh: Q; 2000h–5FFFh: bank 7; 6000h–DFFFh: bank 7−P; E000h–FFFFh: bank 0 | Same SRAM mapping |

Both chips contain eight 64 KiB banks/pages (512 KiB each). A0–A15 always
retain the CPU address; only the chip and bank/page change. P=0 disables the
mode-10 aperture and selects bank 7 in the mode-11 window. The shared
`zephyr80_map::decode()` supplies read chip/physical address and SRAM write
address to CPU handlers and debugger clients.

The model covers the memory selects/address decode, not PLD propagation,
board wiring/analog timing or flash programming commands. It checks against
the source PLD's inverted output equations and the read-only KonaOS
`tests/z80sim.py:MemoryDecoder` reference. No matching WinCUPL vectors are
available in the supplied HDL tree; fixture provenance is in
`tests/fixtures/rev13-provenance.json`. MAME results are not physical-board
acceptance.

## Serial and debugging

SIO0/B has a fixed 115200 8N1 clock and exposes `pty` and `loopback` RS232
slots; SIO0/A takes its clock from the CTC. `-listslots zephyr80` lists the
slots. A pty session uses `-sio0b_rs232 pty` and MAME reports its host device;
keep throttle enabled for real-time serial pacing. SIO1 is unconnected.

For debugging, `-debug` opens the interactive debugger in a debug build, and
`-autoboot_script foo.lua -autoboot_delay 0` runs a Lua script at startup.
`zephyr80-bringup-fixes.md` is a historical fix log.
