# Zephyr-80 Test Programs

Small Z80 assembly programs for exercising the various parts of the Zephyr-80
machine during hardware bring-up. Each file in `src/` is built independently so
individual tests can be burned to ROM or loaded through the monitor.

## Programs

- `helloworld.asm`: initializes SIO channel B and repeatedly prints
  `Hello, World!`.
- `echo.asm`: initializes SIO channel B and echoes received serial characters.
- `ctctest.asm`: samples CTC channel 0 into a small RAM buffer.
- `vdrip_checkerboard.asm`: monitor-loadable Virtual Drip serial demo that
  repeatedly streams a TMS9928A Graphics I checkerboard over SIO channel B.
- `vdrip_smiley.asm`: monitor-loadable Virtual Drip serial demo with a smiley
  sprite moving left-to-right over a Graphics I background.
- `testiorq.asm`: repeatedly writes `55h` to I/O port `80h`.
- `testlatchport.asm`: repeatedly reads I/O port `00h` with short delay loops.
- `sndtest.asm`: CP/M program that exercises the Percolator Afternoon Blend
  sound card at `E0h`: the four SN76489AN PSGs and the AD7801 PCM DAC.

## Walkthroughs

All programs starting at address `0000h` cannot be run from CP/M, they need
to be burned separately into an EEPROM. Those that start at `0100h` are meant
to be run from CP/M and those starting at `8000h` can be loaded from within
the monitor.

### `helloworld.asm`

This ROM-style test (ie: cannot be run in CP/M) starts at `0000h`, disables 
interrupts, sets the stack to `FFFFh`, and initializes Z80 SIO channel B on 
data port `22h` and control port `23h`.

The SIO initialization resets the channel, selects x16 asynchronous serial mode
with one stop bit and no parity, enables 8-bit receive with auto-enables, and
enables 8-bit transmit while asserting RTS and DTR. Interrupts are left disabled,
so all serial I/O is polled.

After initialization, the main loop loads `HL` with `hello_message`, calls
`sio_puts`, and jumps back to print it again. `sio_puts` walks the
null-terminated string one byte at a time. `sio_putc` polls RR0 until the SIO
reports transmit-buffer-empty, then writes the character to the SIO data port.

### `echo.asm`

This serial echo test also starts at `0000h`, disables interrupts, sets the stack
to `FFFFh`, and initializes SIO channel B on ports `22h` and `23h`.

The SIO setup resets the channel, selects x16 asynchronous 8N1 operation, writes
WR3 with `0C1h` for 8-bit receive plus receive-enable, writes WR5 with `0EAh`
for 8-bit transmit plus transmit-enable, RTS, and DTR, then disables SIO
interrupts.

After setup, the program waits for one received character before printing the
banner. This keeps the banner from being lost while the terminal is being
opened. The main loop then waits for a byte with `sio_getc`, sends that same byte
back with `sio_putc`, and sends an extra line-feed after carriage-return so a
terminal moves to the next line cleanly.

### `ctctest.asm`

This is a small monitor-loadable CTC sampling test.

The file starts with `org 8000h`, so the code is intended to be loaded and run
from RAM at `8000h`, not burned as reset-vector ROM code. `CTC0` names I/O port
`40h`, which is the CTC channel being sampled. `SAMPLE_BUF` names RAM address
`8100h`, where the captured bytes will be stored.

At `start`, the program loads `HL` with `8100h`; `HL` is used as the write
pointer into the sample buffer. It then loads `B` with `32`, making `B` the loop
counter.

Each pass through `sample_loop` executes `in a,(CTC0)` to read the current byte
from CTC port `40h`. The value in `A` is stored at the current buffer address
with `ld (hl),a`, then `HL` is incremented so the next sample goes to the next
RAM byte. `djnz sample_loop` decrements `B` and repeats until 32 samples have
been written to `8100h` through `811Fh`.

After the last sample, `ret` returns to the caller. When run from the monitor,
the captured CTC values can be inspected by dumping memory starting at `8100h`.

### `vdrip_checkerboard.asm`

This is a standalone monitor-loadable Virtual Drip demo assembled with
`sdasz80`/`sdldz80` syntax. It is loaded at `8000h` and run from the monitor
with:

