# Serial console fallback

Status: implemented and working on hardware.

A second CP/M console on SIO0/B that runs **alongside** the selected backend, so
a dark V9958 does not leave the machine unreachable. Output is mirrored; input
is switched by a gesture typed at the terminal.

## What it does

| | |
|---|---|
| Output | `CONOUT` goes to the backend first, then to the serial port when the tee is armed. |
| Input | Switched, not merged: either the USB keyboard or the serial port owns `CONST`/`CONIN`. |
| Takeover | Three ESCs from the terminal toggle input ownership **and** arm the tee. |
| Default | Tee off, input on the keyboard. |
| Control | `SERCON [ON|OFF]` on the rescue disk. |

The port needs no setup: `sio_core_init()` already configures SIO0/B as async
8N1 with RX and TX enabled in every build, and the baud clock is a dedicated
oscillator feeding the SIO directly, so nothing here touches SIO registers.

## Cost

| | |
|---|---:|
| Code | 291 bytes at `F760h`-`F882h` (driver slot 5) |
| State | 5 bytes at `FE78h`-`FE7Ch`, plus an 8-byte ring with the code |
| Slot 5 free after | 560 bytes, largest fragment 539 |
| PIC RAM | **none** |

That last row is the one that mattered when this was scoped: the FAT32 work
budgets against the **PIC's** 12,800-byte data space, and this is entirely
Z80-side. The two features do not compete.

## Design decisions

### Switched input, not merged

A merge would need `CONIN` to poll two blocking sources — awkward, and it lets a
connected-but-idle terminal, or noise on a cable someone just plugged in, type
into a running program. Takeover is something the operator does on purpose.

### The takeover is a toggle

Three ESCs switch input to serial; three more hand it back. A one-way takeover
would leave the USB keyboard dead until reboot, which is a poor property for a
tool whose entire purpose is recovering from a bad state.

`CONIN` re-reads the ownership flag on every pass of its wait loop, so the
gesture works even while something is blocked waiting for input. Without that,
handing control back would be ignored until the next unrelated `CONIN`.

The two ESCs that precede the third are dropped from the ring on takeover: the
sequence is a command, not input.

### The tee defaults OFF, and this is not a preference

`sio_send_byte`'s console path waits for `SIO_CONSOLE_TX_READY`, which is
TX-buffer-empty **AND** `/CTS`. With no terminal attached `/CTS` never asserts,
so each character would burn the full `SIO_CONSOLE_TIMEOUT` — `FFFFh` loop
iterations, on the order of a second. The boot banner alone would take about a
minute, and the machine would look hung.

Two things prevent that:

- the tee is off until something arms it, and
- `sercon_tx` tests `/CTS` itself before calling the helper, so an absent
  terminal costs three instructions per character rather than a timeout.

The `/CTS` test is not an assumption about the wiring. `sio_core.asm` already
folds `/CTS` into its own ready mask, so this port's existing design already
treats that signal as meaningful.

### Why `SERCON.COM` exists

The ESC gesture can arm the tee but cannot usefully disarm it once the terminal
is gone, and it cannot arm the tee *before* a session to capture boot output.
`SERCON OFF` also clears input ownership: if serial had taken over `CONIN` and
you disarm from the keyboard side, leaving that bit set would strand input on a
port nobody is watching.

It writes `SERCON_FLAGS` at `FE78h` directly. That address is fixed across
builds because the state block sits above the SIO core state in either
configuration (v9958 ends at `FE74h`, vdrip at `FE76h`). No extended-BIOS entry
was added: that table is full, ending at `DA48h` with shadow-copy code
immediately after at `DA4Bh`, so appending one would mean relocating boot code
for no benefit.

`SERCON.COM` is on the **normal** rescue profile, not the diagnostic one. It is
a rescue tool by definition.

### Input pacing instead of flow control

`IOCBULK` masks interrupts for a whole transfer — roughly 3 ms for a 512-byte
record — during which the RX sink cannot run and the SIO's 3-byte FIFO is the
only buffer. At 115200 that is about 35 character times.

Typing survives that easily. Pasting does not, and the mitigation is to pace the
terminal rather than to add RTS watermark logic to the BIOS. That is why the
ring is eight bytes and there is no flow control: it covers ISR latency, not a
burst. This is a pre-existing property of the port, not something the tee
introduced — it is why the old `cbios_console_sio.asm` had RTS watermarks.

### Not built in a VDrip build

