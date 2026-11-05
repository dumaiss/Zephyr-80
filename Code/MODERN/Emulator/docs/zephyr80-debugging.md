# Zephyr-80 MAME — Debugging KonaOS programs

The `konaos` Lua plugin (`mame/plugins/konaos`) gives the zephyr80 machine
KonaOS symbols, breakpoints that stop only in a symbol's physical bank, views
of all of SRAM and VRAM, the console as text, and the KonaOS SDK's `make run`.
It ships with the emulator: `-plugin konaos` loads it from MAME's `plugins/`
directory (`-pluginspath` names another), and nothing else in the machine
depends on it.

```sh
./mamepbitzd zephyr80 -flash "$KONAOS_ROOT/build/konaos.bin" -carddir card/ \
  -plugin konaos -debug -console
```

`-console` opens MAME's Lua console, where the plugin is `konaos`; scripts reach
it as `emu.plugin.konaos`.

## Symbols

| Call | Result |
|---|---|
| `konaos.load_os(map)` | the nucleus's symbols from `konaos.map` |
| `konaos.load_program(map)` | a program's symbols from `build/user/<name>/<name>.map`, with `place/placement.json` (the home zone's areas), the EXE manifest `<name>.json` (the segment rows) and `../<name>.exe` beside it |
| `konaos.find(spec)` | every symbol the spec names |
| `konaos.where(spec)` | one symbol: image, zone, logical address and the physical addresses it occupies now, or why it has none |
| `konaos.here()` | the image and symbol at the stopped PC (`phys(pc)` and the nearest symbol below it in that bank) |

