# ColecoGo cartridge patches

These manifests are consumed by `tools/patch_cartridge.py`. Every manifest is
locked to one ROM size and SHA-256 and verifies the original bytes at every
patch site.

## Donkey Kong barrel-cadence diagnostic

`donkey-kong-half-throw-rate.json` targets the 16 KiB Donkey Kong image with
SHA-256:

```text
93f6ed7bd0d1a0ac751fbe09ce7011881939bc2f4c82d3bdfef7c617367f1ae4
```

The game initializes two repeating signals used by the Kong/barrel-throw state
machine with periods of 40 and 80 ticks. The patch doubles only those constants
to 80 and 160 ticks. It does not delay the main loop or alter barrel movement,
collision handling, NMI handling, skill selection, or the number of barrel
slots. This makes it a focused hardware test of whether excessive simultaneous
barrels are causing the observed sprite disappearance.

Build the separate diagnostic ROM with:

```sh
python3 tools/patch_cartridge.py apply \
  ../Software/disk1/8/dk.rom patches/donkey-kong-half-throw-rate.json \
  patches/DKSLOW.ROM
```

## Zaxxon 10 MHz patch

`zaxxon-10mhz.json` targets the 24 KiB Coleco/CBS Zaxxon image with SHA-256:

```text
440a043660e041ac5021df37d65ac402e121bcfa498a1cb796e0c7c91d407ab3
```

This is a whole-game timing patch rather than a fuel-only fix. A MAME trace at
the original 3.579545 MHz clock measured 6,006 cartridge
`RST 08h` dispatches over a 300-frame Skill 1 gameplay window, or approximately
20.02 dispatches per 60 Hz frame. The patch redirects the cartridge's `RST 08h`
vector from `8932h` to a 16-byte trampoline placed in verified `FFh` padding at
`DFC1h`.

One 60 Hz frame gains approximately 107,008 T-states when the CPU changes from
3.579545 MHz to 10 MHz. Dividing that surplus by 20.02 dispatches gives a target
delay of about 5,345 T-states per dispatch. The trampoline preserves AF and BC,
spends approximately 5,335 T-states in a 203-iteration delay, then jumps to the
original `8932h` dispatcher. V9958 NMI remains enabled during the delay and
continues to use the cartridge's original NMI path.

This approach deliberately throttles all cartridge `RST 08h` clients. It may
correct more than fuel consumption, so the original `ZAXXON.ROM` remains the
reference image and the patched file uses the separate name `ZAX10.ROM`.

Hardware result, 2026-09-07: `ZAX10.ROM` was tested on the fixed 10 MHz
Zephyr-80. The game was playable and fuel decreased at a normal rate. This
confirms the 203-iteration calibration for the tested ROM revision. It does not
establish that the same dispatcher strategy or delay applies to another title.

Subsequent hardware testing did not reproduce the expected slowdown. The
203-iteration result must therefore be treated as unconfirmed. Use
`zaxxon-rst08-probe.json` to diagnose the execution path before attempting a
new calibration. Its 4096-iteration loop delays every `RST 08h` dispatch by
approximately 10.66 ms at 10 MHz and is intentionally far too slow for normal
play. If `ZAXPROBE.ROM` does not crawl or stall, the running cartridge did not
execute this patched path. Do not use the probe as a playable timing patch.

Further hardware testing showed that the original 203-iteration patch could
run fast on the first game and slow down after game-over and restart. The
original trampoline delays before the dispatcher sets bit 0 at `719Eh`, so an
NMI arriving during the delay can execute the game update immediately. The
`zaxxon-10mhz-nmi-safe.json` candidate reproduces the original dispatcher
prologue first, delays while its busy flag is set, and resumes at `8939h`.
Zaxxon's existing NMI handler can then mark an update pending and service it
once through the original return wrapper instead of running through the delay.
The trampoline preserves both `AF` and `BC`; `BC` may carry arguments into the
routine selected by `IX` and must not be reused as an unpreserved delay counter.

An earlier generated test named `ZAXNMI.ROM` omitted the `BC` preservation and
crashed on hardware. It is invalid and must not be used. Regenerate the fixed
candidate from the current manifest as `ZAXNMI2.ROM`.

Hardware testing of `ZAXNMI2.ROM` showed no useful slowdown. This confirms that
the general `RST 08h` dispatcher is not a reliable game-speed throttle. The
dispatcher-delay manifests remain diagnostic history and are not recommended
as timing fixes.

An automated MAME gameplay run identified RAM byte `71ADh` as a steadily
decreasing gameplay countdown. Cartridge code at `9205h` loads that address and
decrements it. `zaxxon-10mhz-fuel.json` replaces those four bytes with a call to
a divider in the verified end-of-ROM padding. Zaxxon increments `71E1h`
immediately before this site, so the divider uses that existing value modulo 14
and permits residues 0, 3, 6, 9, and 12. This produces the repeating 3, 3, 3,
3, 2 schedule without writable state in the cartridge image. Its average
divisor of 2.8 converts the 10 MHz call rate to approximately 3.571 MHz, within
0.23% of the original 3.579545 MHz CPU clock. `BC` and `DE` are preserved, `A`
is safely dead on both outgoing paths, `HL` remains pointed at `71ADh`, and the
routine reproduces the original decrement's zero flag when it performs one.

Build the test ROM from the ColecoGo directory with:

```sh
python3 tools/patch_cartridge.py verify \
  ../CPM2.2/images/A/8/ZAXXON.ROM patches/zaxxon-10mhz.json
python3 tools/patch_cartridge.py apply \
  ../CPM2.2/images/A/8/ZAXXON.ROM patches/zaxxon-10mhz.json \
  ../CPM2.2/images/A/8/ZAX10.ROM
```

Build the deliberately slow execution-path probe with:

```sh
python3 tools/patch_cartridge.py apply \
  patches/ZAXXON.ROM patches/zaxxon-rst08-probe.json \
  patches/ZAXPROBE.ROM
```

Build the NMI-safe 203-iteration candidate with:

```sh
python3 tools/patch_cartridge.py apply \
  patches/ZAXXON.ROM patches/zaxxon-10mhz-nmi-safe.json \
  patches/ZAXNMI2.ROM
```

Build the focused fuel-counter candidate with:

```sh
python3 tools/patch_cartridge.py apply \
  patches/ZAXXON.ROM patches/zaxxon-10mhz-fuel.json \
  patches/ZAXFUEL.ROM
```
