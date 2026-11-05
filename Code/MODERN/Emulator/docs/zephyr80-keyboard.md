# The USB keyboard

A USB keyboard plugs into the IO controller, which translates its boot
reports into terminal bytes, queues them and rings `/CTSB` on SIO1/B; the
Z80 fetches them with `HID_INPUT`. The machine models that path above the HID
usages, in two parts:

- `zephyr80_usb_keyboard` (`mame/src/mame/pbitz/zephyr80_usb_keyboard.*`), the
  keyboard: MAME key fields to boot reports.
- `zephyr80_ioc_hid` (`zephyr80_ioc_hid.*`), the controller's HID module: the
  firmware's report handling, translation, repeat and input queue. The
  [protocol core](zephyr80-ioc-core.md) owns it and serves `HID_INPUT` and
  `HID_STATUS` from it; the [transport](zephyr80-sio1-ioc.md) feeds it
  reports and runs its repeat.

The specification is the controller firmware (`Code/MCU/IOController`):
`src/ioc_hid.c` (`translate_key`, `tuh_hid_report_received_cb`,
`hid_host_task`, `input_reserve`, `hid_input_get`, `hid_host_usb_state`,
`keyboard_reset_combo`), `src/handlers.c` (`handler_hid_input`,
`handler_hid_status`), `src/main.c` (the idle pass), `include/ioc_frame.h` and
TinyUSB's `HID_KEYCODE_TO_ASCII` table (`third_party/tinyusb/src/class/hid/hid.h`).
No firmware runs; the PIC, the MAX3421E, the hub and USB below the usages are
not modelled.

## Keys to reports

The keyboard device (`:ioc:keyboard`) has one input field per HID usage:
keys 04h–65h in ports `KEYS0`–`KEYS6` (bit b of `KEYSn` is usage n·16 + b) and
the eight modifiers E0h–E7h in `MODIFIERS` (bit b is the report's modifier
bit b). Each field defaults to MAME's positional key code for that key (US
legends), so the host's layout, its text translation and its key repeat never
reach the guest. Non-US # (32h) and Scroll Lock (47h) have no default host key:
the host's Scroll Lock toggles MAME's UI controls.

Once a frame, after MAME's input update, the keyboard scans its fields. When
the held keys change it sends an 8-byte boot report: the modifier byte, a
reserved zero, then up to six usages in the order they were pressed; with
more than six keys held every slot reads 01h (ErrorRollOver). A boot keyboard
reports only on change, so a held key sends nothing more. The report is the
live input state, not a stream of host events: a key MAME sees released is
released in the next report, and nothing in the device outlives MAME's view
of a key. MAME reports every key released while a UI menu holds the input,
and a key let go while the window has no focus is released as soon as MAME's
key state says so. After a machine reset the keyboard is
enumerated again and its next scan reports the keys held then; after a state
load the saved held keys stand until the next scan reconciles them with the
live input.

## The controller's HID module

Reports reach the HID module only in the controller's idle pass:
`hid_host_task` runs between services (`main.c`), so a report that arrives
while a command is served waits for the service's end. A newer report
replaces one still waiting. The module's millisecond clock is the firmware's
`tusb_time_millis_api`: 10 ms timebase ticks counted from the controller's
reset.

Report handling (`tuh_hid_report_received_cb`, keyboard branch):

- Either Ctrl plus either Alt with Escape in any slot latches the reset
  request, and nothing else of that report is taken. The transport then drops
  READY and resets the machine (`handler_reset`, the 10 ms hold of
  `CMD_RESET`).
- Only usages absent from the previous report are translated, in slot order,
  with that report's modifier byte. Usages 01h–03h never are.
- The last newly pressed key other than CapsLock, NumLock and Scroll Lock
  takes over the repeat, due 500 ms (`REPEAT_DELAY_MS`) after the clock of
  its report. A report without the repeat key ends the repeat; one with it
  re-samples the modifiers, so Shift pressed mid-repeat changes what repeats.

Translation (`translate_key`):