Two reasons. A VDrip build **is** a host-serial console already — VDrip talks
over this same SIO0/B — so a fallback would be redundant. And slot 5 has no room
in that build: the transport occupies `F680h`-`F908h` with the storage backend
after it.

## Composite driver table

The console facade dispatches through `CONSOLE_DRIVER`, a pointer to seven
entries. Rather than modify the facade — which is packed against its neighbours
and says so — this installs a composite table whose `const`/`conin`/`conout` are
wrappers and whose remaining four entries are **copied verbatim from the backend
at init**, so `list`/`punch`/`reader`/`listst` cost no indirection at all.

`sercon_init` runs from cold boot after `console_backend_cold_init` (it copies
the backend's table, so the backend must be up) and before `boot_print_banner`
(so a terminal that armed the tee earlier sees the boot messages).

## Warm boot rebinds, and why

CP/M warm-boots after every transient program, and warm boot undoes the
installation twice over:

- `console_init()` resets `CONSOLE_DRIVER` to the backend's own table, dropping
  the composite table and with it the tee;
- `sio_core_init()` clears `SIO0B_RX_SINK`, unregistering the sink.

So `wboot` calls `sercon_install`, which rebinds both **without** touching the
armed flags. Calling `sercon_init` there instead would disarm the tee the first
time you ran a command — precisely when you would be relying on it.

This was the first field failure: the gesture appeared to arm the tee, but
control never actually moved, and serial keystrokes were lost.

## `CONIN` polls the backend, never blocks in it

The first version tail-called the backend's blocking `CONIN` when the keyboard
owned input. That meant the ESC gesture could not take over while CP/M sat at a
prompt: the backend was already blocked inside its own wait on the HID queue, so
the toggle did not take effect until someone pressed a key on the USB keyboard —
which is exactly the situation the fallback exists for.

It now polls the backend's non-blocking `CONST`, re-checking the ownership flag
each pass, and enters the backend's `CONIN` only once a character is known to be
waiting. The serial side already re-read the flag in its wait loop; the keyboard
side needed the same treatment.

## The backend's CONST is a flush, not just a query

`v9958_console_conout` only appends to a print run; `v9958_console_const` is
what flushes it to the screen, and says so in its own comment: characters stay
invisible until the next `CONST`.

The first version's `sercon_const` returned the serial answer *without* calling
the backend at all when serial owned input, and the serial wait loop did the
same. That froze the V9958: typed characters were invisible there until enough
output accumulated to overflow the run buffer and flush itself, which is why
short echoes vanished while whole messages appeared.

Both paths now call the backend's `CONST` unconditionally and discard its answer
when serial owns input. Answering from the right source is this routine's job;
deciding the backend does not need to run is not.

The general shape of the mistake -- twice now -- is treating a backend entry
point as a pure query when it also carries a side effect the console depends on.
`CONIN` had the mirror-image problem: treating it as callable when it blocks.

## `/CTS` and the terminal emulator

Bring-up hit a symptom worth recording, because the shape of it is the useful
part: `tio` reported occasional disconnect/reconnect, terminal *input* was
perfectly reliable, terminal *output* was missing pieces, and the V9958 and USB
keyboard never faltered.

That asymmetry is diagnostic. Input arrives through the ISR sink and does not
depend on `/CTS` at all; output is gated on it. A genuine USB re-enumeration
would break both. Something that only drops RTS -- a terminal program closing
and reopening the port -- breaks only output.

**Root cause: the terminal emulator.** The same hardware and firmware behave
perfectly under TeraTerm. Nothing on the Zephyr side was at fault, and the
diagnostic counters added while chasing it have been removed.

One change was kept, because it is worth having regardless: `sercon_tx` waits
`SERCON_CTS_WAIT` (~3 ms) for `/CTS` rather than dropping instantly. Long enough
to ride out a port that closes and reopens, short enough that an armed but
unplugged tee stays usable. The full `SIO_CONSOLE_TIMEOUT` of about a second per
character is what it exists to avoid.

## Still open

- **Whether the blocking tee is fast enough under sustained output.** At 115200
  a character is ~87 µs, the same order as the V9958 takes to render a glyph, so
  blocking has not been a problem in use. If rendering turns out much faster,
  sustained output would throttle to ~11.5k chars/s and a small TX ring would be
  worth the bytes. Measure before adding one.
- That the boot banner reaches a terminal armed with `SERCON ON` beforehand.
