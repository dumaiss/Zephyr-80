#ifndef EXTERNAL_SYNC_H
#define EXTERNAL_SYNC_H

#include <stdbool.h>
#include "ioc_frame.h"

/* Z80 SIO External Sync transport.
 *
 * Hardware:
 *
 *   PIC18F57Q84                    Z80 SIO1/B
 *   -----------                    ----------
 *   RB3  SIO_SCK    -------------> RXTXCB
 *   RB1  SIO_MOSI   -------------> RXDB
 *   RB2  SIO_MISO   <------------- TXDB
 *   RA7  /SYNCB     -------------> /SYNCB
 *   RA4  /SIOB_CS   -------------> bus select / TXDB buffer enable
 *   RF0  /SIO1B_INT <------------- service request
 *
 * The PIC owns only the SIO serial-side signals.  The Z80 BIOS owns the SIO
 * register bus and must configure channel B for External Sync mode.
 *
 * Link contract:
 *   - /SIO1B_INT low tells the PIC that the Z80 BIOS is inside one IOCALL.
 *   - /SIOB_CS must be asserted for the whole transaction; the board only
 *     activates the clock toward an SIO while its select is asserted.
 *   - The PIC supplies all serial clock edges.
 *   - Bytes are shifted least-significant bit first, matching the Z80 SIO
 *     serializer.
 *   - The mailbox body is exactly 32 raw bytes.  The transport does not add
 *     bytes before or after the mailbox body, apart from the required trailing
 *     idle clocks used to flush the SIO receiver.
 *
 * See docs/external_sync_protocol.md for the timing walkthrough and the SIO
 * manual references behind the /SYNCB handling.
 */

/* ---------------------------------------------------------------------------
 * Transport
 *
 * The bulk of every transfer runs on the SPI2 hardware module.  It is a hybrid,
 * not a wholesale replacement: reply byte 0 is still clocked by hand, because
 * /SYNCB has to be asserted at a precise position *inside* that byte (after
 * bit 1's rising edge, before its falling edge) and a hardware shift register
 * cannot be interrupted mid-word.  sync_assert() is idempotent, so every later
 * byte needs no intra-byte GPIO and goes through SPI2.
 *
 * The bit-banged receive path and the RX/TX transport switches were removed
 * once the SPI path was confirmed on hardware; see git history if the old
 * transport is ever needed for comparison.
 * --------------------------------------------------------------------------- */

/* Bound on the wait for one SPI byte to complete.  One byte at 125 kHz is
 * ~64 us, about 1000 instruction cycles at 64 MHz, so this is a wide margin.
 * It exists so a module that never completes cannot wedge the PIC in a spin
 * loop -- that would hang the controller until reset, which is far worse than
 * failing one transaction.  One byte at 1 MHz is 8 us, about 128 instruction
 * cycles at 64 MHz, so this bound is orders of magnitude wide. */
#define EXTSYNC_SPI_TIMEOUT_LOOPS 20000u

#define EXTSYNC_BIT_DELAY_US     50u
#define EXTSYNC_ALIGNMENT_BYTE   0x7Eu

/* ---------------------------------------------------------------------------
 * Reply turnaround guard
 *
 * The PIC waits this long after receiving a request before clocking the reply,
 * so the host has time to turn SIO1/B from transmit to receive.  Everything the
 * host does in that window is the prologue of ioc_command_recv_frame:
 *
 *   ld a,n / out (c),a  x3   75 T   (WR0 error reset, WR3 RX enable)
 *   push de / pop hl         21 T
 *   ld b,n                    7 T
 *   ret / call / test        ~48 T   getting there from send_frame
 *                            -----
 *                            ~130 T  = 13 us at 10 MHz
 *
 * This was 10 ms during bring-up -- about 770x what the host needs -- and at two
 * IOCALLs per sector it was 20 ms of a 32 ms transfer, the single largest cost
 * in the whole path.  1 ms still leaves ~77x margin.
 *
 * In microseconds so it can be tuned below a millisecond without changing units.
 * If replies start failing, this is the first constant to raise.
 * --------------------------------------------------------------------------- */
#define EXTSYNC_REPLY_GUARD_US   200u

