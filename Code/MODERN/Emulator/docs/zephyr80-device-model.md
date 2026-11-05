# Zephyr-80 MAME — Device model and fidelity

The `zephyr80` machine is a developer tool for the current board: it runs the
unchanged KonaOS and ZSDOS images, shows the V9958, plays the sound card,
reads a USB keyboard and serves an SD card. Its model is copied from the
board's schematics, PLD equations and the IO controller's firmware source, or
is a stock MAME device for the part the schematic names. It makes no claim
to match the board's timing. The physical board and its deployed PLD and
controller firmware are the reference; where the two disagree, the board is
right and the emulator is wrong.

## Machine

| Block | Device | Code | Document |
|---|---|---|---|
| CPU | stock `Z80` at 10 MHz | `zephyr80.cpp` | this page |
| Memory decode, latch | Rev 13 `MEM_DECODER.pld`, `zephyr80_map::decode` | `zephyr80_map.h`, `zephyr80.cpp` | [build and run](build-and-run.md#memory-decode) |
| Flash | `-flash` image device, read-only, up to 512 KiB | `zephyr80_flash.*` | [build and run](build-and-run.md#images-and-operation) |
| SRAM | 512 KiB, the `sram` share | `zephyr80.cpp` | [debugging](zephyr80-debugging.md#physical-memory) |
| CTC, SIO0 | stock `Z80CTC`, `Z80SIO`; RS232 slots on SIO0/B | `zephyr80.cpp` | [build and run](build-and-run.md#clocks-and-interrupts) |
| `/INT`, `/NMI`, daisy chain | composed in the machine; stock acknowledge | `zephyr80.cpp`, `z80daisy.cpp` | [build and run](build-and-run.md#clocks-and-interrupts) |
| SIO1 | behavioural External Sync x1 lanes | `zephyr80_sio1.*` | [SIO1 and the IO controller](zephyr80-sio1-ioc.md) |
| IO controller | transport, protocol core, HID module | `zephyr80_ioc*.*` | [SIO1 and the IO controller](zephyr80-sio1-ioc.md), [protocol core](zephyr80-ioc-core.md) |
| SD card | `-card` image (the firmware's FatFs) or `-carddir` folder | `zephyr80_card*.*`, `zephyr80_fatfs.c` | [card socket](zephyr80-card.md) |
| USB keyboard | boot reports from MAME key fields | `zephyr80_usb_keyboard.*` | [USB keyboard](zephyr80-keyboard.md) |
| USB mouse, gamepads, controller latches | mouse and F310 reports from MAME input; the latches read at E0h–FFh | `zephyr80_usb_mouse.*`, `zephyr80_usb_gamepad.*`, `zephyr80_controller_latch.h`, `zephyr80.cpp` | [mouse and controllers](zephyr80-input.md) |
| V9958 card | stock `V9958`, 128 KiB VRAM, the card's latch | `zephyr80.cpp` | [V9958 card](zephyr80-video.md) |
| Sound card | four stock `SN76489A`, `DAC_8BIT_R2R`, mono mix | `zephyr80.cpp` | [sound card](zephyr80-sound.md) |
| `konaos` plugin | symbols, bank breakpoints, console text, `make run` | `mame/plugins/konaos` | [debugging](zephyr80-debugging.md) |

The IO controller is behavioural: it reproduces what the Z80 observes at
SIO1 (registers, lines, frames, replies and their effects on the media) from
the firmware's source. No PIC is emulated and no firmware runs. A USB mouse
and two F310 gamepads feed the controller's HID module; the Z80 reads the
mouse with `HID_MOUSE` and the controller latches at E0h–FFh
([mouse and controllers](zephyr80-input.md)).

## Fidelity

Evidence for each item:

- **copied** from a schematic netlist, a PLD equation or the firmware's
  source, with the source named;
- **stock**: MAME's own device for the part the schematic names;
- **inferred lower bound**: the smallest value with which a guest that works
  on the board also works here;
- **provisional**: a stated value no board record gives;
- **not modelled**.

Question numbers refer to the owner question list (`ZephyrOS/work/MAME-OWNER-QUESTIONS.md`).

| Item | Evidence | Basis and limits |
|---|---|---|
| Z80 instruction set and flags | stock | MAME `z80_device`. ZEXALL 67/67 on ZSDOS (a superset of ZEXDOC: the same tests without its undocumented-flag mask); `zexall` runs the binary in `mame/src/zexall/zexall.h`, `zexdoc` runs ZEXDOC.COM where it is supplied ([tests](../tests/README.md#acceptance)) |
| CPU clock 10 MHz | copied | CPU board Y1, net `CLK_10M` |
| `/WAIT` states (the LunchCrema WAIT generator, the V9958's own `/WAIT`) | not modelled | by design: they fix board timing margins; the CPU is never held by a VDP access (question 17). The PSG READY stretch is modelled (below) |
| `LD A,I` / `LD A,R` IFF2 after an interrupt (the Z84C0020 erratum) | not modelled | board only: MAME's core returns IFF2; guests that repeat every IFF read are checked on the board |
| Memory decode, latch, mirrors, reset | copied | `MEM_DECODER.pld` Rev 13 equations; 8192 mappings checked against them and the KonaOS simulator's `MemoryDecoder(13)`; no WinCUPL vectors exist in the HDL tree. PLD propagation not modelled |
| Flash | copied (capacity, decode) | any image of 1–524288 bytes, FFh padding; programming commands and timing not modelled |
| CTC channel order and trigger clocks | copied | IO board netlist: channel = A0·2 + A1; 1.8432 / 3.6864 / 7.3728 / 7.3728 MHz from the 14.7456 MHz 74HC4040 chain. Trigger edge polarity and divider phase not modelled |
| CTC and SIO0 registers | stock | MAME `z80ctc`, `z80sio`; SIO0/B 115200 from `CLK_1M8432`, SIO0/A on TO0 |
| Daisy order, `/INT` wired-OR, V9958 to `/INT` or `/NMI` | copied | IO board, CPU board and LunchCrema netlists; acknowledge stops at the first device in service (`z80daisy.cpp`); propagation delays not modelled |
| SIO1 registers and lines | copied | the KonaOS driver's register use and the firmware's lane handling (`external_sync.c`, `bulk_channel.c`); byte granularity: `/SYNC` inside a character, receive CRC, parity and SIO1 interrupts not modelled |
| IO controller frames, classes, statuses, bulk lifecycle | copied | firmware `ioc_frame.h`, `dispatch.c`, `handlers.c`, `fs2.c`, `fs_share.c`, `volume.c`, `bulk_channel.c` (normal profile, CRC bypass); diagnostic profile and power handshake not modelled |
| Command-lane byte period 20 µs | provisional | at least the KonaOS request loop's 17.5 µs; no board record (question 4) |
| Reply guard 200 µs, bulk admission guard 100 µs, bulk byte from the Z80 24 µs | copied | firmware constants (`EXTSYNC_REPLY_GUARD_US`, `BULK_ADMISSION_GUARD_US`, `BULK_RX_TARGET_BYTE_US`); not board-measured (question 7) |
| Bulk marker/header bytes 18 µs, payload bytes 9 µs to the Z80 | inferred lower bound | from ZSDOS's bulk reader working on the board (the firmware targets are 7 µs and 6 µs); question 5 |
| Controller request handling and card access time | not modelled | zero; a 512-byte read is about 4 ms faster than the board's SDBENCH (question 6) |
| `-ioc_speed fast` | emulator option | clocks each byte when the Z80 can take it; same replies and media |
| FAT volume on a card image | copied | the firmware's FatFs R0.15 and `ffconf.h`, unmodified; `fatmap_resolve` for CP/M volume files |
| Host-folder card | emulator semantics | FatFs's results over 8.3 host names; no card blocks: `SD_READ` answers a blank block 0, other raw access fails (question 1) |
| SD card, SPI, the controller's write-back cache, card-detect timing | not modelled | writes reach the host file at once; a swapped card is noticed at its first failing access, as the firmware does (question 2) |
| Keyboard translation, repeat, queue, doorbell | copied | firmware `ioc_hid.c` (`translate_key`, report edges, 500/60 ms repeat on 10 ms ticks, 128-byte queue, `/CTSB`) and TinyUSB's key table |
| USB enumeration, MAX3421E, real USB devices, poll interval | not modelled | board only: the keyboard mounts with the controller reset; HID_STATUS page 0 reports no controller probe (question 9) |
| Mouse report decode, accumulation, saturation, take and clear | copied | firmware `ioc_hid.c` (`tuh_hid_report_received_cb`, `hid_mouse_take`), `handlers.c` (`handler_hid_mouse`); 7-byte dongle reports, motion capped at ±32767, presses latched until read |
| F310 report to controller byte, keypad priority, the keyboard's number keys on port 0 | copied | firmware `controller_latch.c`, `ioc_hid.c` (`coleco_keypad_for_report`); 10 ms pad poll in the idle pass |
| Reads of E0h–FFh (the controller latches) | copied | `IO_DECODER.pld` (`CTRL`), the IO board's U6 74HC138: bus A0 selects the pad (FCh and FFh as the ColecoVision A1 decode would; the other thirty addresses differ: question 26); ColecoVision mode-select writes decode to nothing |
| HID_STATUS pages 6 and 7 | copied | `handlers.c` page layouts over the module's live state; device VID/PID of the dongle unknown |
| Mouse and pad devices, host bindings | emulator semantics | MAME's relative mouse and joystick inputs as the report fields; a motion total and a button ring bound what a device holds between polls; the connection is a machine configuration |
| Real USB mice and pads, enumeration, hubs, the device limit | not modelled | board only: the board's two-device TinyUSB limit (a keyboard and two pads together) is not enforced (question 27); pad and mouse timing beyond the 10 ms poll |
| V9958 registers, modes, sprites, palette, command engine | stock | MAME `v9958_device`, 21.477272 MHz, NTSC 59.92 Hz. Short commands complete earlier than the engine's own table (a 6×8 glyph HMMM 26 µs against 95 µs; question 14) |
| V9958 port decode, interrupt latch | copied | `IO_DECODER.pld`, LunchCrema netlist (A0h–BFh, A2 write = latch) |
| Video output levels, overscan, NTSC artefacts | not modelled | board only; the frame is the digital bitmap |
| PSG part and clock | stock, part copied | schematic `SN76489AN` ×4 at 3.579545 MHz; MAME `sn76489a_device` (noise sequence matched). MAME runs it as a stream at the integer rate 1,789,772 Hz (0.28 ppm below half the clock) with a count every 8 samples, so its tones are that much flat; far inside a crystal's tolerance |
| Sound ports, mirrors, READY stretch | copied | `IO_DECODER.pld`, U8 decode on A2:A0, the READY `/WAIT` latch (the stretch ends on the stock device's READY); whether the board has the READY generator fitted and SW1 at 1110 is question 11 |
| Mix gains | copied | schematic input and feedback resistors |
| PSG level against the DAC span | provisional | taken as equal (question 12) |
| AD7801 reset code | provisional | cleared to code 00h by `/RESET` (question 10) |
| Analogue stage (filters, op-amp headroom, AC coupling of the PSGs, stereo, output amplifier) | not modelled | board only; mono output |
| Save states | emulator | every device's state; the flash and card media by identity (questions 18, 19) |

## Board-only checks

These are checked on the board, not here:

- the `LD A,I` IFF2 erratum and any guest workaround for it;
- real USB devices, hubs and enumeration;
- analogue audio and video output;
- electrical timing: PLD propagation, WAIT states, the IO controller's
  measured lane and card timing (questions 4–7, 14, 15).

## Timing

Emulated time is the Z80's clock. Every lane and card delay is in the
[delay table](zephyr80-sio1-ioc.md#the-controllers-command-transport) with its
evidence, and the VDP and console comparisons with the board's recorded
figures are in [the V9958 card](zephyr80-video.md#timing-against-the-board).
None of these is a board match: a program's speed here is a guide, and a
timing-sensitive result needs the board.
