# The USB mouse and the game controllers

A USB mouse and two Logitech F310 gamepads plug into the IO controller. The
controller's HID module decodes their reports. The mouse is read through the
command lane (`HID_MOUSE`, 12h); the pads and the keyboard's number keys load
two controller latches, which the Z80 reads at E0h–FFh. The machine models
that path above the HID report decode, in three parts:

- `zephyr80_usb_mouse` (`mame/src/mame/pbitz/zephyr80_usb_mouse.*`) and
  `zephyr80_usb_gamepad` (`zephyr80_usb_gamepad.*`, two instances), the
  devices: MAME input to 7-byte mouse reports and 8-byte F310 reports.
- `zephyr80_ioc_hid` (`zephyr80_ioc_hid.*`), the controller's HID module: the
  firmware's report decode, the mouse's accumulators, the pad slots and
  `HID_STATUS` pages 6 and 7. The [protocol core](zephyr80-ioc-core.md) owns it
  and serves `HID_MOUSE` and the pages from it; the
  [transport](zephyr80-sio1-ioc.md) mounts the devices and feeds it reports.
- `zephyr80_controller_latch` (`zephyr80_controller_latch.h`), the two latches
  (`controller_latch.c`), and the read decode of E0h–FFh in `zephyr80.cpp`.

The specification is the controller firmware (`Code/MCU/IOController`):
`src/ioc_hid.c` (`tuh_hid_mount_cb`, `tuh_hid_umount_cb`,
`tuh_hid_report_received_cb`, `hid_mouse_take`, `hid_host_task`,
`coleco_keypad_for_report`, `gamepad_unmount`), `src/controller_latch.c`
(`controller_latch_f310_report`, `controller_latch_keypad`,
`controller_latch_release`), `src/handlers.c` (`handler_hid_mouse`,
`handler_hid_gamepad_page`, `handler_hid_other_page`) and
`include/ioc_frame.h`; for the read decode, the IO board's netlist. No
firmware runs; the PIC, the MAX3421E, the hub, USB enumeration, the 74AHC595s'
SPI shift and the F310 below its report are not modelled.

## The mouse

The firmware's mouse is the **second HID interface of the keyboard's dongle**:
`tuh_hid_mount_cb` returns early for an interface of the boot mouse protocol,
gives the first protocol-0 interface to the keyboard and keeps the next one
(`other_addr`), whose reports it decodes only when they are 7 bytes with ID 02h:

| Byte | Meaning |
|---|---|
| 0 | 02h |
| 1 | buttons: D0 left, D1 right, D2 middle |
| 2–4 | X and Y as two 12-bit signed fields: X's low byte, then X's high nibble with Y's low nibble above it, then Y's high byte |
| 5 | wheel, signed |
| 6 | horizontal scroll (the model sends 0) |

The module (`tuh_hid_report_received_cb`, `hid_mouse_take`) keeps, per report:

- the buttons held, and `pressed` OR-ed with the buttons that were not held in
  the previous report, so a click shorter than the read interval still shows;
- running totals of X, Y and wheel that wrap at 16 bits (HID_STATUS page 7);
- the motion since the last read, added with a cap: dx, dy and wheel stay in
  ±32767 (the sum clamps, never wraps and never reaches −32768);
- the decode flag, set by the first well-formed report.

`HID_MOUSE` answers flags (D0 an interface is mounted, D1 reports decode),
buttons held, buttons pressed, then dx, dy and wheel (16-bit little endian)
since the last read, and **takes**: it clears `pressed` and the three motion
accumulators; the held buttons and the totals stay. With no mouse every field
is zero. A report that is not ID 02h with 7 bytes is counted and kept raw (page
7) and decodes to nothing. Removing the interface clears the buttons, the
decode flag and the pending motion and keeps the totals; a controller reset
clears everything. Nothing here queues a keyboard byte or rings `/CTSB`, and
there is no interrupt.

### The device

MAME's host mouse reaches the device as three analog fields (X, Y, wheel, each
a 16-bit position that wraps, so the motion is the difference of two scans;
+Y is down, as in the report) and three buttons. Once a frame, after MAME's
input update, the device adds that frame's motion to what a mouse holds between
polls: a motion total per axis, bounded at ±32767 like the firmware's own, and
the button states in the order seen (a ring of eight; beyond that the newest
is replaced). The controller polls it in its idle pass: each `poll` builds one
report with the oldest button state and at most ±2047 of X and Y and ±127 of
wheel, so a long throw arrives whole in several reports and a press and release
inside one idle gap arrive as two reports. A mouse reports only on change: a
connected mouse that has neither moved nor been pressed sends nothing and the
decode flag stays clear. A click shorter than a frame is invisible to MAME's
input, which samples once a frame.

