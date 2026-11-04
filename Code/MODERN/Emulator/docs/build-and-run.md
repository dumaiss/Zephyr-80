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
make -C "$KONAOS_ROOT" console-serial-selftest   # serial-console image
```

The serial-console image,
`build-console-serial-selftest/konaos-console-serial-selftest.bin`, is the
production driver set with the console on SIO0/B.

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

The [test runner](../tests/README.md) runs bounded, scripted cases: both
images' reset copies and OS-mode entry, the clocks and interrupts, and the
serial-console image to its shell prompt, and the IOC link. SIO1 carries a
behavioural IO controller ([SIO1 and the IO controller](zephyr80-sio1-ioc.md))
with its [protocol core](zephyr80-ioc-core.md); the card socket is empty and
no keyboard is attached, so the V9958/HID console takes no keyboard input and
the guests report no filesystem.

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

## Clocks and interrupts

Electrical evidence is the native KiCad netlist (`kicad-cli sch export netlist`)
of `Schem/Zephyr-80-IO` and `Schem/Zephyr-80-CPU`, the pBITz backplane
(`pBITzPlatform/pBITzBackplane/Backplane.kicad_sch`) for the bus pull-ups, and
the LunchCrema video card (`PercolatorLabs/Schem/LunchCrema`, HDL
`Code/HDL/LunchCrema/v9958WSGenerator.pld`). On the IO board IC1 is the CTC,
IC2 SIO0 and IC3 SIO1.

| Signal | Nets | Machine |
|---|---|---|
| CPU, CTC and SIO `CLK` | `CLK_10M` (CPU board Y1, bus `CLK0`) | Z80, CTC, SIOs at 10 MHz; CTC timer mode counts it through ÷16/÷256 |
| CTC CLK/TRG0, SIO0 RxTxCB | `/Baud Clock/CLK_1M8432` = U8 74HC4040 Q2 | 14.7456 MHz ÷ 8 = 1.8432 MHz |
| CTC CLK/TRG1 | `/Baud Clock/CLK_3M6864` = U8 Q1 | ÷ 4 = 3.6864 MHz |
| CTC CLK/TRG2, CLK/TRG3 | `/Baud Clock/CLK_7M3728` = U8 Q0 | ÷ 2 = 7.3728 MHz |
| U8 clock | `Net-(U8-CLK)` = Y1 ECS-2100AX-147.4 output | 14.7456 MHz oscillator |
| SIO0 RxCA, TxCA | `USR_UART_BAUD_CLK` = CTC ZC/TO0 | TO0 pulses clock SIO0/A |
| CTC channel select | `/IO Controller Card/A1` → CS0, `A0` → CS1 | channel = A0·2 + A1: 40h ch0, 41h ch2, 42h ch1, 43h ch3; 44h–4Fh mirror |
| Daisy chain | bus `CTRL_18` (backplane RN5 4.7 kΩ to +5 V) → `/IO Controller Card/IEI` → CTC; `Net-(IC1-IEO)` → SIO0 IEI; `Net-(IC2-IEO)` → SIO1 IEI; SIO1 IEO → `/IO Controller Card/IEO` (bus `CTRL_17`, unused) | priority CTC > SIO0; SIO1 has no interrupt model and passes IEI to IEO |
| `/INT` | `/IO Controller Card/~{INT}` (CTC, SIO0, SIO1), bus `CTRL_14` (RN7 pull-up), CPU pin 16 | wired-OR level |
| `/NMI` | CPU board `/CPU and Address Decoding/~{NMI}` = J2.A12 (`CTRL_15`) and Z80 U3 pin 17; bus `CTRL_15` (RN5.8 pull-up) | the V9958 card's NMI route |
| Data bus idle | backplane D0–D7 pull-ups (RN5/RN6/RN7, 4.7 kΩ) | unclaimed acknowledge reads FFh |

Guests program the tick as CTC channel 2 (port 41h) in timer mode, ÷256, time
constant 250: 10 MHz / 64000 = 156.25 Hz. Counter mode with time constant N
divides the channel's trigger clock by N; on channel 0 it sets SIO0/A's rate to
1.8432 MHz / (16·N) in x16 mode (N = 1 gives 115200 baud, N = 12 gives 9600).
CTC ZC/TO1 and ZC/TO2 only reach connectors.

The machine composes `/INT` from its sources: the V9958 sits outside the daisy
chain, the CTC and SIO0 request only while their IEI is high, and a source
releasing its request never clears another's. SIO1, polled by both guests
with its interrupts disabled, has no interrupt logic. The CTC and SIO0 keep
the stock MAME acknowledge and RETI behaviour: the highest-priority requesting
device supplies the vector, and a device in service blocks those below it until
its RETI. The acknowledge stops at the first device in service, as the chain's
IEI does: with a daisy ISR running under EI and a lower device requesting, a
V9958 acknowledge reaches no device and reads FFh (backplane data pull-ups)
instead of vectoring to the blocked device. MAME's Z80 daisy helper
(`z80daisy.cpp:daisy_get_irq_device`) stops at the first device in service,
as `daisy_update_irq_state` does.

### V9958 card interrupt latch

The LunchCrema card decodes `~{CS_VDP}` (window A0h–BFh; A3 and A4 are not
decoded) with a 74AHCT139 (U10). Reads always select the V9958 by A1:A0, A2 is
ignored (`~{CSR}`, half 1: A0 = `~{RD}`, A1 = GND). For writes, half 2 uses A0 =
A2 and A1 = `~{WR}`: A2 = 0 is `~{CSW}` to the V9958 and A2 = 1 is
`~{INT_MODE}`, which clocks the 74HC273 U3 (CP = `~{INT_MODE}`, MR =
`~{RESET}`). That write never reaches the V9958. D0 loads Q0, D1 loads Q1 =
`~{WS_EN}` (the WAIT generator U11 only); D2–D7 are tied low and Q2–Q7 are
unconnected. Reset clears both bits.

| Net | Nodes |
|---|---|
| `/Video/~{INT_i}` | U2 V9958 `~{INT}`, R5 pull-up, U8 74LVC1G19 `~{E}` |
| U3 Q0 | U8 A: Q0 = 0 selects Y0, Q0 = 1 selects Y1 |
| `/Video/~{INT}` | U8 Y0 through U9 (BAT54), J2.C11 (`CTRL_14`) |
| `/Video/~{NMI}` | U8 Y1 through U9, J2.A12 (`CTRL_15`) |
| `/Video/~{INT_MODE}` | U10 half 2 Y1, U3 CP |
| `/Video/~{WS_EN}` | U3 Q1, U11 pin 5 |

The card leaves `CTRL_17` and `CTRL_18` (IEO/IEI) unconnected. The CPU board
wires `CTRL_14` to Z80 `~{INT}` (U3.16) and `CTRL_15` to Z80 `~{NMI}` (U3.17),
so the machine models the latch as: Q0 = 0, the V9958 request joins the `/INT`
wired-OR (acknowledge FFh, as above); Q0 = 1, the request drives the Z80 NMI
line and leaves `/INT` alone. NMI has no acknowledge cycle and the Z80 takes it
on the falling edge; a latch write re-routes an already asserted request, so
moving a pending request to NMI takes the NMI at once and moving it back to
`/INT` interrupts at the next EI. D1 is stored and has no timing effect. The
WAIT generator fixes a board timing margin that the MAME Z80 core does not
reproduce, and its speed effect is small, so it is deliberately not modelled.

Simulation limits: the trigger inputs are channel clocks rather than edges, so
edge polarity (control bit D4) and the phase between the divider outputs and
SIO0/B's clock are not modelled; an externally triggered timer starts one
trigger period after its constant. The IOC-driven `RESET_HIGH` divider reset
is not modelled. The V9958 interrupt wiring above is traced on the card and
CPU board only; no other slot card is modelled. A RETI that ends a V9958
handler also ends the service of the daisy device in progress, as on the bus.
The [clock and interrupt probes](../tests/README.md#clock-and-interrupt-probes)
check these properties in MAME only; they are not physical-board evidence.

## Serial and debugging

SIO0/B has a fixed 115200 8N1 clock and exposes `pty` and `loopback` RS232
slots; SIO0/A takes its clock from the CTC. `-listslots zephyr80` lists the
slots. A pty session uses `-sio0b_rs232 pty` and MAME reports its host device
(`:sio0b_rs232:pty: pseudo terminal slave /dev/pts/N`); keep throttle enabled
for real-time serial pacing. SIO1 is the [IOC link](zephyr80-sio1-ioc.md).

The serial-console image holds its banner until the host sends AAh 55h on
SIO0/B, and its console receiver is polled one byte deep, so a terminal types
one byte at a time. The shell prompt `/system> ` follows about 3 seconds after
the sync. `python3 tests/run.py --mame ./mame/mamepbitzd
--interactive --konaos-root "$KONAOS_ROOT"` starts the image in real time,
sends the sync and prints the pty for a terminal such as
`picocom -b 115200 /dev/pts/N`.

For debugging, `-debug` opens the interactive debugger in a debug build, and
`-autoboot_script foo.lua -autoboot_delay 0` runs a Lua script at startup.
`zephyr80-bringup-fixes.md` is a historical fix log.