```text
G 8000
```

After launch, it takes over SIO channel B, reinitializes it for 115200 8N1, waits
a few seconds, then repeatedly sends Virtual Drip binary packets:

- RESET
- PING
- TMS9928A Graphics I register setup
- checkerboard pattern, color, and name table writes
- FRAME_MARK
- a replay delay

The demo does not return to the monitor. Reset or power cycle the machine to
recover the monitor.

Host-side handoff:

1. Start the monitor terminal.
2. Load `build/vdrip_checkerboard.hex` with the monitor `L` command.
3. Run `G 8000`.
4. Close the monitor terminal quickly while the demo is in its startup delay.
5. Start Virtual Drip on the same serial device:

```sh
virtual-vdp --serial /dev/serial/by-id/<device> 115200 --vnc-port 5900
```

6. Connect a VNC viewer to `localhost:5900`.

The demo resends the full checkerboard state forever, so the proxy can attach
late and still eventually display the image.

### `vdrip_smiley.asm`

This is a standalone monitor-loadable Virtual Drip animation demo assembled with
`sdasz80`/`sdldz80` syntax. It uses the same serial handoff model as
`vdrip_checkerboard.asm`: load `build/vdrip_smiley.hex` with the monitor `L`
command, then start it with:

```text
G 8000
```

After launch, it reinitializes SIO channel B for 115200 8N1, waits a few
seconds for the terminal-to-proxy handoff, then sends a full TMS9928A Graphics I
state:

- RESET and PING
- Graphics I register setup
- checkerboard background pattern, color, and name table data
- two overlaid 8x8 sprite patterns for the smiley face and facial details
- initial sprite attribute table

The main animation loop updates only the sprite attribute table bytes for the
two smiley sprites, sends `FRAME_MARK`, delays briefly, advances X, and wraps
back to the left edge. On wrap it resends full state so Virtual Drip can attach
late and recover without requiring framebuffer-style streaming.

Host-side handoff:

1. Start the monitor terminal.
2. Load `build/vdrip_smiley.hex` with the monitor `L` command.
3. Run `G 8000`.
4. Close the monitor terminal quickly while the demo is in its startup delay.
5. Start Virtual Drip on the same serial device:

```sh
virtual-vdp --serial /dev/serial/by-id/<device> 115200 --vnc-port 5900
```

6. Connect a VNC viewer to `localhost:5900`.

The demo does not return to the monitor. Reset or power cycle the machine to
recover the monitor.

### `testiorq.asm`

This ROM-style I/O request test starts at `0000h`, disables interrupts, and
loads `A` with the fixed pattern `55h`.

The loop continuously writes `A` to I/O port `80h` with `OUT ($80),A`, then jumps
back to repeat forever. It is useful for checking I/O decode, IORQ activity, and
external hardware connected to that port.

### `testlatchport.asm`

This ROM-style input-port test starts at `0000h`, disables interrupts, and sets
the stack pointer to `FFFFh`.

The loop repeatedly reads I/O port `00h` into `A`. It then runs two delay loops
by loading `B` with `0` and executing `DJNZ`; on Z80 this counts through 256
iterations before falling through. After both delays, it jumps back and reads the
port again. This gives a slow, repeated input cycle for observing latch or port
behavior on the bus.

### `sndtest.asm`

This is a CP/M program (`org 0100h`) that exercises the Percolator Series
**Afternoon Blend** sound card. `IO_DECODER.pld` routes the `E0h-FFh` block to
`SOUND` on writes and to `CONTROLLERS` on reads, so the program only ever
writes those ports. The card decodes `A2:A0` locally:

| Port | Device | Stereo placement |
| --- | --- | --- |
| `E0h` | PSG0, U6 SN76489AN | centre |
| `E1h` | PSG1, U7 SN76489AN | centre |
| `E2h` | PSG2, U11 SN76489AN | left-biased (22k/47k) |
| `E3h` | PSG3, U12 SN76489AN | right-biased (47k/22k) |
| `E4h` | PCM, U3 AD7801 | centre |

Only `A2:A0` reach the card, so `E8h`, `F0h` and `F8h` alias back onto `E0h`.
The program stays within `E0h-E4h`.

