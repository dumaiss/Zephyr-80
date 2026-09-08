# Build configuration

**These files are required to build. They are not images and not disposable.**

| File | What needs it |
|---|---|
| `diskdef` | cpmtools disk geometry for the ROM A: volume. `tools/build_rom_disk.py` stages it next to the image as `diskdefs`, because cpmtools looks for that name in the working directory before falling back to `/etc/cpmtools/diskdefs`. |
| `banks.ini` | ROM bank payload map. `tools/build_zephyr_image.py` uses it to place the ROM disk pages and other payloads in the 256 KiB image. |

They used to live in `images/`, alongside a generated staging tree and an 8 MiB
working volume that genuinely *was* disposable. Deleting that directory as
leftover therefore broke the build, which is a bad property for a directory name
to have. Build inputs live here; generated output lives in `build/`.
