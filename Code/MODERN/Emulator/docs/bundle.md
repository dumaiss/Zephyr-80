# Zephyr-80 emulator bundle

One archive, `zephyr80-mame-linux-x86_64.tar.xz`, runs KonaOS on the `zephyr80`
machine. It holds the MAME binary, its libraries, the `konaos` plugin, the
current KonaOS flash image and a starter card; there is no MAME source tree and
no build.

```sh
tar -xf zephyr80-mame-linux-x86_64.tar.xz
zephyr80-mame/start.sh
```

`start.sh` boots KonaOS on the card in `card/` and stops at the `/> ` prompt.
The folder can be moved anywhere, including a path with spaces.

## What is in it

| Path | What |
|---|---|
| `start.sh` | `mamepbitz zephyr80 -flash konaos.bin -carddir card`; extra arguments are MAME options |
| `mamepbitz` | MAME for this machine: a script that runs `libexec/mamepbitz` on the libraries in `lib/` |
| `konaos.bin`, `konaos.map` | the KonaOS flash image and its symbol map |
| `card/` | the starter card folder: `HELLO.EXE`, `KEDIT.EXE`, `KC.EXE`, the gamepad, mouse, sound and graphics programs and `README.TXT` |
| `plugins/` | the `konaos` plugin, MAME's `json` library plugin and its loader files |
| `ini/mame.ini` | the bundle's settings: `pluginspath`, and MAME's per-user folders under `$ZEPHYR80_STATE` |
| `lib/`, `libexec/`, `qt-plugins/` | the binary, the glibc loader, libc, libstdc++, SDL2, Qt 6 and the other libraries it loads |
| `docs/` | this guide and the device documents it links to |
| `MANIFEST.json` | every file with its size, SHA-256 and source revision; the three checkouts' revisions; the packages the libraries came from |

## Host requirements

- 64-bit Linux on x86-64, kernel 3.2 or newer, a desktop session (X11, or
  Wayland with XWayland), and the host's OpenGL driver and sound server (ALSA
  or PulseAudio). The window, the sound and the debugger need these; a run with
  `-video none -sound none` needs nothing of them.
- The glibc loader, libc, libm, libstdc++, SDL2, Qt 6, ICU, X11 and the other
  libraries `ldd` lists for the binary are in `lib/` and are used instead of the
  host's. The binary needs glibc 2.43 and libstdc++ 3.4.32 symbols, which the
  bundled libraries provide; the host's glibc can be older. Only the host's GPU
  driver and plugin libraries are loaded from the host (Mesa through GLVND), and
  those must work against a newer libc, as an older distribution's do.
- The bundle is x86-64 only. It is built with MAME's generic x86-64 flags, with
  no `-march`.
- The debugger window is Qt on X11 (`QT_QPA_PLATFORM=xcb`). With no display,
  `QT_QPA_PLATFORM=offscreen` runs `-debug` without a window.

The build host's distribution, and that the bundle starts on a host with an
older glibc, have been tested on one machine only; the manifest names the
distribution package of every library.

## Keyboard and the UI

With a window, MAME's key input goes to the guest keyboard while MAME's UI
controls are off. The host's Scroll Lock toggles them: with UI controls on, Tab
opens MAME's menu (Machine Configuration, File Manager, Input Settings) and the
function keys are MAME's; press Scroll Lock again to return the keyboard to
KonaOS. Keys are positional (US legends); Ctrl+Alt+Esc resets the machine.
[The keyboard](zephyr80-keyboard.md) has the details.

## Cards

`start.sh` mounts the folder `card/` as the SD card: files and directories with
8.3 names, seen by KonaOS as `/fs`. Copy a program (`HELLO.EXE`) or a file into
it and run `/fs/HELLO.EXE`. The card is written in place; keep a copy of the
folder to start over.

```sh
zephyr80-mame/start.sh -carddir /path/to/other/folder
zephyr80-mame/mamepbitz zephyr80 -flash konaos.bin -card sd.img
```

A FAT16/FAT32 image (`truncate -s 64M sd.img; mkfs.fat -F 16 sd.img`) works
with `-card`; the two options are exclusive. [The card socket](zephyr80-card.md)
describes both.

## Gamepads and mouse

The host mouse drives the USB mouse (connected by default). The host's first and
second joysticks drive two F310 pads, which are not connected until you set
"USB gamepad 1" and "USB gamepad 2" under Machine Configuration (Scroll Lock,
Tab). The choice is kept in `$ZEPHYR80_STATE/cfg`. `JOY.EXE` and `MOUSE.EXE` on
the card show them. [Mouse and controllers](zephyr80-input.md) has the device
and the rebinding.

## State

MAME's settings, saves and snapshots are under `$ZEPHYR80_STATE`, by default
`$XDG_STATE_HOME/zephyr80-mame` (`~/.local/state/zephyr80-mame`). The bundle's
own folders are not written, except `card/` and MAME's `ui.ini` in `ini/`.

## The debugger and the `konaos` plugin

```sh
zephyr80-mame/start.sh -plugin konaos -debug -console
```

`-debug` opens the Qt debugger, `-plugin konaos` loads the KonaOS symbols,
bank-aware breakpoints, physical SRAM and VRAM views and the console as text
(`konaos.load_os("konaos.map")`). [Debugging KonaOS programs](zephyr80-debugging.md)
describes them.

## The KonaOS SDK's `make run`

Point the SDK at the bundle with one setting:

```sh
make run KOS_MAME=/path/to/zephyr80-mame
make run KOS_MAME=/path/to/zephyr80-mame KOS_MAME_ARGS=-debug KOS_BREAK=main
```

`KOS_MAME` may name the bundle's folder: its `mamepbitz`, `plugins/` and
`konaos.bin` (with `konaos.map` beside it) are the defaults, so `KOS_FLASH` is
only needed for another image. The SDK's `docs/sdk.md` has the other variables.

## Building the bundle

From `Code/MODERN/Emulator`, with the release binary and the KonaOS programs
built (the card programs are the build outputs of the KonaOS checkout):

```sh
make -C mame SUBTARGET=pbitz BUILDDIR=build-release -j8     # mame/mamepbitz
make -C /path/to/ZephyrOS build/konaos.bin build/user/hello.exe \
  && make -C /path/to/ZephyrOS \
  && make -C /path/to/ZephyrOS/UserSoftware/KonaEdit \
  && make -C /path/to/ZephyrOS/UserSoftware/KonaCommander \
  && make -C /path/to/ZephyrOS/UserSoftware/GfxDemo
python3 tools/bundle.py --mame mame/mamepbitz --konaos-root /path/to/ZephyrOS
```

The archive is written to `tests/output/bundle/` (`--output` changes it) and its
path, size and SHA-256 are printed. The same inputs give the same archive. The
`bundle` case of [the test runner](../tests/README.md) extracts it to a path
with spaces and runs it.
