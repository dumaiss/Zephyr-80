# Zephyr-80 MAME — Completion Plan

The `zephyr80` machine (`mame/src/mame/pbitz/`) becomes an application
development emulator for the current board: it boots KonaOS and ZSDOS images,
shows the V9958, plays the sound card, reads the keyboard and serves an SD card.
The physical board stays the reference; where the two disagree, the board wins
and the emulator is fixed.

## 1. Decisions

- **Two boot images, one machine.** Any flash image up to 512 KiB loads at
  start: KonaOS (`ZephyrOS/build/konaos.bin`) or ZSDOS
  (`Code/HOST/CPM2.2/build/zephyr80.bin`). Both run on the current hardware, so
  both run here; neither needs a machine variant. The old CP/M firmware under
  `Emulator/roms/` is obsolete and goes.
- **The IOC is behavioural.** The emulator models what the Z80 observes at
  SIO1 — lane registers, handshake lines, frames, replies and their effects —
  not the PIC18F57Q84 or its firmware. The references are the firmware's
  protocol (`Code/MCU/IOController/include/ioc_frame.h`, `src/fs2.c`,
  `src/volume.c`, `src/ioc_hid.c`) read as a specification, and the KonaOS
  simulator's register-level peer (`ZephyrOS/tests/z80sim.py`,
  `IocCommandPeer`), which the KonaOS driver is validated against.
- **Two card backends behind one interface:** a FAT image file (`-card sd.img`)
  and a host folder (`-carddir dir/`). The folder mode presents what the
  firmware's FatFs presents: 8.3 names (no LFN), case-insensitive lookup.
- **Emulator tests live with the emulator.** Nothing is added to the KonaOS or
  ZSDOS builds or their `make check`.

## 2. Where it stands

| Area | State | Gap |
|---|---|---|
| Z80 at 10 MHz, handler-based memory | works | — |
| Memory decoder | MEM_DECODER Rev 09 | Rev 13: latch modes 00/08/10/11, page field P, the mode-11 window, the mode-10 aperture |
| Flash | 128 KiB `ROM_LOAD` with a fixed CRC | any image up to 512 KiB, no hash |
| CTC | present at 40h-43h, A1:A0 as the channel | board order: 40h ch0, 42h ch1, 41h ch2, 43h ch3; trigger clocks 1.8432 / 3.6864 / 7.3728 / 7.3728 MHz unwired |
| SIO0 | console on SIO0/B, pty or loopback | — |
| SIO1 | placeholder clocks, `coffeeio` stub | the IOC: command lane, bulk lane, FS2, volumes, HID |
| V9958 | stock device, 128 KiB VRAM | validation against KonaOS and ZSDOS graphics |
| Sound | none | four SN76489 at 3.579545 MHz on E0h-E3h, the DAC on E4h |

## 3. Milestones

| | Proof |
|---|---|
| **A** | the KonaOS serial-console image boots to `/system>` on the pty |
| **B** | the KonaOS production image shows its shell on the V9958 and takes keyboard input; ZSDOS shows its prompt |
| **C** | programs load from both card backends; KonaOS `hwtest` reports `4/4 PASS`; ZSDOS reads and writes `B:` and a `C:` volume |
| **D** | sntview and VGMPlayer play; sndtest passes |
| **E** | `make run` from the KonaOS SDK; symbols in the debugger; headless scripted runs; the documents |

## 4. Work packages

Sizes: S a few days, M about a week, L two weeks or more.

**WP0 — Clean-up (S).** Remove the `coffeeio` stub, the SIO TX logging and
`Emulator/roms/`. Rewrite `build-and-run.md` for the two images.

**WP1 — Rev 13 decoder and the flash device (S).** Transcribe
`Code/HDL/WinCUPL/src/MEM_DECODER.pld` Rev 13 (the simulator's `MemoryDecoder`
is a checked transcription). Latch bits become Q (D0-D2), mode (D3-D4) and P
(D5-D7). The flash is an image device (`-flash image.bin`), padded with FFh.
Check the decoder against the PLD's WinCUPL vectors in a debug self-test.

**WP2 — Clocks, CTC, interrupts (S).** Board CTC port order and trigger
clocks; SIO0/B clocked from `CLK_1M8432`; SIO0/A from CTC TO0; the IEI/IEO
daisy order from `Schem/`; the V9958 /INT outside the daisy chain (vector
FFh). Proof: the KonaOS 156.25 Hz tick (`timer.exe`).

**WP3 — Serial boot and the script harness (S) → A.** The KonaOS
serial-console image on the pty. A Lua autoboot harness that types a line,
waits for text on the console or the screen, and exits with a status
(`-video none -sound none -nothrottle`); every later package proves itself with
it.

