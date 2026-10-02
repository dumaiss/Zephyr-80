# Zephyr-80 MAME — Build & Run

The Zephyr-80 machine is an out-of-tree MAME **subtarget** called `pbitz`. All
custom sources live under `src/mame/pbitz/`; the machine is **not** registered in
`mame.lst` (the `zephyr` token there is the unrelated `zms8085.cpp`). It is listed
in `src/mame/pbitz/pbitz.lst` and built via its own subtarget script
`scripts/target/mame/pbitz.lua`.

All commands below run from the MAME tree root:

    cd Zephyr-80/Code/MODERN/Emulator/mame

## Build

Debug binary (recommended during bring-up — enables the `-debug` debugger and Lua
taps):

    make SUBTARGET=pbitz DEBUG=1 -j$(nproc)      # -> ./mamepbitzd

Optimised binary:

    make SUBTARGET=pbitz -j$(nproc)              # -> ./mamepbitz

### When to add `REGENIE=1`

The GENIE-generated makefiles under `build/` are only regenerated when you ask for
it. Add `REGENIE=1` **whenever a project file changes**, i.e. after editing
`scripts/target/mame/pbitz.lua` (for example, adding a new device source such as
`z80ctc.cpp`). Editing only `.cpp`/`.h` under `src/mame/pbitz/` does **not** need it.

    make SUBTARGET=pbitz DEBUG=1 REGENIE=1 -j$(nproc)

### Devices are listed explicitly

`pbitz.lua` does not pull the full MAME device set. Each device the driver uses is
named directly in its `files{}` block (`z80sio.cpp`, `z80ctc.cpp`, the `rs232`
bus, `pty`, `loopback`, …) plus `CPUS["Z80"]` and `MACHINES["Z80DAISY"]`. **If you
reference a new device, add its `.cpp`/`.h` to `files{}` and rebuild with
`REGENIE=1`**, or you will get an undefined `DEVICE_TYPE` link error.

### Gotcha: stale absolute paths after a directory rename

The generated files under `build/` bake **absolute** paths (e.g. the forced-include
`src/osd/sdl/sdlprefix.h`). If the tree is moved or renamed, the OSD/SDL layer fails
to compile with:

    fatal error: /…/<old-path>/…/sdlprefix.h: No such file or directory

Fix by regenerating the project files at the current location:

    make SUBTARGET=pbitz DEBUG=1 REGENIE=1 -j$(nproc)

or, to avoid a large rebuild, patch the stale paths in place (this tree was renamed
from `Z80HomeBrew` to `Zephyr-80`):

    grep -rlI Z80HomeBrew build | xargs sed -i 's#Z80HomeBrew#Zephyr-80#g'

### Common failure: "I rebuilt but nothing changed"

The debug binary is `mamepbitzd`; the release binary is `mamepbitz`. Confirm you
launched the one you just built (check its timestamp with `ls -l mamepbitzd`). A
stale binary is the most common source of "my fix didn't take effect".

## ROM

`ROM_START(zephyr80)` loads `roms/zephyr80/zephyr80.bin` — the current 128 KiB
CP/M firmware — into a 512 KiB ROM region. The hash in the driver pins the current
dump; if you rebuild the firmware, MAME prints a non-fatal `WRONG CHECKSUMS`
warning until the `CRC(...) SHA1(...)` line in `zephyr80.cpp` is updated. The
machine still runs with the warning.

## Run

The CP/M console and the Virtual Drip (VDrip) video/storage link share **SIO0/B**
at a fixed **115200 8N1**. Expose it as a host pseudo-terminal for the VDrip proxy:

    ./mamepbitzd zephyr80 -sio0b_rs232 pty -video none -sound none

At startup MAME prints the allocated device:

    :sio0b_rs232:pty: pseudo terminal slave /dev/pts/N

Point the VDrip proxy at that `/dev/pts/N` (open it in **raw** mode — the link is
binary, not line-oriented). Keep the default throttle (do not add `-nothrottle`) so
the serial link runs in real time. `-video none -sound none` runs headless.

`-listslots zephyr80` shows the serial ports:

- `sio0a_rs232` — user serial channel (SIO0/A), baud from the CTC.
- `sio0b_rs232` — console + VDrip link (SIO0/B), fixed 115200.

### Debugging aids

- `-debug` opens the interactive debugger (debug build only).
- `-autoboot_script foo.lua -autoboot_delay 0` runs a Lua script at start — handy
  for I/O taps, e.g. `space:install_write_tap()` on the bank latch (`$00`) or the
  SIO ports (`$20-$23`) to trace boot/console behaviour.
