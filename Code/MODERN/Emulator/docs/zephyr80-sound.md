# The sound card

The Afternoon Blend card sits at E0h–FFh (writes) on the pBITz backplane:
four SN76489AN programmable sound generators and an AD7801 8-bit DAC, summed
by op-amp stages to a stereo output. The machine models the digital side with
MAME's stock devices and mixes them to one mono speaker.

Source of truth: the KiCad schematic of the card (`Sound.kicad_sch`, exported
as a netlist), the decoder equations (`IO_DECODER.pld`) and the KonaOS driver
(`drivers/sound/`, `platform/zephyr80/public/hardware.h`). The code is in
`mame/src/mame/pbitz/zephyr80.cpp` (`sound_w`, `psg_ready_w`, the machine
configuration) and `zephyr80_map.h` (`io::SOUND_*`).

## Parts

| Reference | Value on the schematic | Device |
|---|---|---|
| U6, U7, U11, U12 | `SN76489AN`, DIP-16 sockets | `SN76489A` (`sn76489a_device`) |
| Y1 | `ECS-2100A-035`, 3.579545 MHz HCMOS oscillator, to pin 14 of each PSG | the PSG clock |
| U3 | `AD7801BRUZ` | `DAC_8BIT_R2R` (offset binary) |
| U8 | `74AHCT138` | the port decode |
| U1 | `74HC688` against the coded switch SW1 | the card select (`/CS_SOUND`) |

The `SN76489AN` marking is the SN76489A in a plastic DIP. MAME's `SN76489A` is
that part: a 16-bit-wide shift register with taps on stages D and E, output on
F, not inverted, a periodic-noise ring of 15 shifts, and the clock divided by
8 then by 2 per count (`clock / 16` counts a second). The plain `SN76489`
differs (15-bit register, inverted output): the noise tests tell them apart.
The schematic fixes the part; nothing about it is assumed.

## Data bus

The card buffers the bus through U4 (74HCT541) and wires host D7 (the MSB) to
the PSG pin the datasheet calls D0, which is the chip's MSB, and host D0 to
its D7 (LSB): pins 3, 2, 1, 15, 13, 12, 11, 10 take D7…D0. So the PSGs take
conventional SN76489 bytes (bit 7 is the latch bit, `1 rrr dddd`) exactly as
the guest sends them, which is the byte MAME's device expects; the "reversal"
the hardware header mentions is relative to the pin labels and needs no
software or emulator step. The AD7801 takes D7…D0 straight (DB7 = MSB).

## Ports

`IO_DECODER.pld` selects the card for every write in E0h–FFh. U8 decodes only
A2:A0 (with `/WR` on an enable), so the eight ports repeat four times across
the block:

| Port (A2:A0) | Writes |
|---|---|
| 0–3 (E0h–E3h, E8h–EBh, F0h–F3h, F8h–FBh) | PSG0–PSG3 |
| 4 (E4h, ECh, F4h, FCh) | the DAC |
| 5–7 | nothing (U8 Y5–Y7 are unconnected) |

Reads of E0h–FFh are the controller latches' (`/CTRL`) and not the card's: the
machine answers the latch the address selects ([mouse and
controllers](zephyr80-input.md#reading-the-latches)) and no sound device sees a
read. The card's select switch
SW1 must be set to the code the decoder drives (1110) for any of this to
work; the emulator assumes it is.

## The write stretch

A PSG write sets a latch (U5A) that holds the bus `/WAIT` low through Q1 until
the written chip's open-collector READY rises, which the chip does 32 clocks
of its input after a write (8.94 µs). The Z80 core has no `/WAIT` input
model, so `sound_w` suspends the CPU until the stock device's own READY
output rises (`psg_ready_w`, the wired-AND of the four READY pins) and the
core resumes it at that time. A write to the DAC, or to ports 5–7, is not
stretched. The stretch is what lets the driver's `OTIR` of four bytes into one PSG land
every byte. Consecutive writes to one PSG are 10.6 µs apart in the model: the
8.94 µs stretch plus 1.7 µs of the next `OTIR` iteration. The board adds a
whole iteration (2.1 µs) after READY rises, so the model is about 0.4 µs
short: it resumes the CPU at the READY edge with the `OUT`'s own cycles already
counted.

## Mix

The card's stages are inverting summers around a mid-rail reference (10 kΩ
feedback). The input resistors from the schematic give each source's weight
to each side: PSG0 and PSG1 33 kΩ to both, PSG2 22 kΩ to the left and 47 kΩ
to the right, PSG3 the reverse, the DAC 47 kΩ to both. The mono output
averages the two sides: weight = 0.5 × (10/R_left + 10/R_right), times 0.66,
the one scale that keeps four chips at full level plus the DAC at its positive
extreme under full scale (0.98).

| Source | Gain |
|---|---|
| PSG0, PSG1 | 0.2000 |
| PSG2, PSG3 | 0.2202 |
| DAC | 0.1404 |

A PSG channel at attenuation 0 is MAME's 0.25 of full scale (a chip is 1.0
with its four channels high), so one channel of PSG0 swings 0.05. The DAC is
offset binary: code 80h is zero, 00h is −1.0 and FFh +0.992 before the gain,
which is the card's AC coupling of the 0–5 V output (the DC at midscale is not
passed). The PSGs' own AC coupling is not modelled: their output is unipolar,
so a sounding chip adds a DC offset to the capture.

Not in the schematic and not modelled: the PSG's output level against the
DAC's 5 V span (taken as equal), the volume potentiometers and the output
amplifier, the high-frequency feedback filter and the stereo image (the
output is mono).

## Reset

- `/RESET` reaches the AD7801 `/CLR`: the DAC register clears to code 00h
  (−1.0 before the gain) on a machine reset and at power-on, and stays there
  until the guest writes it. The KonaOS driver parks the DAC at 80h.
- The PSGs have no reset input. A machine reset leaves their registers and
  counters as they are, and at power-on the stock device starts as the part
  does: attenuation 0 and every tone at divisor 1024, a low drone until the
  guest's reset sequence (`9Fh BFh DFh FFh` to each chip) silences it.

## Capture

`-wavwrite FILE` records the mixed output at the `-samplerate` (the tests use
192000) with `-sound none`: no host audio device is involved and the run is
bounded by emulated time. The capture's group delay against the register
events is about 16 µs.

MAME runs each PSG as a sound stream at an integer rate, half its clock rounded
down (1,789,772 Hz, 0.28 ppm slow), counting on every eighth stream sample; a
register write takes effect after the stream sample its time falls in. A
rendering of the register writes matches the capture sample for sample only on
that grid (the tests' reference uses it).

## State

The devices are stock and save their own state. The machine keeps no sound
state of its own: the stretch is the CPU's suspend, which the scheduler saves.

## Not modelled

- The analogue stage beyond the gains above: levels, filtering, noise,
  headroom of the op-amps, the output amplifier, stereo.
- The AD7801's settling and its internal reference's tolerance.
- The CE-to-READY delay (90–150 ns) and the decoder's propagation: the stretch
  starts at the write and ends at the chip's READY edge.
- The card-select switch: SW1 is taken to be set to E0h–FFh.
