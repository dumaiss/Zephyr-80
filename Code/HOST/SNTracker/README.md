# SNTracker

SNTracker is the initial native music-tracker architecture for the Zephyr-80
Afternoon Blend sound card. It is a CP/M transient program for a 10 MHz Z80 and
four independently selected SN76489AN PSGs. The player has 16 fixed logical
channels; it does not allocate or steal voices dynamically.

```text
channel = 00-0F
chip    = channel >> 2       (SN0-SN3 at E0h-E3h)
voice   = channel & 3        (Tone 0, Tone 1, Tone 2, Noise)
```

The source of truth for the ports and write behavior is the existing Zephyr
`platform_zephyr80.inc` and `SNDTEST`/Afternoon Blend implementation. Software sends conventional SN76489
bytes—there is no software-side data-bit swap—and keeps the conservative
bring-up delay after each write. The card is write-only and has no PSG reset,
so SNTracker mutes all four chips before and after playback.

## Architecture

```text
CSM -> csmc parser/semantics -> logical timeline -> SN76489 backend -> ZTR
                                                         |
                                                         v
UI scaffold <- tracker/player state <- sparse ZTR decoder
                                                         |
                                                         v
                                          SN76489 driver -> PSGs
```

The Furnace parser is host-only. The player deals in notes, instruments,
volumes, effects and macros. Only `sn76489.asm` encodes hardware latch/data
bytes. `ui.asm` reads logical state and has no sound-register knowledge.

`ztr_init`, `ztr_load`, `ztr_play`, `ztr_stop` and `ztr_tick` are explicit
assembly entry points. CTC0 runs near 180 Hz and a phase accumulator derives
the ZTR tick rate; the supplied 60 Hz song is an exact divide-by-three case.
The ISR only publishes pending ticks. Row parsing, macro work, disk I/O, UI
output and PSG writes occur in foreground code.

## Build

The build uses the same SDCC ASxxxx tools as the existing CP/M host projects:

```sh
make
```

This produces:

- `build/SNTRACK.COM`
- `songs/night-market.ztr`
- `songs/RunawayCircuit.ztr`

The converter and checked-in Furnace source are also usable independently:

```sh
python3 tools/fur2ztr.py songs/night-market.txt songs/night-market.ztr
python3 tools/fur2ztr.py --validate songs/night-market.txt
python3 tools/fur2ztr.py --dump songs/night-market.ztr
python3 tools/fur2ztr.py --strict songs/night-market.txt songs/night-market.ztr
```

A CSM source compiles directly to ZTR in one process. The compiler does not
write JSON IR or Furnace text intermediates:

```sh
python3 tools/csmc.py songs/RunawayCircuit.csm songs/RunawayCircuit.ztr
```

If the output path is omitted it defaults to the source name with a `.ztr`
suffix. `--dump` prints the decoded result after the compiler's mandatory
encode/decode round-trip check. `--allocation-report` shows every logical
layer-unit assignment or optional spill. `make csm-song` builds the supplied CSM score.
The integer-only language and current backend contract are documented in
`docs/CSM-Language.md`.

CSM patterns support exact-tick note durations, ties, envelope-preserving
legato pitch changes, persistent per-tick arpeggios/trills, and persistent
crescendo/diminuendo hairpins. These are compiled directly into compact ZTR
events; they do not depend on Furnace effect syntax.

The project Makefile passes `--transpose 24` for the supplied TI-99 song. Set
`TRANSPOSE=0` when building a source whose note periods already match the
Afternoon Blend clock, or pass a different `--transpose` value directly.

`--validate` parses, encodes, bounds-checks and decodes without writing an
output file. `--dump` displays metadata, instruments, the complete 16-channel
order list and every decoded sparse event. Unsupported Furnace effects are
reported with order, row and channel; `--strict` makes any warning fatal.

Run the self-contained host tests with:

```sh
make test
```

## Playing Night Market

Copy `build/SNTRACK.COM` and `songs/night-market.ztr` to a CP/M disk, using an
8.3 destination such as `NIGHT.ZTR`, then run:

```text
SNTRACK B:NIGHT.ZTR
```

Press `Q` or Escape to stop. The compact status UI shows order, elapsed
`Tmm:ss`, and the unexpected
interrupt count. It refreshes once per pattern block (about every 6.4 seconds);
playback and effects continue at the song's full tick rate. It is deliberately
a playback scaffold, not yet an interactive pattern editor.

Night Market is a one-SN76489 Furnace song. Its four source channels map to
Zephyr channels `00h`-`03h` (physical SN0); the other 12 channels remain
silent. The importer also accepts two, three or four SN76489 instances when
their order list contains the corresponding 8, 12 or 16 channels.

## Furnace compatibility in this milestone