Three hardware facts shape the code. All four PSGs share one 3.579545 MHz
oscillator, so a tone divisor is `N = 111861 / f(Hz)`. The card generates its
own wait states, holding pBITz `/WAIT` until the selected chip's open-collector
READY rises, so back-to-back `OUT`s are safe and no software delay separates
them. The host data bus is reversed in the card wiring (`DB7` to PSG `D0`), so
software writes conventional SN76489 byte values and must not pre-swap them.

The PSGs have no reset input on this card, so their power-on state is
undefined. The program mutes all four chips on entry, between tests, on exit
and on abort.

Run it from CP/M:

```text
SNDTEST      run tests 1-6
SNDTEST 1    chip identification, one voice per PSG in turn
SNDTEST 2    the four voices of PSG0, alone and together
SNDTEST 3    attenuation staircase
SNDTEST 4    noise generator modes
SNDTEST 5    tone divisor sweep
SNDTEST 6    /WAIT handshake stress plus a four-chip chord
SNDTEST P    AD7801 PCM DAC sawtooth (not part of the default run)
```

Any keypress aborts, mutes every chip and returns to CP/M.

What each test is looking for:

1. **Chips.** The same note on each PSG in turn. Confirms all four chip selects
   reach a device, and that the mixer places PSG2 and PSG3 off centre.
2. **Voices.** PSG0 channels 0, 1 and 2 alone, then together as a C major
   triad, then channel 3 as noise. A missing voice here points at the latch
   byte's channel field rather than at the chip select.
3. **Volume.** Attenuation 0 to 15 and back. The attenuator is 2 dB per step,
   so the ramp should sound even rather than collapsing at one end.
4. **Noise.** Periodic and white noise at each of the three fixed shift rates,
   then the tone-3 clocked mode with channel 2's divisor swept.
5. **Sweep.** Walks the 10-bit divisor range, so every write exercises both the
   latch byte's low nibble and the second byte's upper six bits. A sweep that
   jumps in octaves or sticks at one pitch means the second byte is not
   landing.
6. **Wait stress.** 16384 wait-stretched writes issued back to back across
   `E0h-E3h` with no software spacing, roughly 150 ms of stretched bus time.
   Reaching the line after the loop is the result: the card's FF1/FF2 state
   machine armed, cleared and rearmed every time without leaving `/WAIT`
   asserted. The chord underneath it must stay steady throughout.

The `P` test drives the AD7801 at `E4h`, which is deliberately outside the PSG
wait-state generator, so those writes run at full bus speed and the waveform
timing is entirely software. `LDAC` is grounded, so the output updates on the
rising edge of `/WR`. The test leaves `80h` loaded on exit so the DAC sits at
mid-rail instead of holding a DC offset into the mixer.


## Build

```sh
make
```

The default build emits these outputs:

- `build/<name>.bin`: binary for EPROM burning, with the data-bit swap fix
  applied by `tools/swapbits.py`. The ASxxxx-only `vdrip_checkerboard.asm`
  demo is monitor-loadable only and does not produce this ROM-style output.
- `build/<name>.hex`: Intel HEX for loading without the bit swap fix. These HEX
  files are assembled to run at address `8000h`.

Build only one output family if needed:

```sh
make bins
make hex
```

Build the maintained IOC, storage, HID and sound diagnostics, copy them to the
CP/M staging directory, and replace their copies in the bootable disk image:

```sh
make install-diags
```

The installer updates `../CPM2.2/images/A/0` and
`../CPM2.2/images/zephyr80-vdrip2.cpm`, then extracts every installed file and
verifies it byte-for-byte. The image is replaced only after all checks pass.
The image, disk format, staging directory and CP/M user can be overridden with
the `CPM_IMAGE`, `CPM_FORMAT`, `CPM_STAGE_DIR` and `CPM_USER` make variables.

Override tools from the command line when needed:

```sh
make Z80ASM=/path/to/z80asm
make SDASZ80=/path/to/sdasz80 SDLDZ80=/path/to/sdldz80
make PYTHON=/path/to/python3
```

Remove generated outputs:

```sh
make clean
```