| Input | Bytes |
|---|---|
| CapsLock, NumLock | toggle the lock and the LED report (NumLock on, CapsLock off at power-on and at every mount); no byte |
| Ctrl + A–Z | 01h–1Ah |
| Ctrl + `[` `\` `]` `6` `-` | 1Bh 1Ch 1Dh 1Eh 1Fh |
| Ctrl + 2, Ctrl + Space | 00h |
| keypad 7 8 9 4 6 1 2 3 0 . with NumLock off | `ESC [ H`, `ESC [ A`, `ESC [ 5 ~`, `ESC [ D`, `ESC [ C`, `ESC [ F`, `ESC [ B`, `ESC [ 6 ~`, `ESC [ 2 ~`, `ESC [ 3 ~` |
| letters | the table's lower or upper case: Shift inverted by CapsLock |
| digits, punctuation, Enter, Escape, Backspace, Tab, Space, keypad digits and operators | the table (US: `1`/`!` … `/`/`?`; Non-US # gives `#`/`~`; Enter CR; Backspace 08h; keypad Enter CR); a zero entry (Shift + keypad digit) falls through to the keypad's digit |
| Up Down Right Left Home End | `ESC [ A` `B` `C` `D` `H` `F` |
| Insert Delete PageUp PageDown | `ESC [ 2 ~`, `3 ~`, `5 ~`, `6 ~` |
| F1–F4 | `ESC O P` … `ESC O S` |
| F5–F12 | `ESC [ 15 ~` `17` `18` `19` `20` `21` `23` `24 ~` |
| Print Screen, Scroll Lock, Pause, Non-US \, Application, GUI, Alt alone | nothing |

Alt and GUI change no translation. Ctrl with any other key falls through to
the table (Ctrl + Up is `ESC [ A`).

Repeat (`hid_host_task`): at the first idle pass on or after the due tick the
repeat key is translated again with its modifiers and the next repeat is due
60 ms (`REPEAT_PERIOD_MS`) after the tick it ran at; a late pass (a long
service) moves the phase. A repeat is translated only while the queue holds
fewer than 64 bytes (half its size), so a key held with nothing draining
stops at 64 bytes and costs no drop; a 3-byte key can pass 64 once. The
transport sets a timer for the due tick.

## The queue and the doorbell

The queue holds 128 bytes (`HID_INPUT_QUEUE_SIZE`). A key's translation is
admitted whole or not at all (`input_reserve`): a sequence that does not fit
is refused and counts one drop, and the drop count saturates at FFh. `/CTSB`
is asserted while the queue holds anything and released when it empties; it
is a level, so a guest that samples late still sees it, and a partial dequeue
leaves it asserted.

`HID_INPUT` (0Eh) dequeues up to the request's DATA 0 bytes, at most 24, and
answers `queued`, `dropped`, then the bytes (`handler_hid_input`); DATA 0 = 0
is a status-only query. A controller reset (a machine reset, `CMD_RESET`,
Ctrl+Alt+Esc) empties the queue, clears the drop count and releases `/CTSB`.

## HID_STATUS

Page 0 (`handler_hid_status`) keeps the bring-up fields at the values of a
controller that probed nothing: status NOT_STARTED, revision 0, `/USB_INT`
idle, the probe results zero. The live USB fields (`hid_host_usb_state`)
describe the emulated keyboard: one device, the keyboard's address (1), the
reports received since its mount, the last report (modifier, reserved, six
usages) and full speed (00h); the device count includes any mounted pad. Pages
6 and 7 are [the mouse's and the pads'](zephyr80-input.md#hid_status).

## State

Save-registered: the queue, its indexes, count and drop count; the keyboard's
mount, report count and last report; the locks and the LED report; the
repeat key, its modifiers and due time; the reset request (`hid.*` items of
the IO controller); the transport's waiting report and clock origin; the
keyboard device's held keys in press order and its last report. A state
restored with the same key held continues its repeat at the saved phase; one
restored with the key up releases it at the first scan.

## Using it

The machine always has the keyboard; MAME's key input goes to it whenever
MAME's UI controls are off (toggled with the host's Scroll Lock). Function
keys reach the guest only then. In the Lua harness, `harness.keyboard` sets
and clears the fields through MAME's input path ([tests](../tests/README.md)).

## Not modelled

USB enumeration and its timing (the keyboard is mounted when the controller
resets; a key held through a reset is reported at once), the LED output
report's transfer (the state is kept), low-speed devices behind the hub, the
MAX3421E and its interrupt, the USB poll interval (a report reaches the
controller at the next idle pass), several keyboards, a keyboard unplugged.
The keypad mirror of the number keys onto controller port 0
(`coleco_keypad_for_report`), the mouse and the gamepads are in [the mouse and
controllers](zephyr80-input.md).