Every symbol keeps its owner: the image (`konaos` or the program's name), the
module and the zone. A program's zone follows its area: the home areas are
`home`, a segment's areas `far<n>` (FAR_CODE row n) or `data<n>` (a mappable
DATA row), every other area `resident`. The nucleus's zone follows its address:
`nucleus` (2000h–DFFFh, bank 7: the fixed core and the mode-11 window at P = 0),
`common` (E000h–FFFFh, bank 0) and `caller` (0000h–1FFFh, the calling
process's bank in mode 11, so no one physical bank).

Names:

- `image:name` searches that image only; a bare name searches every loaded
  image.
- An exact name wins; when no image in the scope has it, `_name` (the C symbol)
  is tried, so `main` finds `_main`.
- More than one match, in two images or at two values in one, is an error
  listing every candidate (`kos_entry is ambiguous: bankbp:kos_entry …;
  hello:kos_entry …; name it as image:symbol`). Nothing is chosen silently.
- Absolute symbols (area sizes and starts, bank ids) are found but take no
  breakpoint, and neither does a `caller`-zone nucleus symbol.
- A missing map, placement, manifest or EXE, and a placement whose home area the
  map lacks, are errors naming the file; a missing EXE only warns
  (`konaos.diagnostics`) and leaves the program's banks unknown.

## Banks and breakpoints

The loader chooses a program's banks at run time, so the plugin finds them in
memory. At every launch (the nucleus's `kos_process_launch`, whose request
names the child's bank; `kernel/include/process.h`) it compares the launched
bank with each loaded program's resident code from its EXE, and the aperture
slice (8000h) of banks 0–5 with the program's far and mappable segments.
`konaos.locate(name)` does the same at once. A copy left in a freed bank can
match too, which is harmless: no code runs there until a launch replaces it.

`konaos.bp(spec[, action])` sets a debugger breakpoint at the symbol's logical
address with the condition `phys(pc) == <physical>`, one term per bank the
image was found in, and returns the record (`index`, `condition`, `phys`,
`text`). Before the program is loaded the breakpoint is pending (`pending`
says why) and is set at the launch that loads it, before its first
instruction. `konaos.bpclear([record])` removes one or all.

`phys(a)` is the machine's debugger function, registered with `-debug`: the
board decoder (`zephyr80_map::decode`) applied to logical address `a` and the
current latch, giving SRAM `bank << 16 | a`, or 80000h plus the flash address in
mode 00. It reads nothing, so it moves no latch and clears no device status.
Any debugger expression can use it (`bpset 8000,phys(pc)==58000`). The
condition is why a far segment's code and the home zone at the same logical
address, or another program's code there, never trigger each other's
breakpoint: the `debug-symbols` case shows a home function at 18000h and a far
function at 58000h, both at 8000h, each stopping only in its own bank (the far
one with the mode-10 aperture open), while a plain `bpset 8000` stops in
banks 6, 1 and 5.

## Physical memory

| View | What |
|---|---|
| debugger memory window `memory/:/0/:sram` | the 512 KiB SRAM share, physical address = bank × 10000h + address, every bank whatever the latch maps |
| `dump file,58000:sram.s,100` (also `save`, `load`, `find`, `fill`) | the same share in debugger commands |
| debugger memory window `:vdp vram space`, `dump file,10000:vdp,100` | the V9958's 128 KiB, as the chip stores it (GRAPHIC6/7 interleaved) |
| `konaos.sram(phys[, n])`, `konaos.vram(addr[, n])` | the same from Lua; Lua also has `manager.machine.memory.shares[":sram"]` |

None of these reads goes through a port: the latch and the VDP status
registers are unchanged.

## The console

`konaos.console.read()` returns the V9958 console's 26 rows as text: cells
matched against the font the image ships (its ROMFS `v9958.mod`, read from the
`-flash` file), read from VRAM and the saved registers without a port access.
`find(text)`, `text()` and `printable(row)` help scripts;
`capture(path[, every])` appends every changed screen with its emulated time to
a file, `stop()` ends it. `konaos.keys.queue(text)` types on the USB keyboard
through MAME's input path (US legends, Shift as needed), one change a frame;
`konaos.keys.idle()` reports when it is done.

## `make run`

The KonaOS SDK's `make run` (its `docs/sdk.md`, "Running in the emulator")
stages a program into a card folder and starts this machine with `-carddir`,
`-plugin konaos` and `KONAOS_SESSION` naming a session file. The session
(`session.lua`) waits for the shell prompt on the console, sets the session's
breakpoints (pending until the launch), types `/fs/<NAME>.EXE` and its
arguments, waits for the prompt to return and writes the program's screen lines
to the result file; `exit 1` ends MAME then. A stop at one of its breakpoints
is reported as `konaos: stopped at <image>:<symbol> (…)`.

## Save states

Every device's state is save-registered and restores in a fresh process; host
resources are never saved and are rebuilt or refused on load.

| Device | State | Handling |
|---|---|---|
| Z80 | registers, IFFs, halt, suspend (the PSG READY stretch) | stock |
| SRAM, latch | the `sram` share (512 KiB), `m_latch` | saved |
| Flash | the host `-flash` image | not copied: its length and SHA-1 are saved and compared on load; other contents are a fatal error |
| CTC, SIO0, daisy chain, `/INT`, V9958 latch | stock CTC and SIO0, `m_vdp_int`, `m_vdp_config` | saved; the RS232 slot's host pty is not state |
| SIO1 lanes | registers, FIFOs, pipes, hunt, CRC, RTS/CTS/DCD/sync | saved |
| IO controller | transport phase, window, reply, bulk buffer, counters, the timer (scheduler), HID epoch, pending report | saved |
| Protocol core | FS2 tokens, cookies, positions, resolver, generation, `/SHARED`, volumes, transfers, staged writes, chunk/block/record buffers, HID queue, held keys, repeat, mouse totals, buttons and pending motion, pad slots, controller latches | saved |
| USB keyboard | held keys, last report | saved; MAME's host key levels are input, not state |
| USB mouse, gamepads | the mouse's last field positions, motion owed, button ring; each device's connection as of its last scan; each pad's slot | saved; MAME's host mouse and joystick levels are input, not state |
| Card socket | session, mount, the 16 objects, FatFs's volume and FIL/DIR objects | saved without pointers ([card socket](zephyr80-card.md#save-states)); the media's identity is saved and compared on load |
| V9958, VRAM | stock chip, 128 KiB | saved |
| PSGs, DAC | stock | saved |

A state is restored with `-state NAME` (with the media given as when it was
saved) or `manager.machine:load(NAME)`. Restoring onto media that differ from
those saved, or with another flash image, ends MAME with a fatal error naming
both identities (exit status 3); nothing saved is replayed onto changed
media. The `save-restore` case saves idle at the prompt, mid-command,
mid-bulk, mid-write and while a program runs the timer, the console and the
PSGs, on a card image and a card folder, and restores each in a fresh process:
the run ends exactly as the saving run did.