/* ---------------------------------------------------------------------------
 * SPI2 link timing
 *
 * SPI2CLK = 0 selects Fosc (the reset default), so no clock-source encoding is
 * involved.  SCK = Fosc / (2 * (BAUD + 1)).
 *
 * The datasheet prints Equation 36-1 without parentheses, as
 * "FCSEL / 2 x BAUD + 1", which is ambiguous.  It has to be 2 * (BAUD + 1):
 * the reset value BAUD = 0 would otherwise mean SCK = FCSEL, and a divider
 * cannot emit a symmetric clock at its own input frequency.
 *
 *   BAUD =  31  ->  64 MHz / 64  = 1.000 MHz   <- current
 *   BAUD = 255  ->  64 MHz / 512 = 125 kHz     (module minimum from Fosc)
 *
 * Bit rate is NOT by itself what the host feels.  The Z80 BIOS polls RR0 in
 * software behind a 3-byte SIO FIFO, so what matters is the *byte* rate, set by
 * EXTSYNC_TARGET_BYTE_US below.  External Sync counts clock edges and is
 * indifferent to gaps between bytes.
 *
 * The inter-byte gap is derived from the baud rate rather than hard-coded, so
 * changing EXTSYNC_SPI_BAUD alone cannot silently change the pacing the host
 * depends on.  At a 25 us target:
 *
 *   BAUD =  31  ->   8 us of clocking + 17 us gap = 25 us per byte
 *   BAUD = 255  ->  64 us of clocking, which exceeds the target and trips the
 *                   static assert below -- raise the baud or the target
 *
 * What the baud rate buys is headroom: at 125 kHz a byte spent 64 us on the
 * wire, so a 25 us byte period was not reachable at all.
 * --------------------------------------------------------------------------- */
#define EXTSYNC_SPI_CLKSEL       0x00u   /* Fosc */
#define EXTSYNC_SPI_BAUD         31u     /* 64 MHz / (2 * 32) = 1.000 MHz */

/* ---------------------------------------------------------------------------
 * Byte pacing
 *
 * EXTSYNC_TARGET_BYTE_US is the real throughput knob.  Its floor is set by how
 * fast the Z80 BIOS can drain the SIO, not by anything on the PIC side.
 *
 * Per byte, IOC_CMD_RECV_LOOP -> sio_command_get_byte costs 151 T-states in the
 * best case (byte already waiting on the first poll):
 *
 *   call sio_command_get_byte                         17
 *   push bc / ld b,n / ld de,nn                       28
 *   in a,(ctrl) / and / jr nz taken                   30
 *   in a,(data) / pop bc / ld c,a / xor a / ret       39
 *   or a / jr nz / ld (hl),c / inc hl / djnz          37
 *
 * At 10 MHz that is 15.1 us per byte, i.e. ~530 kbit/s -- the ceiling for the
 * current BIOS.  Only 30 of those 151 T-states are the actual poll; the rest is
 * per-byte call/ret, push/pop and reloading the 24-bit timeout counter.
 *
 * 16 us (500 kbit/s) is deliberately close to that floor -- about 6% margin.
 * Be aware what the 15.1 us assumes: no I/O wait states, no interrupt taken
 * during the transfer, and the byte already waiting on the first poll.  A 10 MHz
 * Z80 with even one wait state on the two IN instructions pushes the floor to
 * ~15.4 us, and the SIO's 3-byte receive FIFO only buys ~48 us of cover against
 * a long ISR.  Overrun shows up as a corrupt frame, not a clean error.
 *
 * Back-off ladder if 16 us proves marginal:
 *
 *   20u  -> 400 kbit/s, 32% margin
 *   25u  -> 320 kbit/s, 65% margin
 *
 * Going below ~15 us requires reworking the host loop -- inlining the poll and
 * dropping the per-byte call/timeout gets it to about 62 T-states (6.2 us,
 * ~1.3 Mbit/s), which is what a 1 Mbps target actually needs.
 * --------------------------------------------------------------------------- */
#ifndef EXTSYNC_TARGET_BYTE_US
#define EXTSYNC_TARGET_BYTE_US   16u   /* 8 bits / 16 us = 500 kbit/s */
#endif
#define EXTSYNC_SPI_BYTE_US      ((8u * 2u * (EXTSYNC_SPI_BAUD + 1u)) / 64u)
#define EXTSYNC_BYTE_GAP_US      (EXTSYNC_TARGET_BYTE_US - EXTSYNC_SPI_BYTE_US)

