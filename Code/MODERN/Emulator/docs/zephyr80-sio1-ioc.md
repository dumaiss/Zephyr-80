# SIO1 and the IO controller

SIO1 is the link to the IO controller (IOC). Both channels run External Sync
x1 lanes that the controller clocks: channel B is the command lane (ports
32h data, 33h control), channel A the bulk lane (30h/31h); A3:A2 mirror them
across 30h–3Fh. Both guests poll SIO1 with its interrupts disabled.

The machine models SIO1 as a behavioural device, `zephyr80_sio1`
(`mame/src/mame/pbitz/zephyr80_sio1.*`), and the controller as
`zephyr80_ioc` (`zephyr80_ioc.*`) with its transport-independent protocol
core `zephyr80_ioc_core` (`zephyr80_ioc_core.*`, described in
[The IO controller's protocol core](zephyr80-ioc-core.md)). SIO0 is MAME's stock
`z80sio`. The specification is the KonaOS IOC driver
(`ZephyrOS/drivers/ioc/ioc_boot.c`, `ioc_io.asm`, `ioc.c`,
`platform/zephyr80/public/hardware.h`) and the controller firmware
(`Code/MCU/IOController`: `src/main.c`, `src/external_sync.c`,
`src/bulk_channel.c`, `src/handlers.c`, `include/ioc_frame.h`,
`include/external_sync.h`). No
firmware runs, and nothing below the lane pins (the PIC, SPI2, the clock
gates, USB, the card) is modelled.

## Why SIO1 is not the stock z80sio

The stock device has no byte path: a received character exists only after
RxC edges (`receive_data()` is empty, `queue_received()` is protected) and a
transmitted one leaves only as TxD bits on TxC edges. Fed one byte per burst
of eight x1 clock edges, its lane probes show:

| Probe | Stock behaviour | Contract |
|---|---|---|
| `/DCDB`, `/CTSB` to RR0 D3/D5, Reset External/Status | correct, latched | pass |
| Preload A5h, WR0 C0h, WR5 6Ah | TX buffer full, EOM latch reset, `/RTSB` low | pass |
| Request bytes on TxD | `07 28 D5 1A 00 60 …`; the frame appears only at bit offset 3, after a WR6 sync character (`00 A5 5A 03 00 0C …`) | fail: needs a bit-level deserializer |
| Underrun fill | WR6 (00h) | the guest programs WR7 |
| WR5 68h with `/RTSB` low | released at once | the board holds it while TX is enabled (harmless to the guests) |
| External Sync Hunt | ends on the inactive (high) `/SYNC` level | fail: polarity and level |
| Enter Hunt with `/SYNC` held | resynchronises with no edge | fail: the board needs a fresh falling edge |
| Receive pipeline, 3-deep FIFO | one character held back; a fourth overwrites | pass |
| RR1 after ordinary characters | CRC/framing error with RX CRC disabled | differs |

Meeting the contract would take bit-level clocking or changes to the generic
device's synchronous receive and transmit, so SIO1 alone is replaced.

## Register and line contract

What the KonaOS driver programs and observes, what the firmware does at the
other end, and what the model does.

| Item | KonaOS driver | Firmware | Model |
|---|---|---|---|
| WR0 18h channel reset | once at boot (`ioc_hw_init`, `ioc_io_bulk_init`) | — | receiver off and hunting, FIFO and pipeline empty, transmitter off, EOM latch set, `/RTS` released, WR1 = WR5 = 0 |
| WR0 pointer | D2:D0, the next control write is that register | — | as the chip; the command bits D5:D3 and D7:D6 act in the same write |
| WR0 10h Reset External/Status | before every `/DCD` or `/CTS` sample | — | RR0 D3/D5 follow the lines again; a line change latches them |
| WR0 30h Error Reset | around the receive arm and its drain | — | clears RR1 D5 (overrun) |
| WR0 C0h Reset Tx Underrun/EOM | after the preload (B); after the last payload byte (A) | — | clears RR0 D6 |
| WR0 80h Reset Tx CRC | before the bulk lead-in (A) | — | Tx CRC zeroed |
| WR1 00h | interrupts and WAIT/READY off | — | stored; a nonzero value is logged; no interrupt exists |
| WR4 30h | External Sync, x1 | — | the one mode modelled; another value is logged |
| WR6/WR7 | B: WR7 FFh fill; A: both AAh | — | the transmitter's underrun fill is WR7 |
| WR3 (B) C0h, D1h, C1h | disabled at boot; D1h (enable, Enter Hunt) after a request until a CRC-verified reply; C1h after | — | enabling or Enter Hunt starts Hunt; Hunt ends on a falling `/SYNC` edge; disabling ends assembly |
| WR3 (A) C9h, D9h, C1h | enabled at boot; D9h until the first verified bulk packet | — | as B; RX CRC is not modelled |
| WR5 (B) 68h, 6Ah, 00h | TX on, preload A5h, RTS on, the packet, two FFh trailers, 00h releases | `/SIO1B_INT` is `/RTSB`: a held request level | `/RTS` follows D1; with TX enabled, clearing D1 keeps it low; disabling TX releases it, marks the line and drops the buffer |
| WR5 (A) E0h, E9h, EBh | idle; TX with Tx CRC, RTS off/on | RTS is the host's "in the read loop" / "go" | as B; Tx CRC (CCITT, wire order) accumulates the bytes sent |
| RR0 D0 | receive available | — | FIFO non-empty |
| RR0 D2 | before every data write | — | buffer empty and no CRC byte pending |
| RR0 D3, `/DCDB` | COMMAND_READY, waited 8 × 65535 polls | asserted while idle; dropped from accepting a request to the end of its service | the IOC drives it |
| RR0 D5, `/CTSB` | the HID doorbell (`ioc_status`) | asserted while the HID queue holds bytes | the IOC drives it from the HID module's input queue ([the USB keyboard](zephyr80-keyboard.md)) |
| RR0 D3, `/DCDA` | read admission | asserted before the clock gate opens | the IOC drives it: asserted from admission to the end of a transfer to the Z80 |
| RR0 D5, `/CTSA` | write admission and phase active | held for the transfer | the IOC drives it: asserted from admission until the bytes are clocked |
| RR0 D4 | — | — | Hunt |
| RR0 D6 | the bulk write waits for it after WR0 C0h | — | set on underrun, transmitter disable and reset |
| RR1 | — | — | D0 All Sent (always, a synchronous mode), D5 overrun |
| Data reads | drain at most 4 (FIFO + 1), then scan up to 160 (B) or 8 (A) bytes for `A5 5A` | a trailing FFh after every reply stays in the SIO's pipeline | assembled characters wait one character time before the 3-deep FIFO; a fourth overwrites the last; an empty FIFO rereads its last byte |
| `/SYNCB` | — | released, then dropped inside the first reply's establishing byte; held low until LINK_SYNC | the IOC drives it |

## The controller's command transport

COMMAND_READY is asserted while idle. A request is `/RTSB` found low while
idle: READY drops and the controller clocks the 36-byte request window
(`EXTSYNC_RX_WINDOW_BYTES`): FFh towards the Z80, the SIO's transmitter
captured. It then requires `/RTSB` released, finds the request
(`zephyr80_ioc_core::decode`: the first position holding a whole packet with
an admitted class, a zero STATUS and a valid CRC, as `external_sync.c`
`packet_at` checks) and dispatches it. After the reply guard it clocks the
reply: while the lane is not yet synchronised, first the disposable
establishing byte and the falling `/SYNCB` edge, then `A5 5A … CRC`, then one
trailing FFh that moves the CRC's low byte into the FIFO. READY returns when
the service ends; a request still asserted then is served again, as the
firmware's level test does. A window with no valid request, or a request not
released within the bound, gets no reply.

| Delay | Value | Basis |
|---|---|---|
| command-lane byte | 20 µs | provisional. The firmware's target is 16 µs (`EXTSYNC_TARGET_BYTE_US`) plus its per-byte overhead; the KonaOS request loop (175 T-states a byte, one transmit buffer) works on the board, so the board's period is at least 17.5 µs, and 16 µs underruns it here. No record gives the board value |
| reply guard | 200 µs | `EXTSYNC_REPLY_GUARD_US` |
| `/RTSB` release bound after the window | 1 ms | the firmware bounds it by a loop count; not derived |
| bulk admission guard | 100 µs | `BULK_ADMISSION_GUARD_US` |
| bulk marker, header and CRC bytes, to the Z80 | 18 µs each | lower bound inferred from ZSDOS working on the board; calibrate with the board measurement of the bulk packet's byte spacing. The firmware's target is about 7 µs (`bulk_send_packet_byte`: 4 µs of SPI clocking, a 2 µs gap, the call). ZSDOS's marker scan calls a one-byte helper that costs 11.1 µs a byte, so a faster wire byte builds a backlog behind the 17 µs of setup before its payload loop that the 3-deep FIFO and the pipeline cannot hold; 11.1 µs plus 6 µs of margin, rounded up. The establishing byte of an unsynchronised lane gets the same |
| bulk payload byte, to the Z80 | 9 µs | lower bound inferred from ZSDOS working on the board; calibrate likewise. The firmware's target is 6 µs (`BULK_TARGET_BYTE_US`). The same reader takes its first payload byte 21-26 µs after it arrives (INI poll phase 4-9 µs, then 17.2 µs of setup) against a cover of four payload periods, so the period is at least 6.6 µs; with one period of cover as margin (4P - P >= 26.3 µs) it is 9 µs |
| bulk byte from the Z80 | 24 µs | `BULK_RX_TARGET_BYTE_US`, every byte of the window (length + 27 bytes: the packet, the 16-byte marker search and slack) |
| wait for `/RTSA`, and for its release between a run's packets | 500 ms | `BULK_HOST_READY_TIMEOUT_MS` |
| CMD_RESET to the machine reset | 10 ms | `handler_reset` |
| request detection, decoding, dispatch, media access (backend latency) | 0 | no record separates the card's access time from the lane and the controller's request handling |

Admission overhead is the guards (reply, bulk), the byte time is length
dependent (the byte rows), and backend latency is the last row. A command
exchange is the 36-byte request window, the reply guard and the reply, about
1.3 ms for a short reply at 20 µs a byte. A 512-byte read is that exchange,
the admission guard and 4.8 ms of bytes; a 512-byte write is that exchange and
the 539-byte window at 24 µs, about 13 ms.

Each reply comes from the core: the classes and their replies are in
[The IO controller's protocol core](zephyr80-ioc-core.md), the media behind
them in [the card socket](zephyr80-card.md). CMD_RESET answers
nothing and resets the machine after its hold. A machine reset resets the
controller with the board: no service in flight, both `/SYNC` lines released,
READY asserted.

## The bulk transport

A reply that arms a transfer (READY) is followed by its bulk phase on SIO1/A
before READY returns (`bulk_channel_run_if_armed`). The controller waits for
the host's `/RTSA` (the KonaOS read and write paths assert it once they are in
their loops), then asserts `/CTSA`, and `/DCDA` too for a transfer to the Z80,
and waits the admission guard. Towards the Z80 it clocks, while the lane is not
synchronised, a disposable byte and the falling `/SYNCA` edge (held low from
then on until LINK_SYNC), then the packet and one flush byte, and drops both
lines. From the Z80 it clocks the capture window (FFh towards the Z80), drops
`/CTSA` and hands the window to the core, which checks the packet and runs the
commit. A FS2_READ_RUN's further packets each wait for `/RTSA` to be released
and asserted again. A host that never asserts `/RTSA` (or never releases it
between packets) ends the phase; the core records BULK_NO_HOST. The service,
the commit included, ends before READY returns, so a following DONE query sees
the backend's effect.

## Pacing: `-ioc_speed`

`-ioc_speed paced` (the default) clocks every byte on its period in the table
above. `-ioc_speed fast` clocks a byte as soon as the other end can take it:

- to the Z80, when the receive FIFO has room (`lane_rx_room`);
- from the Z80, when its transmitter holds a character (`lane_tx_loaded`);
- the SIO reports data port accesses (`lane_data_event`), so a waiting byte is
  clocked one microsecond after its counterpart is ready.
  A slot never takes less than that yield, so a polling guest always runs.

A request window keeps its 36 slots: a slot with no byte loaded waits its
deadline, so the reply starts as late as it does paced. A guest arms its
receiver after it releases the request (WR3, the error reset, the stale-byte
drain), and that takes longer than the reply guard alone when a timer interrupt
lands in it; the window's unused slots are the margin.

A slot whose counterpart is not ready is clocked at a deadline: one period
after the last byte for a character from the Z80, five periods for a character
to the Z80 (what a paced lane gives a guest before its first overrun; fast keeps
the receive FIFO full, so it must not give less). A bulk write whose transmitter
misses a deadline has ended its transmission and the rest of the window is
fill; a later deadline to the Z80 is one period. The reply and admission
guards stay: they are the time a guest takes to arm its receiver (WR3, the
stale-byte drain, `RTS`) and the arming order the guests rely on. Bounded
waits (the host's `/RTSA`, `/RTSB` release) are unchanged.

Replies, statuses, transfer ids, `READY`/`DONE` ownership, line transitions
and the bytes on the card are the same in both modes for a guest that keeps up
with the wire; only elapsed time differs. A guest that stalls inside a bulk
write corrupts the transfer in both modes, not necessarily with the same
bytes.

## Interfaces

`zephyr80_ioc_lane.h` is the lane boundary. `zephyr80_ioc_lane_port`, which
SIO1 implements, is what the controller drives and samples per lane
(`zephyr80_ioc_lane::COMMAND` or `BULK`): `lane_clock(lane, to_z80)` is one
full-duplex character time and returns what the transmitter sent;
`lane_sync`, `lane_dcd`, `lane_cts` set the controller's outputs;
`lane_rts` reads `/RTS`; `lane_rx_room` and `lane_tx_loaded` tell fast pacing
whether the Z80 can take or has supplied a character.
`zephyr80_ioc_lane_client`, which the IOC implements, receives
`lane_rts_changed` and `lane_data_event` (the Z80 read or wrote the data port). The IOC owns the scheduling (MAME timers) and the
transport state; the core owns frames and protocol state and reaches the
transport only through `zephyr80_ioc_core::link` (`resync_lanes`,
`command_lane_synced`, `hid_doorbell`, `host_reset`). The transport asks the
core for the armed transfer and hands it the captured window
(`bulk_armed`, `bulk_packet`, `bulk_sent`, `bulk_window`, `bulk_received`,
`bulk_no_host`, `run_more`, `run_next`, `run_end`) and runs its idle pass
after every service: the HID module's waiting keyboard report, the mounted and
removed USB devices, the mouse's reports and each pad's 10 ms poll
(`zephyr80_ioc_hid::report`, `mouse_report`, `gamepad_report`) and the repeat
(`task`), then `idle`. The keyboard (`zephyr80_usb_keyboard`, the IOC's
`keyboard` subdevice) hands its reports to the IOC
(`zephyr80_usb_keyboard_device::host`); the mouse and the two pads
(`zephyr80_usb_mouse`, `zephyr80_usb_gamepad`, subdevices `mouse`, `pad1`,
`pad2`) tell it when they have something (`usb_input_ready`) and are pulled in
the idle pass, a change during a service waiting for its end
([mouse and controllers](zephyr80-input.md)). The timer that wakes the idle
pass is the repeat's or the next pad poll's. The controller latches read at
E0h–FFh are the module's (`zephyr80_ioc_device::controller`). The card socket attaches with
`zephyr80_ioc_device::set_storage` (a `zephyr80_ioc_storage` backend,
required before the device starts). The
core includes no SIO, CPU or lane type, no host path operation, and never
touches an interrupt line.

All lane, transport and core state is save-registered, and the scheduler saves
the transport's timer: a state saved in the middle of a command exchange or a
bulk transfer resumes it, at the same phase and byte, on restore, and the
card socket restores its open objects and mount onto the same media
([card socket](zephyr80-card.md#save-states)).
A machine reset cancels the timer and returns the transport to idle, so no
callback reaches the next transaction.

## Not modelled

Interrupts, the daisy chain and WAIT/READY on SIO1; modes other than External
Sync x1; Auto Enables; receive CRC, parity, break/abort, DTR; the position of
`/SYNC` inside a character and anything else below byte granularity (the
bulk receive's bit-phase marker search is a byte search); bulk CRC (the
deployed bypass); the controller's request handling and the card's access
time, which take no emulated time.
