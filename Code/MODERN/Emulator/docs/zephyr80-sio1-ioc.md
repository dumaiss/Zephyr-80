# SIO1 and the IO controller

SIO1 is the link to the IO controller (IOC). Both channels run External Sync
x1 lanes that the controller clocks: channel B is the command lane (ports
32h data, 33h control), channel A the bulk lane (30h/31h); A3:A2 mirror them
across 30h–3Fh. Both guests poll SIO1 with its interrupts disabled.

The machine models SIO1 as a behavioural device, `zephyr80_sio1`
(`mame/src/mame/pbitz/zephyr80_sio1.*`), and the controller as
`zephyr80_ioc` (`zephyr80_ioc.*`) with its transport-independent protocol
core `zephyr80_ioc_core` (`zephyr80_ioc_core.*`). SIO0 is MAME's stock
`z80sio`. The specification is the KonaOS IOC driver
(`ZephyrOS/drivers/ioc/ioc_boot.c`, `ioc_io.asm`, `ioc.c`,
`platform/zephyr80/public/hardware.h`) and the controller firmware
(`Code/MCU/IOController`: `src/main.c`, `src/external_sync.c`,
`src/handlers.c`, `include/ioc_frame.h`, `include/external_sync.h`). No
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
| RR0 D5, `/CTSB` | the HID doorbell (`ioc_status`) | asserted while the HID queue holds bytes | the IOC drives it; deasserted (no HID queue) |
| RR0 D3, `/DCDA` | read admission | asserted before the clock gate opens | the IOC drives it; deasserted (no bulk) |
| RR0 D5, `/CTSA` | write admission and phase active | held for the transfer | the IOC drives it; deasserted (no bulk) |
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
| command-lane byte | 20 µs | the firmware's target is 16 µs (`EXTSYNC_TARGET_BYTE_US`) plus its per-byte overhead, not derived; the KonaOS request loop (175 T-states a byte, one transmit buffer) works on the board, so the board's period is at least 17.5 µs |
| reply guard | 200 µs | `EXTSYNC_REPLY_GUARD_US` |
| `/RTSB` release bound after the window | 1 ms | the firmware bounds it by a loop count; not derived |
| request detection, decoding, dispatch | 0 | not modelled |

The core serves PING (`handler_ping`: the 16-byte echo, level 75, the power
byte of a powered board with no shutdown request plus `IOC_PING_LINK_SYNCED`,
the service and abort counters) and LINK_SYNC (`handler_link_sync`: both
lanes drop their boundary, so the reply re-establishes the command lane's).
Every other class the firmware's request gate admits is answered as the
firmware answers a class it does not serve: RSP_UNKNOWN_COMMAND (FEh), status
IOC_STATUS_UNKNOWN_CMD. The guests then report no filesystem and no input
device. A machine reset resets the controller with the board: no service in
flight, both `/SYNC` lines released, READY asserted.

## Interfaces

`zephyr80_ioc_lane.h` is the lane boundary. `zephyr80_ioc_lane_port`, which
SIO1 implements, is what the controller drives and samples per lane
(`zephyr80_ioc_lane::COMMAND` or `BULK`): `lane_clock(lane, to_z80)` is one
full-duplex character time and returns what the transmitter sent;
`lane_sync`, `lane_dcd`, `lane_cts` set the controller's outputs;
`lane_rts` reads `/RTS`. `zephyr80_ioc_lane_client`, which the IOC implements,
receives `lane_rts_changed`. The IOC owns the scheduling (MAME timers) and the
transport state; the core owns frames and protocol state and reaches the
transport only through `zephyr80_ioc_core::link` (`resync_lanes`,
`command_lane_synced`). The core includes no SIO, CPU or lane type and never
touches an interrupt line.

All lane, transport and core state is save-registered.

## Not modelled

Interrupts, the daisy chain and WAIT/READY on SIO1; modes other than External
Sync x1; Auto Enables; receive CRC, parity, break/abort, DTR; the position of
`/SYNC` inside a character and anything else below byte granularity; the HID
queue and doorbell; bulk transfers and bulk admission; CMD_RESET; every
command class but PING and LINK_SYNC; board-measured timing.
