# Emulator tests

Run from `Code/MODERN/Emulator`. `tests/run.py` is the one entry point: it
runs bounded cases against the `zephyr80` machine and records each result.
Guest images are current build outputs from their own checkouts (see
[build-and-run](../docs/build-and-run.md)); MAME's archived ROM files are not
guest inputs, and nothing here is part of either OS's build or `make check`.

```sh
python3 tests/run.py --list
python3 tests/run.py --mame ./mame/mamepbitzd \
  --case memory-flash --case clocks-irqs --case serial-boot --case timer \
  --case sio1-lanes --case sio1-konaos --case sio1-zsdos \
  --konaos-root /path/to/ZephyrOS --zephyr-root /path/to/Zephyr-80
```

| Option | Meaning |
|---|---|
| `--mame PATH` | the MAME binary (`mame/mamepbitzd` debug or `mame/mamepbitz` release) |
| `--case CASE` | repeatable; a repeated case runs again into `CASE-2`, ...; `CASE:PROBE` runs one probe of `memory-flash`, `clocks-irqs`, `sio1-lanes`, `ioc-core`, `card-image`, `card-directory`, `cpm-volumes`, `keyboard`, `terminal-apps`, `sound`, `audio-playback`, `v9958`, `graphics-apps`, `debug-symbols`, `sdk-run` or `save-restore` |
| `--list` | the cases, what each proves and the inputs it needs |
| `--konaos-root`, `--zephyr-root` | the ZephyrOS and Zephyr-80 checkouts the inputs come from |
| `--output DIR` | result directory, default `tests/output/run` (ignored by Git) |
| `--ioc-speed paced\|fast` | pass `-ioc_speed` to the guest-driven MAME runs (`sio1-*`, `serial-*`, `ioc-core` guests, `card-*`, `cpm-volumes`, `timer`); `sio1-lanes` asserts the paced lane timing and fails under fast; `ioc-timing` runs both modes itself |
| `--prompt TEXT` | the serial shell prompt the serial cases wait for, default `/system> ` |
| `--interactive` | boot the serial image in real time on a pty for a terminal (below); no verdict |