## The gamepads

Each pad is a Logitech F310 in DirectInput mode, an 8-byte report:

| Byte | Meaning |
|---|---|
| 0, 1 | left stick X, Y (80h neutral; 00h left or up, FFh right or down) |
| 2, 3 | right stick (80h) |
| 4 | D3:D0 the hat (0 up, clockwise to 7 up-left, 8 none); D4 X, D5 A, D6 B, D7 Y |
| 5 | D0 LB, D1 RB, D2 LT, D3 RT, D4 Back, D5 Start, D6 L3, D7 R3 |
| 6, 7 | 0 |

The firmware decodes it (`controller_latch_f310_report`) into the ColecoVision
controller byte, active low (a bit is low when pressed):

| Bit | Meaning |
|---|---|
| D0 / D1 / D2 / D3 | up / right / down / left |
| D6 | fire |
| D5:D4 | high |
| D7 | low (the byte reads 7Fh idle) |

Priority, first match: Back is star (nibble 09h), Start is pound (06h), X is
keypad 1 (0Dh), Y is keypad 2 (07h); otherwise the hat's eight directions;
with no hat direction, the left stick (the Mode LED's d-pad), left or up below
40h and right or down above C0h. A or B (`report[4] & 60h`) clears D6 in every
case, so the keypad keys carry the second fire. The bumpers, triggers, stick
buttons and the right stick change nothing. A report shorter than six bytes is
refused and the latch keeps its value.

An idle pad and an absent pad both read 7Fh; there is no presence bit.

### Slots and polling

A mounted F310 takes the first free of the two slots (the first pad mounted
is pad 0 whichever MAME pad it is). The firmware polls each pad every
`GAMEPAD_POLL_MS` (10 ms) after its last report, a poll served in the idle
pass, and the pad answers with its state at that instant; the model polls the
same way, so a keypad key from the keyboard that outranked the stick is
overwritten by the pad's state within a poll when released. A pad removed frees
its slot and parks its latch at 7Fh (`controller_latch_release`); a held
keyboard keypad code stays held, as in the firmware.

### The keyboard's number keys

Every keyboard report also sets port 0's keypad code (`coleco_keypad_for_report`,
after the reset-combination test and before translation): the first slot that
is a number-row digit or a keypad digit gives 0–9, keypad `*` and Shift+8 give
`*`, Shift+3 gives `#`, any other shifted key gives nothing, and an empty report
releases the code. The key is not consumed: the digits still reach the console
queue. The code replaces the direction nibble of port 0 and outranks the stick
on every pad report; the high nibble (fire) stays the pad's. It works with no
pad attached. Port 1 never takes the keyboard.

### The device

Every F310 field is a digital MAME input: the D-pad and the left stick are four
directions each (the stick at full deflection, which the firmware's dead zone
treats as an analog throw) and the twelve buttons. Opposite directions cancel.
The report is the current state of the fields when the controller polls.

## Host bindings

The machine has three configuration settings ("Machine Configuration" in
MAME's Tab menu, kept in MAME's configuration file):

| Setting | Default |
|---|---|
| USB mouse | Connected |
| USB gamepad 1 | Not connected |
| USB gamepad 2 | Not connected |

A device that is not connected is not mounted. Changing a setting while the
machine runs mounts or unmounts the device at the next frame.

The bindings are MAME's own, set in the Input (this Machine) menu; the
defaults follow the host's first and second joystick as MAME's SDL game
controller layout gives them:

| Field | Default host input |
|---|---|
| mouse X, Y, wheel | the host mouse (relative axes and the scroll wheel; sensitivity 100, wheel one report unit per notch) |
| mouse left, right, middle | the host's buttons 1, 3, 2 |
| D-Pad | the hat |
| Left Stick | the X and Y axes as switches |
| A, B, X, Y | buttons 1, 2, 3, 4 |
| LB, RB, Back, Start, L3, R3 | buttons 5, 6, 7, 8, 9, 10 |
| LT, RT | none |

