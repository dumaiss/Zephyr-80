# ColecoGo cartridge patches

These manifests are consumed by `tools/patch_cartridge.py`. Every manifest is
locked to one ROM size and SHA-256 and verifies the original bytes at every
patch site.

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

Build the test ROM from the ColecoGo directory with:

```sh
python3 tools/patch_cartridge.py verify \
  ../CPM2.2/images/A/8/ZAXXON.ROM patches/zaxxon-10mhz.json
python3 tools/patch_cartridge.py apply \
  ../CPM2.2/images/A/8/ZAXXON.ROM patches/zaxxon-10mhz.json \
  ../CPM2.2/images/A/8/ZAX10.ROM
```