**WP4 — SIO1 lane model (M), a decision gate.** The KonaOS and ZSDOS drivers
run SIO1 as external-sync x1 lanes: Hunt, RTS as the request, /DCDB as
COMMAND_READY, /CTSB as the HID doorbell, /DCDA and /CTSA as bulk admission,
EOM and underrun, wire-speed INI/OUTI loops. Try the stock `z80sio` fed byte
by byte from the IOC side; otherwise replace SIO1 with a behavioural device
that models exactly the registers and lines the drivers observe (the
simulator's approach). SIO1 raises no interrupts in either OS. Exit: LINK_SYNC
and PING complete with both drivers unchanged, and the choice is recorded here.

**WP5 — IOC command core (L).** Frames (`A5 5A LEN TYPE SEQ STATUS DATA CRC`,
CRC-16-CCITT, `reply = request | 80h`, `FEh` unknown class); the command set
both OSes use: PING, RESET, LINK_SYNC, XFER_STATUS, PROFILE, HID_INPUT, the
FS2 family (CAPS through READ_RUN), the legacy FS_* commands, VOL_MOUNT and
VOL_INFO, the SD record and block commands. Bulk READY/DONE admission and
transfers up to 4 KiB. Status codes and limits as `ioc_frame.h` defines them.
Keep the lane glue (WP4) and this core apart, so a future machine with another
transport reuses the core.

**WP6 — Card backends (M).** One interface — resolve, open, read, write,
truncate, stat, directories, rename, space, generation — with two
implementations: the image through MAME's `fs::fat` (`src/lib/formats/fs_fat`;
confirm its write coverage, otherwise FatFs from the firmware's
`third_party/`), and the host folder. Volume units (CP/M `C:`/`D:`) are files
on the card mapped by extents, so both backends serve them. Raw block commands
address the image directly; the folder backend answers them as having no
volume.

**WP7 — Lane timing (S).** Pace command turnaround and bulk bytes to the
board's measurements (about 6 µs per byte on the bulk lane); `-ioc_speed fast`
removes the pacing.

**WP8 — HID keyboard (M) → B, with WP5.** MAME keyboard input as USB usages,
translated as the firmware's `translate_key` does (text, control bytes, VT100
sequences), queued with the doorbell on /CTSB. Proof: the KonaOS shell,
KonaEdit and KonaCommander arrows, the ZSDOS prompt.

**WP9 — Sound card (S) → D.** Four SN76489 (confirm the part from the
schematic: the noise taps differ by variant) and the 8-bit DAC, mixed mono.
Reads at E0h-FFh (CTRL) return FFh until WP13.

**WP10 — V9958 validation (S).** KonaOS gfxtest, GfxDemo, sntview, DonkeyKong;
the ZSDOS console. Compare sntview's exit timing lines with the board's to
calibrate the VDP command timing.

**WP11 — Developer tooling (M) → E.** A `konaos` Lua plugin: symbols from
`konaos.map`, a program's map and its `placement.json`; breakpoints by symbol;
zone and segment addresses translated to physical banks; console capture. Debug
views of the 512 KiB SRAM and the 128 KiB VRAM. `make run` in the KonaOS SDK
rules: build, place the program in a card folder, start the emulator, run it.
Save states over every device's state.

**WP12 — Acceptance and documents (M) → C, E.** Scripted runs kept in
`Emulator/tests/`, run by hand: KonaOS boot, `hwtest`, sntview playback, a
ZSDOS session over `B:` and `C:`, ZEXDOC. The documents: build and run, the
device model, and a fidelity table (exact: CPU, VDP, PSG, decoder; approximate:
IOC lane and card timing; board only: the `LD A,I` IFF2 erratum, real USB
devices). KonaOS `docs/boot.md` §9 and the SDK point here.

**WP13 — Later, with the OS features.** Gamepads and the mouse through the
same HID path, from MAME joysticks and the mouse; the CTRL reads.

## 5. Order

```
WP0 → WP1 → WP2 → WP3 (A) → WP4 → WP5 + WP6 → WP8 (B, C) → WP11, WP12 (E)
                 └→ WP9 (D), WP10, WP7 in parallel once WP2 lands
```

The critical path is WP4 → WP5 → WP6: everything a developer sees needs the
card and the keyboard.

## 6. Risks

- **The SIO1 sync model (WP4).** The behavioural SIO1 device is the fallback.
- **Behavioural drift from the firmware.** The firmware evolves; the core
  follows `ioc_frame.h` and the FS2 status codes, and the WP12 sessions on both
  OSes catch a divergence.
- **VDP command timing.** WP10 measures it against the board instead of
  assuming it.
- **Speed.** Byte-level lane glue keeps the emulator well above real time;
  bit-level SIO clocking is not attempted.