Pad 1 follows host joystick 1, pad 2 joystick 2. No pad field has a keyboard
default, so nothing a pad does reaches the keyboard's keys. MAME enables its
mouse device class for this machine because the mouse fields are mouse controls;
`-mouse` also makes it hide the host pointer over the window (SDL's
`should_hide_mouse`), and the mouse motion is what the guest sees either way.

## Reading the latches

IO_DECODER.pld sends a read of E0h–FFh to `CTRL`. On the IO board a 74HC138
(U6) takes `/CE_CTRL` on E0 and `/RD` on E1 and has only its A0 input wired to
the bus (A1 and A2 are tied to ground), so Y0 enables pad 0's 595 and Y1 pad
1's: **bus A0 selects the pad and every other address line is ignored**. All 32
addresses of the block therefore read a latch: even addresses pad 0, odd
addresses pad 1. The ports the KonaOS `joy` driver reads, FCh and FFh, are
pad 0 and pad 1 under this decode and under the ColecoVision A1 decode alike;
the two differ at the other thirty addresses (the schematic says A0; the
decode is one constant, `CONTROLLER_SELECT_MASK`, in `zephyr80_map.h`).

Writes to E0h–FFh are the sound card's and read nothing of the latches; a read
touches no sound device. The ColecoVision keypad/joystick mode-select writes
(80h–9Fh and C0h–DFh) decode to nothing on this board: the latch presents one
merged byte and there is no mode to switch, so those writes change nothing.

## HID_STATUS

Page 0 (see [the USB keyboard](zephyr80-keyboard.md#hid_status)) counts every
mounted device in its device count. Pages 6 and 7 are the module's live state
(`hid_host_gamepad_state`):

- page 6: the number of live devices among the stack's two non-hub addresses (the
  keyboard's dongle is address 1, a pad takes the next free of 2 and 3), the
  mount and unmount counts, the last device's address and VID/PID (F310
  046D:C216; the dongle's are unknown, FFFFh), the HID mount count, the last
  HID address and protocol, and per slot the address, instance, first-arm
  result, report count, last report length and latch byte; an empty slot reads
  address 0 and first arm FFh;
- page 7: the second interface's address, instance, report count, last
  length and first eight raw bytes, the buttons held, and the X, Y and wheel
  totals.

## State

Save-registered: the module's device counters, the pad slots (address, first
arm, report count, length, next poll), the latches and keypad codes, the second
interface, the mouse's totals, buttons, decode flag, pending motion and presses
(the `hid.*` items of the IO controller); each pad's slot (`m_pad_slot`); the
mouse's last field positions, motion owed, button ring and last states; each
device's connection as of its last scan. Mounting follows the devices' scans
only, so a state restored while a device is connected keeps it mounted. A state
restored onto the same host input continues exactly; one restored with the mouse
moved since the save sees that motion at the first scan.

A reset (machine reset, `CMD_RESET`, Ctrl+Alt+Esc) restarts the controller: the
totals, accumulators and latches clear and every connected device mounts again
at its first scan. A button held across a reset is reported once by the new
mount. MAME releases keys when its window loses focus; the mouse buttons and
pad fields are MAME input levels, so a button MAME sees released is released at
the next scan, and the model holds nothing beyond those levels.

## Using it

The headless harness drives the same fields (`harness.mouse`, `harness.pad`;
[tests](../tests/README.md)). With a window, MAME's host mouse and joysticks do
it. KonaOS clients bind the mouse (`mouse_open`) and the pads (`joy_open`)
whether or not a device is attached: `tui_mouse_enable` shows the text pointer
at the centre of the screen as soon as it binds, so a program that enables the
mouse shows a pointer with no mouse mounted; `HID_MOUSE` then reports flags 0
and zero motion, and a pad that is absent reads 7Fh.

## Not modelled

USB enumeration and its timing (a device connects at the next frame), hubs,
the TinyUSB limit of two non-hub devices (the model mounts a keyboard and both
pads together), low-speed devices, boot-protocol mice (the firmware ignores
them), several mice, the horizontal scroll, the pad's right stick, triggers
and rumble, the 595s' SPI shift (a latch value is on the port as soon as the
module sets it), the F310's own report timing, and the USB poll interval (a
mouse report reaches the module at the controller's next idle pass; a pad is
asked every 10 ms). Clicks shorter than a host frame never reach the model.