/* The gap is an unsigned subtraction, so a target below the clocking time would
 * silently wrap to an enormous delay instead of going faster. */
#if (EXTSYNC_TARGET_BYTE_US <= EXTSYNC_SPI_BYTE_US)
#error "EXTSYNC_TARGET_BYTE_US must exceed EXTSYNC_SPI_BYTE_US; raise it or raise EXTSYNC_SPI_BAUD"
#endif

/* PPS output source codes, from Table 21-2 "PPS Output Selection Table" in
 * DS40002213D.  These values are not derivable from the XC8 headers or the DFP
 * device file, which carry only the register layout.
 *
 * The table lists which ports each source can reach per package.  For the
 * 48-pin device both SPI2 outputs are available on ports B and D, so RB1 and
 * RB3 are legal targets:
 *
 *   0x35  SPI2 SDO   B, D
 *   0x34  SPI2 SCK   B, D
 *   0x32  SPI1 SDO   B, C   <- for the port C peripheral bus later
 *   0x31  SPI1 SCK   B, C
 */
#define EXTSYNC_PPS_SRC_SPI2_SDO 0x35u
#define EXTSYNC_PPS_SRC_SPI2_SCK 0x34u

/* The host request currently occupies either:
 *   byte 0..31: direct frame, or
 *   byte 1..32: one leading host alignment byte, then the frame.
 *
 * Clock a small fixed window so the firmware stays simple while the host BIOS
 * is still being simplified.
 */
/* The window must be long enough that the whole 32-byte mailbox still fits
 * after wherever the host's 7Eh alignment byte lands:
 *
 *     copy_received_frame() requires  start_bits + 256 <= WINDOW * 8
 *
 * so a 48-byte window tolerates the alignment byte appearing up to 16 bytes in.
 * In practice it lands within the first byte or two -- the host asserts RTS and
 * is transmitting a few microseconds later, against a 16 us byte time -- so 16
 * bytes is roughly ten times the observed need.
 *
 * It was 80, of which only 33 are ever used; each byte costs 16 us twice per
 * sector.  Lower it further only with that inequality in mind: too small and a
 * late request silently fails to decode. */
#define EXTSYNC_RX_WINDOW_BYTES  48u

/* How far into the capture window find_frame_start() will look for the frame.
 *
 * The window is deliberately larger than a frame so the host's transmission can
 * start late and still be captured whole.  The search must therefore cover that
 * entire slack: anything less throws away the tolerance the window was sized to
 * provide.
 *
 * It used to search 16 bits -- two bytes -- against 15 bytes of slack.  That
 * held for one-shot .COM programs, where the delay between the host asserting
 * RTS and its first byte reaching the wire was consistent.  Under back-to-back
 * transactions it is not: the PIC begins clocking at varying points relative to
 * the host, and a request arriving later than two byte-times was either missed
 * outright or, worse, matched at a wrong alignment inside those 16 bits.  A
 * mis-locked header dispatches the WRONG HANDLER -- an observed case decoded a
 * CMD_SD_READ_BULK as CMD_PING and replied RSP_PING, after which every
 * subsequent reply was off by one transaction.
 *
 * The bound is derived from the window so it cannot drift out of step: the
 * 32-byte frame must still fit after the start offset. */
#define EXTSYNC_FRAME_SEARCH_BITS \
    ((uint16_t)((EXTSYNC_RX_WINDOW_BYTES - IOC_FRAME_SIZE) * 8u))

/* Bit position, within the hand-clocked byte, where /SYNCB is driven low.
 *
 * Channel A uses 0 (BULK_SYNC_DROP_BIT in bulk_channel.c).  The one-bit
 * difference between the channels is a hardware asymmetry with no known cause;
 * every software explanation was eliminated by test or inspection on
 * 2026-08-23.  See bulk_channel.c for the record. */
#define EXTSYNC_SYNC_DROP_BIT    1u

void external_sync_init(void);
bool external_sync_receive(IocFrame *frame);
void external_sync_send(const IocFrame *frame);

#endif /* EXTERNAL_SYNC_H */