| Case | Input | Proof |
|---|---|---|
| `memory-flash` | `konaos`, `zsdos` | the twelve [memory and flash probes](#memory-and-flash-probes) |
| `clocks-irqs` | `konaos`, `zsdos` | the eleven [clock and interrupt probes](#clock-and-interrupt-probes) |
| `serial-boot` | `serial` | SIO0/B: host sync, the banner, `console: driver OK`, the shell prompt, `pwd` answered `/system`, the prompt again |
| `timer` | `serial` | `/system/timer.exe` on the guest's CTC tick (below) |
| `serial-pty` | `serial` | throttled, real time: the runner is the host terminal on the pty and types `pwd` paced by the host clock |
| `sio1-lanes` | none (the probe program) | the eight [SIO1 lane probes](#sio1-lane-probes) |
| `sio1-konaos` | `serial` | the KonaOS IOC driver over SIO1 (below): LINK_SYNC at its first attempt, the shell's PING, every request answered; the same after a reset at the prompt and a reset inside the PING reply |
| `sio1-zsdos` | `zsdos` | the ZSDOS transport over SIO1: LINK_SYNC at its first attempt and every boot request answered |
| `ioc-core` | `konaos`, `zsdos` | the three [IOC core probes](#ioc-core-probes): the protocol core against real frames, and both guests' replies from the empty card socket |
| `ioc-timing` | none (the probe program) | the six [IOC timing probes](#ioc-timing-probes) |
| `card-image` | `serial` | the three [card probes](#card-probes) for `-card` |
| `card-directory` | `serial` | the three [card probes](#card-probes) for `-carddir` |
| `cpm-volumes` | `zsdos` | the three [card probes](#card-probes) for CP/M volume files |
| `sound` | none (the probe program) | the two [sound probes](#sound-probes): the card's tones, mirrors, noise, DAC and mix on a `-wavwrite` capture, and real Z80 writes, reads and a reset |
| `audio-playback` | `konaos`, `sndtest`, `sntview`, `vgmplay` and their assets | the real sndtest, sntview and VGMPlayer playing from a card image, their audio captured and checked ([below](#sound-probes)) |
| `keyboard` | none (the probe program) | the three [keyboard probes](#keyboard-probes): the HID module against the firmware, MAME key input on the SIO1/B lane, save state |
| `konaos-video-boot` | `konaos` | the production KonaOS image to `/system> ` on its V9958/HID console, keys typed and the answers read off the screen ([below](#keyboard-probes)) |
| `zsdos-boot` | `zsdos` | ZSDOS to ZephyrShell's `B0:/$ ` on its V9958/HID console, `echo`, `ls` and Up recall typed and read off the screen |
| `terminal-apps` | `konaos`, `kedit`, `kc` | probes `image` and `folder`: KonaEdit and KonaCommander loaded from a card image and a card folder and driven by keys |
| `v9958` | `konaos`, `zsdos` | the five [V9958 probes](#v9958-probes): the observers against known VRAM, the ports, the command engine, both guests' consoles |
| `graphics-apps` | `konaos`, `gfxtest`, `gfxdemo`, `sntview`, `iobench`, `ztr` | the six [graphics program probes](#graphics-program-probes): gfxtest (every mode), GfxDemo and sntview observed on the VDP, iobench and sntview timing at both IO controller settings |
| `vdp-text` | none (a DI/HALT image) | the VDP observations: TEXT1, TEXT2 and GRAPHIC1 text read from VRAM, rendered glyph pixels, a PNG snapshot, GRAPHIC6 refused |
| `debug-symbols` | `konaos`, `sdk` | the two [developer-tool probes](#developer-tool-probes) of the `konaos` plugin under `-debug`: symbols, ambiguity, bank-aware breakpoints, physical views; the debugger's cost |
| `sdk-run` | `konaos`, `sdk` | the three [developer-tool probes](#developer-tool-probes) of the SDK's `make run` from paths with spaces |
| `save-restore` | `konaos`, `sdk` | the two [developer-tool probes](#developer-tool-probes): five save points on a card image and a card folder, each restored in a fresh process and compared with the saving run; changed media refused |

Inputs: `konaos` is `ZephyrOS/build/konaos.bin`, `zsdos` is
`Zephyr-80/Code/HOST/CPM2.2/build/zephyr80.bin`, `serial` is
`ZephyrOS/build-console-serial-selftest/konaos-console-serial-selftest.bin`
(`make console-serial-selftest`), `kedit` and `kc` are
`ZephyrOS/UserSoftware/KonaEdit/build/user/kedit.exe` and
`ZephyrOS/UserSoftware/KonaCommander/build/user/kc.exe` (`make` in each
program's directory), `gfxtest` and `iobench` are `ZephyrOS/build/user/gfxtest.exe` and
`ZephyrOS/build/user/iobench.exe` (`make build/user/gfxtest.exe`, `make build/user/iobench.exe`), `gfxdemo` is
`ZephyrOS/UserSoftware/GfxDemo/build/user/gfxdemo.exe` (`make` in its directory), `sdk` is
`ZephyrOS/build/kos-sdk-<version>.tar.gz` (`make sdk`). A missing input stops the run before
any case with exit 2, naming the file and the command that builds it.

Each case gets a fresh directory under `--output`, removed and recreated
when the case starts: `inputs.json` (MAME binary and input SHA-256, Git HEAD
and changed files of the three checkouts), `manifest.json` (the exact MAME
command, the harness environment, flash image hash, limits), `mame.log`,
`serial.bin` (bytes received from the guest), `serial-times.tsv` (emulated
time of every received chunk and every sent byte), `result.json`, and the
case's own cfg/nvram/state/snapshot directories. `results.json` in
`--output` lists every case. MAME runs with `-noreadconfig`, so no saved
setting or earlier output reaches a case.

A case passes only when MAME exits 0 and the harness printed exactly one
`PASS harness CASE:` line. A failed expectation, the emulated deadline, the
host watchdog (MAME is killed, exit 124), a MAME error exit or signal, and a
Lua error all fail it; the runner then exits 1. Failures print `DIAG` lines:
the case, emulated time, PC, SP, I, the memory latch, what the case was
waiting for, the VDP mode and the serial tail. Headless cases use
`-video none -sound none -nothrottle`; each has an emulated-time deadline,
MAME's `-seconds_to_run` two seconds later, and a wall-time watchdog.

A change to the controller's lane timing, the SIO1 model or the transport is replayed with `ioc-timing`,
`sio1-lanes`, `sio1-konaos`, `sio1-zsdos`, `serial-boot`, `ioc-core`, `card-image`, `card-directory` and
`cpm-volumes` in the default mode, and (apart from `sio1-lanes`, which asserts paced timing and `ioc-timing`,
which runs both modes itself) again with `--ioc-speed fast`. `cpm-volumes` is the ZSDOS bulk reader: its
call-based marker scan and its setup before the INI loop leave the least cover of any guest path.
A change to the keyboard, the HID module or the console observer is replayed with `keyboard`,
`konaos-video-boot`, `zsdos-boot`, `terminal-apps` and `ioc-core`.
A change to the sound card or the I/O map is replayed with `sound`, `audio-playback`, `clocks-irqs`, `serial-boot`,
`keyboard` and `terminal-apps`.
A change to the V9958, the screen or the observers is replayed with `v9958`, `graphics-apps`, `clocks-irqs`,
`konaos-video-boot`, `zsdos-boot`, `keyboard`, `terminal-apps` and `audio-playback`.
A change to save-state registration touches every device: replay `save-restore` with `serial-boot`,
`konaos-video-boot`, `keyboard`, `terminal-apps`, `card-image`, `card-directory`, `cpm-volumes`, `ioc-timing`,
`sound` and `v9958`. A change to the plugin or the SDK's run rule is replayed with `debug-symbols` and `sdk-run`.

## Serial harness

`harness.lua` is the autoboot script of every Lua case. It loads the case
script (`serial.lua`, `vdp_text.lua`), runs the case body as a coroutine
resumed once per emulated frame, and ends the run with `machine:exit()`
after its verdict. Taps and notifiers are kept referenced for the whole run;
a guard keeps a soft reset from starting the harness twice.

SIO0/B is MAME's stock `pty` slot (`-sio0b_rs232 pty`). The runner opens
the slave the slot advertises, sets it raw at 115200 8N1 with non-blocking
reads, and names it to the harness. The harness opens the same slave: what
it reads is what the slot deserialized from the guest's TXD, and what it
writes the slot shifts into the guest's RXD, both at emulated time. CPU
writes to the SIO are never read as console output.

| Operation | Meaning |
|---|---|
| `harness.wait(pred, timeout, what)` | wait until `pred()` returns a value, at most `timeout` emulated seconds |
| `harness.serial.attach(t)` | open the runner's pty slave |
| `harness.serial.host_sync(t)` | send AAh 55h every 0.25 s until the guest's first byte (the serial images hold their banner for it) |
| `harness.serial.wait(text, t, from)` | wait for text in the received bytes at or after offset `from` |
| `harness.serial.type(line)` | send a line one byte per echo, then CR; returns where the answer starts |
| `harness.serial.data`, `mark()`, `tail()` | the received bytes and offsets |
| `harness.vdp.mode()`, `reg(n)`, `vram(addr)` | V9958 mode, control registers and VRAM, read from the device |
| `harness.vdp.text()`, `wait_text(text, t)` | name-table rows read from VRAM |
| `harness.vdp.pixels()`, `snapshot(name)` | the rendered bitmap; a PNG in the case directory |
| `harness.vdp.console.load_font(path)` | the guest's 6x8 console font (`guest_font.py` writes it from the flash image) |
| `harness.vdp.console.read()` | the GRAPHIC6 console as text: rows of character codes, the reverse-video map, the count of cells that match no glyph |
| `harness.vdp.console.find(text)`, `wait(text, t)`, `wait_for(pred, t, what)` | where text is on the console; waits read the screen every few frames |
| `harness.vdp.console.dump(name)`, `printable(row)` | the screen as a text file; a row as printable ASCII |
| `harness.vdp.console.as_read(code)`, `text_at(x, y, n, paper)` | what the console reads back for a glyph the guest drew with `code`; text a program drew at a pixel position, read with the guest's font |
| `harness.vdp.display()`, `pixel(x, y, page)`, `byte(L)`, `bytes(L, n)` | the shown bitmap mode (width, lines, page, scroll, YJK); a GRAPHIC4/6/7 pixel; a logical VRAM byte (GRAPHIC6/7 interleave applied) |
| `harness.vdp.palette()`, `palette_rgb(i)`, `g7_rgb(b)`, `sprite_rgb(c)` | the 16 palette entries as saved; the colour MAME draws for an entry, a GRAPHIC7 byte and a sprite colour code |
| `harness.vdp.status(n)`, `sprites()` | a status register as saved (no port read, nothing cleared); the sprite attribute table (sprite mode 2) |
| `harness.vdp.image()`, `rendered(image, x, y)`, `histogram(x, y, w, h)`, `render_check(y0, y1)` | the rendered bitmap; the colour drawn at a display pixel; colour counts over a display rectangle; every pixel outside the sprites compared with VRAM and the palette |
| `harness.keyboard.set(key, down)`, `tap(key)`, `chord(keys)`, `type(text)` | the USB keyboard's fields (a usage or its name, `"Left Shift"`, `"Up"`, `"F5"`) through MAME's input path; each change is logged with its emulated time to `inputs.tsv` |
| `harness.keyboard.frames(n)`, `release_all()` | wait `n` frames; release every held key |

The guest's console receiver is polled one byte deep, so `type` sends each
byte only after the previous one's echo. Name-table text is the character
codes in VRAM, read as ASCII: it matches what the screen shows when the
pattern table holds an ASCII-ordered font. TEXT1, TEXT2 and GRAPHIC1–3 are
decoded (vertical scroll R#23 is not applied); MULTICOLOR and the bitmap
modes GRAPHIC4–7 hold no character codes and `text()` returns `nil` with the
reason. Both guests' V9958 consoles draw glyphs into GRAPHIC6; their
screen text is read by `harness.vdp.console` ([below](#the-graphic6-console)).
A case can add MAME options (`mame_args` in `run.py`), for example
`-wavwrite` for audio or a video mode for rendering.

The serial cases boot the console-serial image against the IOC model
([SIO1 and the IO controller](../docs/zephyr80-sio1-ioc.md)): the link comes
up, the shell banner reports `IOC version 75` from PING, the card socket is
empty and no key is pressed, the prompt follows about 3 emulated seconds after the host
sync, and the shell starts
in `/system`. `timer` taps the CTC's I/O writes and the IM2 vector fetch of
channel 2, then runs `timer stage` (INFO 390625/250, 10,000 monotonic
readings, a one-second advance within 39062–39312 counts, the bounds of
ZephyrOS `tests/test_timer.py`) and the bare `timer` (one line a second for
60 s). It requires channel 2 programmed for 10 MHz / 256 / 250 = 156.25 Hz,
the acknowledge rate during the run within 0.1 % of 156.25 Hz, no gap of
1.5 tick periods, and the guest's 60 lines 0.99–1.05 s apart.

`serial-pty` keeps throttle on: host serial pacing and `-nothrottle` run on
different clocks, so the host-paced session (sync, prompt, `pwd` one byte
per echo) runs in real time, and the harness only bounds it and reports the
host's verdict.

`--interactive` starts the serial image throttled, prints the pty MAME
advertises, sends the host sync until the banner starts, then leaves the pty
to a terminal, for example `picocom -b 115200 /dev/pts/N`. The prompt
arrives a few seconds later. Its MAME directories are under
`--output/interactive`; it stops after an hour or on Ctrl-C.

## Memory and flash probes

The runner's `memory-flash` case runs the media, decoder, reload and guest
probes. The fixture check and the debug self-test run on their own:

```sh
python3 tests/decoder_fixture.py --check \
  --zephyr-root /path/to/Zephyr-80 --konaos-root /path/to/ZephyrOS
c++ -std=c++17 -DMAME_DEBUG -Wall -Wextra -Werror \
  -I mame/src/osd -I mame/src/mame/pbitz \
  tests/decoder_selftest.cpp -o tests/output/decoder_selftest
tests/output/decoder_selftest tests/fixtures/rev13.txt
```

The case directory holds all disposable media, logs, SRAM snapshots and the
probes' `results.json` (exact commands, exit codes, wall times and input
hashes). `memory-flash:PROBE` selects probes: `one`, `partial`, `full`,
`empty`, `oversized`, `absent`, `missing`, `unreadable`, `decoder`,
`reload`, `konaos`, `zsdos`. Each MAME process has a
2-second emulated-time limit and a 60-second wall-time limit; timeout/signal
termination never passes. Positive cases require an explicit PASS marker.
Negative cases require the normal MAME error exit and diagnostic. Unreadable
media uses a directory fixture to exercise an actual host open/read failure.

`decoder_fixture.py` parses the actual Boolean equations in
`Code/HDL/WinCUPL/src/MEM_DECODER.pld`, complements the inverted RAM outputs,
and handles active-low bus pin declarations. It compares all bus-control
combinations and bank results with the actual `MemoryDecoder(13)` class in
`ZephyrOS/tests/z80sim.py`, extracted read-only with Python AST. There are
8192 mappings (256 latches × 8 regions × start/interior/mid/end addresses),
each describing reads and writes, plus 16384 select comparisons. The fixture
is not generated by the C++ implementation. `--check` verifies the checked-in
fixture and provenance hashes; omit it only when deliberately regenerating
against reviewed hardware source. No matching WinCUPL `.si` vectors are present
in the supplied HDL tree; the ignored generated `.sim` has older equations.

The guarded standalone debug self-test builds the actual shared C++ mapping
header. The Lua decoder probe exercises the CPU's real program/I/O handlers
against the same fixture, including all latch mirrors, SRAM write routing and
flash immutability. Media probes compare every addressed byte of all eight
pages, including padding. Reload tests exercise full→short replacement in the
same live device, invalid replacements, unload, explicit reset and retained
SRAM. The guest observer checks every reset-copy write, snapshots and compares
the complete copied banks at the final transition, then observes OS-mode
entry. It retains tap handles across reset and guards its temporary diagnostic
mapping. It patches no guest instructions.

Guest copy references: KonaOS `boot/shadow_copy.asm` (page 0→bank 0 and page
1→bank 7), ZSDOS `src/common/rom_copy.asm` and `src/layout/memory.inc`
(page 0→bank 0 and page 7→bank 7). Full prompts, serial, IOC, interrupt timing,
and physical-board behavior are outside these probes. No electrical flash
programming, PLD delay, permission-denied or mid-read I/O fault injection is
claimed.

## Clock and interrupt probes

`python3 tests/run.py --case clocks-irqs` assembles `clocks_irqs.asm` with
`sdasz80`, `sdldz80` and `makebin` into the case directory and boots it as
the flash image.
The program copies itself into SRAM, installs an IM2 table at 8000h whose
handlers report through mailboxes, and runs the case `clocks_irqs.lua` selects.
The Lua side timestamps every acknowledge by tapping the CPU's vector-table
read, and programs devices only through the machine's I/O handlers.
`clocks-irqs:PROBE` selects probes; each MAME process has an emulated-time
verdict limit, MAME's own `-seconds_to_run` one second later, and a wall-time
limit. A case passes only on exit 0 with its explicit PASS line.

| Case | Proof |
|---|---|
| `channels` | All 16 ports 40h–4Fh: reads return the channel the same port's writes program; counter mode with constant 256 acknowledges vector 2·channel at the channel's trigger rate (A0·2 + A1 select, 1.8432/3.6864/7.3728/7.3728 MHz) |
| `timer` | The guest tick bytes from the CPU (43h/41h reset, vector 00h, 41h A5h, FAh): 625 channel-2 acknowledges span 4 s (156.25 Hz), every interval 6.4 ms, 156 or 157 per second |
| `baud` | SIO0/A on a `loopback` slot, clocked by TO0: character times at constants 12 and 1 match 9600 and 115200 baud, bytes intact |
| `overlap` | V9958 and CTC requesting together: releasing the V9958 leaves the CTC pending; ten times the CTC (04h) is acknowledged first and the V9958 (FFh) immediately after the CTC's RETI; free-running counts |
| `daisy` | CTC and SIO0 requesting together: order 04h, 10h; the CTC nests inside SIO0's service; SIO1, programmed with WR1 06h and a written Tx buffer, is never acknowledged (it has no interrupt model) |
| `latch` | The V9958 card's configuration latch: writes with A2 = 1 (A4h–A7h and mirrors) never change VRAM, the VRAM address pointer or R#1, while A3/A4 mirrors of the ports still reach the V9958; reads at A4h and mirrors equal reads at A0h; D0 selects NMI or `/INT` through every mirror, D1 and D2–D7 have no route effect; reset clears the latch |
| `nmi` | NMI route: an asserted request moves to the NMI vector (0066h) at once on the latch write, frame requests arrive as NMIs at 59.94 Hz with no IM2 acknowledge, a request left asserted does not hold IRQ0 with EI, and switching back acknowledges at once with vector FFh and no NMI |
| `nested` | A CTC handler runs with EI, SIO0 is pending and the V9958 asserts: the acknowledge reads FFh, SIO0 is not acknowledged, and SIO0 is served right after the CTC's RETI |
| `pty` | SIO0/B on a `pty` slot, throttled: the host reads the program's 115200 8N1 banner lines |
| `konaos`, `zsdos` | The current guests boot; decoding every SIO1 control write shows WR1 interrupt enables stay clear |

The probes' `results.json` records each command, exit code, wall and
emulated time, speed and input hash. The guest `/system/timer.exe`
measurement is the `timer` case.

## SIO1 lane probes

`sio1-lanes` assembles `sio1_lanes.asm` and runs each probe in its own MAME
process (`state` in two) under `harness.lua` (`sio1_lanes.lua`), with a 3-second emulated and
60-second wall limit. The program serves operations the Lua side posts in a
mailbox: the KonaOS lane initialisation, and exchanges built from the KonaOS
driver's sequences (`ioc_io_wait_ready`, `ioc_io_tx`, the receive arm), whose
receive side records every byte the lane delivers and the empty RR0 polls
before it. `sio1-lanes:PROBE` selects probes.

| Probe | Proof |
|---|---|
| `exchange` | LINK_SYNC with Enter Hunt, then three PINGs: echo, level 75, power 6Fh, service counters +1 each, no abort; READY (`/DCDB`) low while a request is served; the capture loop finds the FIFO empty before every reply byte (the receiver is paced by the lane) |
| `hunt` | after a channel reset the receiver hunts: a PING is served (its counter shows it) but never received, since `/SYNCB` stays low; LINK_SYNC's edge resynchronises the lane |
| `underrun` | a request stalled 60 µs after its fifth byte latches Tx underrun (RR0 D6) and gets no reply; the next PING succeeds and reports one abort |
| `early` | a second request issued straight after the first waits on READY; the first reply fills the FIFO meanwhile, the bounded drain removes four stale bytes and the capture finds the second reply |
| `overrun` | a 1 ms pause after three reply bytes sets RR1 D5 and loses the reply; the next PING succeeds without Hunt |
| `reset` | a channel reset after four reply bytes ends reception (Hunt, nothing available); after LINK_SYNC the capture holds only that reply |
| `irq` | WR1 1Fh on both channels and traffic with interrupts enabled: no acknowledge |
| `state` | two processes: the first saves a lane synchronised by LINK_SYNC; the second starts from that state and a PING without Hunt is answered, its service counter continuing the saved count |

`sio1-konaos` boots the console-serial image four times in one run: cold to the
prompt and `pwd`, after a machine reset at the prompt, and after a reset taken
on the eighth byte the driver reads following the shell's PING. `sio1-zsdos`
boots the ZSDOS image for 6 emulated seconds. Both tap SIO1's ports and keep
the CPU-side register trace (`sio1-trace.tsv`: every write, every data read)
and the command-lane exchanges decoded from it (`exchanges.tsv`: request bytes
are the data writes while the transmitter is enabled for a request, reply bytes
the data reads after its release). Every request must parse and receive a
CRC-valid reply with its sequence, the first exchange of each boot must be
LINK_SYNC armed with Enter Hunt and be the only one, KonaOS must send a PING
answered with level 75 and the synchronised link bit, and no WR1 write may be
nonzero. ZSDOS sends no PING.

## IOC core probes

`ioc-core` runs three probes ([The IO controller's protocol core](../docs/zephyr80-ioc-core.md)).
`ioc-core:PROBE` selects one.

| Probe | Proof |
|---|---|
| `core` | `ioc_core/ioc_core_test.cpp`, built with the core source and run on the host: every request a complete packet in a 36-byte window, every reply encoded, CRC-checked and decoded again, bulk packets and capture windows built as the lanes carry them, expected values from the firmware source. Its eleven tests: framing (bad CRC, length, truncation, unadmitted class, nonzero STATUS, idle window, a valid frame after a broken one, counters, no stale bytes), the transport-level classes (diagnostic classes FEh, LINK_SYNC, RESET without a reply), the empty socket for every class, FS2 reads (EOF, ranges, runs of 512-byte packets, wrong cookie, stale generation after FS2_RESET, a removed card noticed at its first failing access, a disk error), directories and the 16-component resolver, bad names and refused requests leaving the media unchanged, FS2 writes (DONE, partial, wrong SEQ or TYPE, late marker, no host, underrun under the CRC bypass, reset mid-transfer, truncate, full volume, namespace commands), the `/SHARED` family, records, blocks and volumes (raw, auto-mount, file images, ranges, folder media), the HID input queue (partial dequeue, doorbell, overflow) and save registration |
| `konaos` | the production KonaOS image boots for 10 emulated seconds: each of its requests gets its class's reply with the empty-socket status, FS2_RESET generations count from 2, and the bulk lane's data port is never touched |
| `zsdos` | the same for the ZSDOS image over 8 emulated seconds |

`ioc_core/rig.h` drives the core as the transport does (shared with the card
host test), `ioc_core/memory_storage.h` is the in-memory card the core test
uses, and `ioc_core/emu.h` supplies the MAME integer types; none of them is
part of the emulator. The build command and the test's output are in the probe's log.

## IOC timing probes

`ioc-timing` (`ioc_timing.py`, `ioc_timing.lua`) runs the probe program's bulk
operations on a disposable FAT16 image, each probe in both `-ioc_speed` modes
([pacing](../docs/zephyr80-sio1-ioc.md#pacing--ioc_speed)). The operations are
the KonaOS bulk read and write sequences (`ioc_io_bulk_read`,
`ioc_io_bulk_write`) in `sio1_lanes.asm`. Timing is taken from taps on ports
30h-33h with emulated time, so the guest and the device carry no probe code
and collecting it changes nothing; `HARNESS_TRACE` writes each transfer's
accesses to `<label>.tsv`. `ioc-timing:PROBE` selects one.

| Probe | Proof |
|---|---|
| `transfers` | LINK_SYNC, PINGs, and `/SHARED` reads and writes of 128 B, 512 B and 8 x 512 B. In paced mode each phase is checked against the timing table: the reply's start and span, the admission (guard and first byte), the header and payload spans of a read, a write's first byte, byte span and `/CTSA` window. Both modes must return the same replies and payload sums, leave the same files on the card (the written file complete, `fsck.fat -n` clean) and fast must not be slower for any phase total. `TIME` lines in the log list each phase |
| `zsdos` | a reader in the ZSDOS driver's shape (`sio1_lanes.asm` op 9: drain, a call-based marker scan at 11.1 µs a byte, an INI header, 17.2 µs of setup, an INI payload) reads 128 B and 512 B records on a lane that has just hunted, just written and just read; every byte must arrive. It bounds the bulk packet's byte spacing from below (marker and header 11.1 µs plus margin; payload 6.6 µs plus margin) and fails at the firmware's 7 µs and 6 µs targets |
| `admission` | a `READY` the host never admits holds `/DCDB` low for 500 ms and ends with DONE 21h; two requests back to back are both answered; a request whose transmitter stalls inside it is dropped (one abort) and the next is served |
| `partial` | a read abandoned after 100 bytes and a write short by 212 bytes both end, DONE reports them, the 300 bytes sent are on the card, and the controller serves the next requests |
| `reset` | the machine resets inside the request window, the reply, a bulk read, a bulk write and the wait for the host: the transport is idle with nothing counted or scheduled, LINK_SYNC and PINGs follow, and requests run back to back across the instant the cancelled 500 ms wait would have ended |
| `state` | a bulk read is saved at its 300th data read and a second process restores that state: it finds the transport in the packet phase with about 300 bytes clocked, the read completes with all 512 bytes, DONE is OK and the service counters continue |

## Card probes

`card-image`, `card-directory` and `cpm-volumes` test [the card
socket](../docs/zephyr80-card.md) (`card_backends.py`); `CASE:PROBE` selects
one probe. All media are made fresh in the probe's directory: FAT images by
`mkfs.fat` and filled by `fat_fixture.py`'s own FAT writer, folders by the
host, CP/M volumes by `card_backends.py` in ZSDOS's SD geometry. Nothing else
is mounted or written.

| Probe | Proof |
|---|---|
| `host` | `card/card_test.cpp`, built with the core, the production socket and FatFs and run on the host on those media, through real frames (`ioc_core/rig.h`); then what it wrote is read back independently (`fat_fixture.Volume` and `fsck.fat -n` for images, the host filesystem for folders, volume and raw records at their file offsets). `card-image`: the shared workload (listing, reads to and past the end, READ_RUN, create, write, overwrite, sync, truncate, append, EXISTS/NOT_FOUND/IS_DIR/BAD_NAME, MKDIR, RENAME, RMDIR of a non-empty directory, UNLINK, STAT, SPACE, a stale token, the `/SHARED` family and FS2 reading what it wrote, then a new socket reading it all back) on FAT16, FAT32 and MBR-partitioned FAT32; a read-only image; a full volume; a raw card (first-access raw unit, the auto-mount dropping it, the range, a card smaller than the raw unit); a raw write to the block FatFs holds dirty; removal and an unnoticed swap; a controller reset. `card-directory`: the same workload on a folder; a read-only folder; a full folder (RLIMIT_FSIZE); 8.3 names, case, collisions, links, `.`/`..`, long and non-ASCII names; no raw unit. `cpm-volumes`: auto-mount, VOL_INFO extents and base (a 3-extent CPM_2.DRV), records across extents and at both ends, VOL_RANGE and VOL_UNMOUNTED, a cut write, FS2 and the volume seeing each other's writes, VOL_MOUNT of a wrong-size, missing and 17-extent image, on an image and a folder; a read-only volume file |
| `konaos` | the KonaOS serial image boots with the card and its shell runs `ls`, `cat`, `cp`, `stat`, `mkdir`, `mv` across directories, `cp` of 64 KiB into `/SHARED`, `rm`, `rmdir` and a missing file; each answer is checked, the card is then read back independently (and `fsck.fat -n` for the image), and a second MAME run on the same card lists and stats the results |
| `options` | MAME refuses `-card` with `-carddir`, a missing path and the wrong kind of path, each with its message |
| `zsdos-image`, `zsdos-folder` | ZSDOS boots with `/CPM/CPM_1.DRV` (C:, a text file), `CPM_2.DRV` (D:, empty), `/CPM/B` (B:) and `/SHARED/NOTE.TXT`; three ESC on the serial port hand ZephyrShell to it (`card.lua`), then `VOLINFO` (units, base, extents), `SDDIR`, `SDGET NOTE.TXT` to B: and `MCOPY D:=C:HELLO.TXT` (copy and verify); afterwards D:'s copy is read from CPM_2.DRV's own directory and compared with C:'s, C: must be unchanged and `/CPM/B/NOTE.TXT` must hold `/SHARED/NOTE.TXT` |

`card.lua` runs the guest sessions: one command per line of the steps file
the probe writes, each answer checked for its expected text (or for no output
at all), a key sent when a program ends with `[any key]`, and each step's
emulated time traced.

## Keyboard probes

`keyboard`, `konaos-video-boot`, `zsdos-boot` and `terminal-apps`
(`keyboard.py`, bodies in `keyboard.lua`) test [the USB
keyboard](../docs/zephyr80-keyboard.md). Keys go through MAME's input path
(`harness.keyboard`): a field set in one frame is applied by the next frame's
input update, where the keyboard scans and reports. Every guest step waits for
the screen the guest draws in answer; the screen of every step is in the case
directory as text and PNG, with `transcript.txt` and `inputs.tsv`.

| Probe | Proof |
|---|---|
| `keyboard:host` | `keyboard/hid_test.cpp`, built with the HID module and the core and run on the host, every expected byte, count and time from the firmware: 303 translation vectors (letters with either Shift, Alt, GUI; digits and punctuation; Ctrl to control bytes and NUL, Ctrl falling through; navigation, editing and function keys; the keypad with NumLock on), the keypad's NumLock-off layer and CapsLock, report edges (only new usages, slot order, rollover, the report's own modifiers, no keyboard), locks and their LEDs, the repeat (500 ms, 60 ms from the tick it ran at, takeover, Shift re-sampled, the half-queue limit), the queue (whole admission, drops saturating, partial dequeue, the doorbell, reset), Ctrl+Alt+Esc, HID_STATUS page 0, save registration |
| `keyboard:lane` | the probe program on SIO1/B: HID_STATUS page 0; `/CTSB` (Reset External/Status, RR0 D5) idle, then asserted by a, Shift+b, Ctrl+c, Up and F5, held through a partial HID_INPUT of 2 and released by the rest (`61 42 03 1B 5B 41 1B 5B 31 35 7E`); x held a second (the firmware's count from the press and release times, nothing after the release); z held 6 s undrained (64 queued, no drop); 43 arrows and three letters (126 then 128 queued, two drops, 24 a reply); a machine reset (queue and drops gone; a key held across it reported once, no repeat after its release); Ctrl+Alt+Esc (the controller restarts, no Escape queued) |
| `keyboard:state` | three processes on the probe program: the first saves a state with `ab` queued and R held mid-repeat, then records what it queues by a later check time; a restore with R held queues the same bytes by that time (queue, held key and repeat phase restored); a restore with R up keeps the saved bytes and repeats no more |
| `konaos-video-boot` | the production KonaOS image without a card: `/system> ` on the screen; `echo Hello World` (the first key's input-to-screen time), CapsLock, Backspace, F5 swallowed, `pwd`, Ctrl-L clearing the screen, Up/Down history, a held key's repeat on the line (the firmware's count) and a held Backspace erasing it |
| `zsdos-boot` | ZSDOS with a card folder holding only `/CPM/B` (ZephyrShell's B:; without it ZSDOS stops at `ZSDOS error on B: No Drive`): `B0:/$ ` on the screen, `echo Hello ZSDOS`, `ls` answering `SYSTEM/`, Up recalling `ls` |
| `terminal-apps:image`, `terminal-apps:folder` | a card (FAT16 image or folder) with `/BIN/KEDIT.EXE`, `/BIN/KC.EXE`, `NOTE.TXT` and `DOCS/A.TXT`. KonaEdit opens `/fs/NOTE.TXT` (menu bar, text, status `Ln 1 Col 1`); Down, End, Home, Right, Up move the status position; typing, Enter and Backspace edit the text (the modified mark); F1 and Down open the File menu, Escape closes the pop-up and the bar; F7 marks, Escape clears it; F2 saves; F10 exits. KonaCommander lists the card, its PC link times out, the arrows move the selection both ways, Enter opens `DOCS`, Backspace returns, Enter on `NOTE.TXT` opens the viewer with KonaEdit's text, Escape returns, `q` exits. The card then holds exactly KonaEdit's saved text and nothing else changed (`fsck.fat -n` clean for the image) |

### The GRAPHIC6 console

Both consoles draw 6x8 glyphs into a GRAPHIC6 bitmap (KonaOS
`drivers/v9958/v9958_driver.h`, ZSDOS `drivers/console/v9958.asm`): 85
columns by 26 rows, page 0 a circular 256-line surface, row r at scanline
R#23 + 4 + 8r, column c at bytes 3c–3c+2 of a line, paper colour 4, ink F.
`harness.vdp.console.read()` reads those lines from the vdp's address space
(MAME stores GRAPHIC6 VRAM interleaved: logical byte L at
`((L & 1) << 16) | (L >> 1)`) and R#2, R#9 and R#23 from the saved register
file. It does no port I/O and reads no status register. A cell's eight rows of
ink are matched exactly against the guest's own font, which `guest_font.py`
reads from the flash image: KonaOS's from the ROMFS `v9958.mod` mapped
segment (the driver's paged font), ZSDOS's from flash 78000h
(`CONSOLE_FONT_ROM_BASE` in bank 7). A cell matching with ink and paper
swapped is reverse video; a fully inked cell is a reverse space (pixel for
pixel CP850's full block, which these programs do not draw). Any colour other
than paper counts as ink. Cells that match no glyph (the KonaOS logo, a glyph
half drawn) are counted as unknown. Sprites (the text cursor, the pointer) are
not in the bitmap. Another mode, another page or a graphics screen is not a
console; it is captured by `snapshot`.

## V9958 probes

`v9958` (`video.py`; bodies in `video.lua` and `vdp_text.lua`; the command probe program `video.asm`) tests the stock
V9958 as the machine wires it ([the video card](../docs/zephyr80-video.md)). Each probe is one MAME process.

| Probe | What it checks |
|---|---|
| `v9958:bitmap` | a DI/HALT image drives the chip through its ports and the observers read it back: GRAPHIC6 corner pixels, the palette, 212 and 192 lines (the active area at row 22 and 42 of the 544×466 bitmap), the vertical scroll mapped and rendered, page 1 through R#2, a sprite in sprite mode 2 (decoded, drawn two hi-res pixels wide, gone with R#8's SPD), the status flag left for the guest's first read after fifty observer reads, a pending control byte, palette byte and read-ahead left untouched by every observer and a snapshot (and changed by a port status read), GRAPHIC7 (fixed palette), and a pixel written but not yet drawn that the render check must catch |
| `v9958:ports` | seventeen addresses across the 16 KiB banks and the A16 boundary written and read back; GRAPHIC1's counter wrapping inside its bank; GRAPHIC6 runs crossing 3FFFh/4000h, FFFFh/10000h and the last byte; the GRAPHIC6 interleave; the mirrors across A0h–BFh and writes with A2 set; the sixteen palette entries (pointer wrap, upper bits) and their rendered colours; the indirect register port with and without auto-increment; S#1's ID, S#0's frame flag and its clear on read |
| `v9958:commands` | `video.asm` runs the KonaOS driver's sequence (the 15-byte block through the indirect port, S#2 polled until CE clears) on the real Z80; taps log the starting write and the first poll that saw CE clear. HMMV, HMMM, a console glyph HMMM with sprites on and off, LMMV with IMP/AND/OR/XOR, LMMM IMP/TIMP and PSET in GRAPHIC7 and GRAPHIC6 are compared pixel for pixel with references; LINE in eight octants plus horizontal and diagonal is checked for its start dot, one connected path, one dot per major step and its direction; a full-screen HMMV shows CE busy for its whole time; HMMV 128×40 by display and sprite state. `commands.tsv` lists every run's busy time |
| `v9958:konaos-console`, `v9958:zsdos-console` | the production image's console from a card file: the prompt screen against the rendered bitmap and the sprite cursor (pattern 0, colour 11, on the cell after the prompt); an ANSI listing (the font's glyphs 20h–7Eh and 80h–FCh, cursor positioning, reverse video drawn ink-on-paper swapped, erase to the end and the start of a line, wrap at column 85, wrap off, tab, backspace, insert line, the shell prompt written where the cursor was left); a 100-line listing that runs the circular surface past its end (the last rows in order, R#23 moved, the prompt and the cursor on the last row, every pixel as VRAM says); every status read selects S#2 and `/INT` stays low. ZSDOS's `cat` pages (`--More--`); the probe presses a key at each page |

A cell is read back as the first code sharing its bitmap, printable ASCII first, so the expected text of a glyph
row is the font's own (`console.as_read`); the bytes FDh–FFh are not in the ZSDOS listing because its `cat` writes
through BDOS function 6, where they mean console input.

## Graphics program probes

`graphics-apps` (`video.py`; bodies in `apps.lua`) runs the real programs from a card image on the production KonaOS
image, typed at the shell. A program that takes the display is held at its key stops (the console's interlace bit gone
and no VDP port write for half a second), observed, and released with a key; the lines it prints are read off the
restored console. Every capture is a PNG listed in `captures.tsv` and `captures.json` with its file SHA-256 and the SHA-256 of its decoded pixels (the file's text chunks carry MAME's version string, the pixels do not), the program,
its arguments, the stop and the program and asset hashes.

| Probe | What it checks |
|---|---|
| `graphics-apps:gfxtest` | every gfxtest mode. `info`: the record (`v1 b1 fF r128 pA0 A1 A2 A3 A4 c0`). `mode6`, `mode7`, `yjk`: the held screen is one colour over every VRAM byte (R#25's YJK bit for `yjk`), rendered as VRAM says. `reopen`, `text`: their result lines. `upload`: every byte of the four uploaded rectangles (chunks of 1, 7, 256 and 4096; page 0 and page 1) seen written to its VRAM address, and the page-1 bytes in place. `palette`: entries 1–3 as saved. `prims`: the fill ordering, the 32 of 33 queued fills drawn at the auto-flush, the four overlapping copies against a memmove reference, the page copies in both directions. `shapes`, `atlas`, `timing`: every held screen rendered as VRAM says with its captures. `pages`: the upload winning over a fill in flight, page 1 shown (band and body colours), three retrace waits, the partial present, twelve page flips at the frame rate. `pointer`: the sprite's position, size, colour and pattern against the program's shape, drawn at the hot spot. Every mode's own result lines are in `gfxtest-results.txt`; the markers of `timing` give `gfxtest-timing.tsv` (the twelve windows in µs and T-states) |
| `graphics-apps:gfxdemo` | the cleared screen, two bars, the box and its copies, both texts read back with the font, the application glyph and its restore, rendered as VRAM says, and the exit line |
| `graphics-apps:sntview`, `graphics-apps:sntview-fast` | the tracker viewer on `NIGHT.ZTR`: the first screen rendered as VRAM says, a page flip by Space (R#2) and back, forty seconds of playing (the screen changes; at most 10 % of its pixels trail VRAM at an instant), and the exit report (`underruns 0, overruns 0, missed ticks 0`, the late counts and the per-step timing line, kept in `sntview-exit.txt`), at the paced and the fast IO controller setting |
| `graphics-apps:iobench`, `graphics-apps:iobench-fast` | the I/O bench: the console, VDP, direct-write and card rows (`iobench.tsv`), at both settings |

A rendered-bitmap check compares MAME's frame with VRAM; it holds on a held screen and is a tolerance during
playback, where the foreground draws while the frame is rendered.

## Sound probes

`sound` and `audio-playback` (`sound.py`, bodies in `sound.lua`, the probe
program `sound.asm`) test [the sound card](../docs/zephyr80-sound.md). Every
run captures the mixed audio with `-wavwrite` at 192 kHz under `-sound none`
(no host audio device) and logs each write and read of E0h-FFh with its
emulated time and each phase's start and end to `events.tsv`; `sound.py` reads
both. The audio is analysed with numpy: tone frequencies from interpolated
edge crossings, spectra with a Goertzel filter, levels as means and swings,
all against the decoder and mix constants of the machine. Its delay against the
events (about 16 us, the resampler's) is found from the audio itself.

| Probe | What it checks |
|---|---|
| `sound:bus` | Lua writes the bus. All twelve tone channels alone through their own port: frequency within 0.002 and swing within 3 % of 3579545 / (32 N) and the chip's level; the 12 mirrored ports (E8h-FBh); ports 5-7 and their mirrors silent; four chips at once (a spectrum line each) then each silenced alone while the others stay; the sixteen attenuation steps (2 dB, 15 off); the noise generator (rates 0-3, white and periodic, the retriggering rewrite, chip 3 through FBh) decoded to bits and matched to a model of the SN76489A, and a model of the SN76489 shown not to match; the periodic ring repeating every 15 shifts; ten DAC codes through the port and its mirrors (80h is zero, FFh +0.992, 00h -1.0); loud mixes (every voice of every chip plus the DAC at each extreme) for peaks and clipping; silence between phases to 2 LSB |
| `sound:guest` | the probe program with real instructions. `OTIR` of the driver's silence bytes into each PSG (every byte arrives; consecutive writes 10.6 us apart against 8.94 us for 32 PSG clocks) and into the DAC (2.1 us, no stretch); `IN A,(C)` over E0h-FFh while a tone sounds (all FFh, 32 read events, no writes, the tone's frequency unchanged); `OUT (C),A` to chip 3 through F3h and the DAC through FCh; a machine reset with a tone and the DAC high (the DAC register clears to 00h, the tone continues); silence after the silence sequence |
| `audio-playback:sndtest` | the real `sndtest` modes `tones`, `adsr`, `noise`, `modes`, `catchup`, `close` and `zvg` of a short stream, run from a card image on the production KonaOS image, driven by keys and read off the console: every PASS and printed count, the twelve held notes' divisors on the four chips against the library's table, the noise control bytes E1 E1 E7, the stream's PSG0 writes against its report, silence and the DAC at 80h after the exit |
| `audio-playback:sntview` | the real `sntview` playing the tracker song: it plays, pauses (no write and no sound for two seconds), resumes and quits; its report; the audio against an ideal rendering of the writes; silence after the exit |
| `audio-playback:vgmplay` | the real VGMPlayer playing the music stream for twelve seconds and stopped by a key: its report, the PSG0 writes against the report (the chips 1-3 receive only the driver's and library's own writes), the audio against the rendering, silence after the stop |

The program names come from the build manifests (`<name>/<name>.json` beside
each packed program), the card paths follow them, and the assets are
`UserSoftware/SNTracker/songs/night-market.ztr`,
`tests/snd/fixtures/NIGHT.ZVG` and `tests/snd/fixtures/wraps.zvg` of the
KonaOS checkout. `audio-playback` needs `make -C $KONAOS_ROOT build/user/sndtest.exe`,
`make -C $KONAOS_ROOT/UserSoftware/SNTracker` and
`make -C $KONAOS_ROOT/UserSoftware/VGMPlayer`.

The ideal rendering is an event-driven model of the SN76489A fed with the
writes the guest made (`sound.ChipModel`): the counters of the datasheet's
count grid, the card's gains, the DAC. The capture is compared with it in 0.1 s
windows after one global delay. The players must match every window (the
correlation 0.9 or better, the swing within 3 %); the unfiltered rendering
caps the correlation near 0.99. The `sndtest zvg` stream is a synthetic
ring-wrap stress (three tones a few Hz apart, rewritten every tick). Its
windows show a phase difference between the rendering and the chip after a
tone counter reloads in the 12 us between the latch byte and the data byte of a
tone write (the two counters then differ by up to 15 counts, as the chip's
saved counters show at the end of the stream), which three near-equal tones
make a large difference in a window; so only its median (0.95) is required and
the spread is reported.

## Developer-tool probes

`tests/devtools.py` with `devtools.lua` under the harness and the `konaos` plugin
(`-pluginspath mame/plugins -plugin konaos`; [debugging KonaOS programs](../docs/zephyr80-debugging.md)).
Every probe unpacks the `sdk` tarball into its own directory and builds its fixtures with it:
`tests/sdk/bankbp` (a placed program: `home_step` is the home zone's first code and `far_step` far
segment 1's, both at 8000h) and `tests/sdk/savework` (reads `/fs/INPUT.BIN`, writes and re-reads
`/fs/OUTPUT.BIN`, twenty 20 ms timer waits each with a PSG0 tone and a console line).

| Probe | Proof |
|---|---|
| `debug-symbols:banks` | under `-debug -debugger none`: errors for nothing loaded, a missing OS or program map, a placement naming a home area the map lacks; `kos_entry` and `main` ambiguous between bankbp and the template hello, `image:name` and the `_name` fallback, an unknown name and image, refused breakpoints on an absolute and a caller-window symbol, the nucleus's bank 7 and common bank 0; breakpoints on `home_step` and `far_step` pending until the launch, then stopping home/far three times each at 8000h in two banks, the far stops with mode 10 and P ≠ 0; at a far stop the SRAM share, the debugger's `dump` of it (`addr:sram.s`) and of VRAM (`addr:vdp`) read the home bank, the far bank and VRAM's upper 64 KiB while the latch and the VDP status registers stay unchanged; a plain `bpset 8000` stops in bankbp's two banks six times and wherever else code runs at 8000h |
| `debug-symbols:timing` | the same boot and run without the debugger, with it, and with the two breakpoints (six stops): wall time per emulated second, informational |
| `sdk-run:run` | the SDK unpacked under a path with spaces, MAME, the image and the card folder at paths with spaces, `make run KOS_BREAK=main` in `template/` with `-debug -debugger none`: HELLO.EXE staged, the breakpoint reported pending and then stopped at `hello:_main`, the program's lines in `result.txt`, exit 0 |
| `sdk-run:names` | `examples/`: `KOS_RUN=files` with arguments and two assets (one renamed): FILES.EXE, NOTES.TXT and HELLOSRC.C staged and listed by the program; no `KOS_RUN` among several programs and an invalid asset name refused |
| `sdk-run:no-mame` | `make` in `template/` with no MAME on PATH and none configured builds HELLO's EXE; `make run` names the missing binary (a path, and on PATH), the missing image and the missing plugin |
| `save-restore:image`, `save-restore:folder` | savework from a 16 MiB FAT16 image or a folder: one run saves `idle` (the prompt), `command` (a command window clocking), `bulk` (the program's load, BULK_SEND), `write` (an OUTPUT.BIN block arriving, BULK_RECEIVE, the file open for writing) and `active` (tick 5: timer, console, PSG), copying the card at each save instant; each state restored in a fresh process onto its copy must match the saving run: the IO controller and SIO1 line state at the first frame after the save, every PSG/DAC write with its time, the VDP registers, VRAM, the screen, the end time and the card's final contents. The `bulk` state onto a card with one byte of INPUT.BIN changed, and (image) with a flash image one byte different, must end MAME with the socket's or the flash's fatal error |