The converter reads song information, sound-chip declarations, instruments,
volume/pitch/arpeggio/noise/phase-reset macros, the first subsong's tick rate,
speed, pattern length, orders and pattern rows. It distinguishes a note OFF
from macro release (`===`). The Night Market effects implemented by the player
are:

- `00xy`: arpeggio
- `0Axy`: volume slide
- `EAxx`: legato mode
- `F9xx`: one-tick volume decrease
- `FAxy`: fast volume slide
- `FFxx`: song stop

Furnace dev233 ADSR and LFO generator slots are translated on the host into
ordinary native ZTR sequences. That preserves instrument timing, loops and
release points without putting Furnace's packed generator representation or
runtime multiplication in the Z80 player. Fixed arpeggio steps are retained,
which is important for SN noise instruments.

The generated note-divisor table uses the song's tuning (`A4=405 Hz` for Night
Market) and the 3.579545 MHz Zephyr PSG clock. Pitch macros use signed
1/128-semitone values. The current Z80 renderer applies a bounded linear period
approximation for fine pitch while arpeggios use exact semitone-table entries.

Night Market's TI-99 Furnace target uses a divided PSG clock. Its reference VGM
writes divisor 465 for the opening `C-2`; that same divisor sounds as `C-4` on
Afternoon Blend's direct-clock SN76489AN. The ZTR header therefore records a
+24-semitone target transpose and the generated divisor table applies it. Sparse
events and the UI retain the source note names.

Noise is not treated as an independent pitched oscillator. A noise rate of 3
continues to mean “clock from this PSG's Tone 2,” and the driver makes that
coupling explicit.

## Runtime memory and current limits

This first player loads a whole ZTR file rather than streaming it:

| Range | Use |
| --- | --- |
| `0100h`-approximately `1523h` | CP/M transient code and static state, including the fallback ISR at `1515h` |
| `5E00h`-`5F00h` | 257-byte application-local IM2 vector table |
| `6000h`-`AFFFh` | ZTR buffer (20 KiB maximum) |
| `BFF0h` downward | private stack |

The IM2 setup mirrors the existing BIOS SIO handler from `DD10h`, following the
standalone VGMPlayer convention. The extra table byte makes the `FFh` vector
fetch across the IM2 page boundary safe without touching the ZTR buffer at
`6000h`. It does not alter the BIOS image or global BIOS timing. A future
integration should replace this application-local hookup with an exported
platform timing service if one becomes available.

The Night Market ZTR is 20,234 bytes. That is larger than 20,000 decimal bytes
but remains 246 bytes below the 20 KiB (20,480-byte) buffer limit. Its final
rounded CP/M record ends at `AF80h`, below the `B000h` limit.

Other current limits are intentional:

- ZTR v1 files are at most 65,535 bytes, while this CP/M player accepts at most
  20 KiB.
- The player accepts tick rates up to its 180 Hz CTC base rate.
- Only the effects listed above are implemented.
- Furnace grooves with multiple speed values, additional subsongs, non-SN
  chips and multiple effect columns are not implemented.
- Fine pitch magnitudes above 63/128 semitone are saturated by the initial Z80
  renderer.
- The UI is read-only and relies on the configured CP/M console; it does not
  access V9958 ports directly.

## Project layout

- `src/tracker.asm`: CP/M entry point, foreground loop and application CTC/IM2
  hookup.
- `src/ztr.asm`: bounded CP/M file loader and ZTR header/section validation.
- `src/player.asm`: sparse row decoding, channel state, effects and macros.
- `src/sn76489.asm`: fixed 16-channel mapping and dirty-only PSG rendering.
- `src/ui.asm`: four-channels-at-a-time status UI.
- `tools/csmc.py`: direct CSM-to-ZTR compiler and SN76489 backend.
- `tools/csm_language.py`: CSM lexer, parser and semantic validation.
- `tools/fur2ztr.py`: Furnace text importer, ZTR encoder/decoder and CLI.
- `tools/test_fur2ztr.py`: host-side parser/round-trip/error tests.
- `tools/test_csmc.py`: direct compiler and language-semantic tests.
- `docs/CSM-Language.md`: complete CSM authoring guide and backend reference.
- `docs/ZTR-Format.md`: byte-precise ZTR v1 specification.
- `songs/RunawayCircuit.csm`: supplied integer-semantics CSM score.
- `songs/RunawayCircuit.ztr`: direct compiler output and hardware stress song.
- `songs/night-market.txt`: supplied Furnace text export.
- `songs/night-market.ztr`: generated example song.

## Next milestones

The compiler now performs priority-aware allocation and accepts backend-owned
extension blocks. The next work is hardware playback comparison of the newly
allocated Runaway Circuit build, followed by additional target backends when a
concrete platform is selected.
