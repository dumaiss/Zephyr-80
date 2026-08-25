#include <xc.h>
#include <stdint.h>
#include <stdbool.h>
#include "config.h"
#include "external_sync.h"
#include "sio_link.h"
#include "ioc_frame.h"
#include "bulk_channel.h"

/* ---------------------------------------------------------------------------
 * Bulk lane on SIO1/A
 * ---------------------------------------------------------------------------
 *
 * Electrically this is the same SPI2 module and the same RB1/RB3 pins as the
 * command lane; only the select and the External Sync strobe differ:
 *
 *      command lane   /SIOB_CS (RA4)   /SYNCB (RA7)
 *      bulk lane      /SIOA_CS (RA5)   /SYNCA (RA6)
 *
 * The byte sequence mirrors external_sync_send(): two setup clocks, one
 * hand-clocked byte carrying the /SYNC edge, then the remainder through SPI2,
 * then a trailing flush byte.  The hand-clocked byte is now shared with the
 * command lane as sio_link_clock_sync_byte(); the ONLY difference between the
 * two lanes is BULK_SYNC_DROP_BIT below.
 *
 * Note the first data byte is the one that carries the sync edge, exactly as
 * the 7Eh preamble does on the command lane.  It is still delivered to the
 * host, so the host reads exactly `length` bytes: this stays a dumb pipe.
 * --------------------------------------------------------------------------- */

/* ---------------------------------------------------------------------------
 * Bulk lane handshake
 * ---------------------------------------------------------------------------
 *
 * Three signals, all on the SIO1/A modem-control pins:
 *
 *   RF1  /SIO1A_INT   in   the host's RTS: "I am in my read loop, go"
 *   RB4  /DCDA        out  with Auto Enables set on channel A (WR3 bit 5),
 *                          this gates the host's RECEIVER.  Held deasserted
 *                          outside a transfer, so stray clocks cannot produce
 *                          stray bytes -- BULK_ACTIVE enforced in hardware.
 *   RB0  /CTSA        out  asserted for the duration of the bulk phase.  The
 *                          host can watch it deassert instead of paying for a
 *                          DONE round trip.  With Auto Enables this same line
 *                          gates the host's TRANSMITTER, which is exactly what
 *                          a future Z80 -> MCU write needs it to mean, so the
 *                          signal keeps one meaning: "the bulk phase is live".
 *
 * Waiting for RTS replaces the fixed start guard this lane used to need.  The
 * guard was the single largest cost in a sector transfer and it was a guess;
 * this is deterministic. */
#define BULK_HOST_READY_TIMEOUT_MS  500u

/* Let the SIO act on /DCDA before the first clock edge arrives. */
#define BULK_DCD_SETTLE_US          100u

/* ---------------------------------------------------------------------------
 * Bulk byte pacing
 *
 * The bulk lane must NOT inherit EXTSYNC_TARGET_BYTE_US.  That constant is
 * sized for the BIOS command-lane receive path, sio_command_get_byte, which
 * costs 151 T-states per byte because of its per-byte call/ret, push/pop and
 * 24-bit timeout reload.
 *
 * The bulk lane is read by an inlined loop in the host program instead:
 *
 *   ld de,#0 / in / and / jr / in / ld (hl),a / inc hl / dec bc / ld a,b /
 *   or c / jr
 *      10  +  11 +  7  + 12 + 11 +     7     +   6    +   6    +   4   +
 *       4  + 12   =  90 T  =  9.0 us at 10 MHz
 *
 * So 16 us per byte was throttling this lane to nearly half its capacity for no
 * reason.  10 us leaves ~11% margin over the measured host loop, slightly more
 * than the command lane runs with.  Raise to 12 us if a long ISR ever lands
 * inside a transfer; overrun shows up as a corrupt frame, not a clean error.
 * --------------------------------------------------------------------------- */
/* The bulk lane runs SPI2 faster than the command lane.  SCK = 64 MHz /
 * (2 * (BAUD+1)), so BAUD 15 gives 2 MHz and 4 us of clocking per byte, against
 * BAUD 31 / 1 MHz / 8 us on the command lane.
 *
 * 6 us per byte is then PIC-bound: 4 us of clocking plus roughly 2 us of loop
 * overhead per byte.  The host's INI-based read loop costs 56 T-states = 5.6 us
 * at 10 MHz, so the host keeps up with margin to spare.  The SIO itself is good
 * for about 3.2 us/byte at a 10 MHz clock, so it is not the constraint either.
 *
 * Going faster means attacking the ~2 us of PIC software per byte, which needs
 * DMA feeding SPI2 rather than a polled loop. */
#define BULK_SPI_BAUD         15u   /* 64 MHz / (2 * 16) = 2 MHz */
#define BULK_SPI_BYTE_US      ((8u * 2u * (BULK_SPI_BAUD + 1u)) / 64u)
#define BULK_TARGET_BYTE_US   6u
#define BULK_BYTE_GAP_US      (BULK_TARGET_BYTE_US - BULK_SPI_BYTE_US)

#if (BULK_TARGET_BYTE_US <= BULK_SPI_BYTE_US)
#error "BULK_TARGET_BYTE_US must exceed the SPI clocking time per byte"
#endif

/* Capture window for a Z80 -> MCU transfer.
 *
 * Room for the payload, the two-byte preamble, and enough slack that the
 * preamble can still be found if the host's transmitter starts late.  The
 * search covers BULK_RX_SEARCH_BITS bit positions, so the window needs that
 * many bits of headroom plus one byte for the bit-shifted tail read. */
#define BULK_RX_SEARCH_BITS   64u
#define BULK_RX_WINDOW_BYTES  (BULK_MAX_LENGTH + BULK_CRC_BYTES + 2u + (BULK_RX_SEARCH_BITS / 8u) + 2u)

static uint8_t rx_window[BULK_RX_WINDOW_BYTES];

/* Reassemble one LSB-first byte starting at an arbitrary bit position. */
static uint8_t rx_wire_byte(uint16_t bit_index)
{
    uint8_t  i;
    uint8_t  value = 0u;
    uint16_t b;

    for (i = 0u; i < 8u; i++) {
        b = (uint16_t)(bit_index + i);
        if ((rx_window[b >> 3] >> (b & 7u)) & 1u)
            value |= (uint8_t)(1u << i);
    }

    return value;
}

/* Locate the payload by finding the two-byte preamble.  Returns the bit index
 * of the first payload byte. */
static bool find_bulk_start(uint16_t *bit_index)
{
    uint16_t start;

    for (start = 0u; start < BULK_RX_SEARCH_BITS; start++) {
        if (rx_wire_byte(start) != BULK_RX_PREAMBLE_0)
            continue;
        if (rx_wire_byte((uint16_t)(start + 8u)) != BULK_RX_PREAMBLE_1)
            continue;
        *bit_index = (uint16_t)(start + 16u);
        return true;
    }

    return false;
}

/* Pace the bulk lane to what the host's inlined read loop can drain. */
static void bulk_byte_gap(void)
{
    __delay_us(BULK_BYTE_GAP_US);
}

/* ---------------------------------------------------------------------------
 * Receive pacing (Z80 -> MCU) is NOT the send figure, and is deliberately
 * slacker.
 *
 * BULK_TARGET_BYTE_US is sized against the host's INI read loop, where being
 * slightly too fast costs nothing: the host simply has not seen the byte yet
 * and polls again.
 *
 * Receiving inverts the risk.  The MCU supplies the clock, so if it clocks
 * faster than the host's transmit loop can refill the SIO, the transmitter
 * under-runs and streams its WR7 fill character.  On this channel WR7 is 00h,
 * so the MCU captures a perfectly well-formed block of zeros, the preamble
 * search still succeeds, and the block is committed to the card.  The failure
 * is SILENT and looks exactly like a successful write of zeros.
 *
 * Worse, once the Tx Underrun latch sets the transmitter stops consuming the
 * buffer, so the host's TBE never re-asserts and it times out -- which is how
 * this was found.
 *
 * The host's OUTI-based transmit loop costs 56 T-states = 5.6 us at 10 MHz,
 * the same as its INI read loop.  12 us is a bit over 2x that.  The extra
 * margin is cheap -- 512 bytes takes 6.1 ms instead of 3.1 ms -- and buys
 * protection against a failure mode that corrupts data without reporting it.
 * Do not tune this down to match the send direction; they are not symmetric.
 * --------------------------------------------------------------------------- */
/* 24 us, not 12.
 *
 * The host's OUTI loop costs 5.6 us/byte, so 12 us left it 6.4 us of slack --
 * less than one interrupt.  A CTC ISR measured at 117 T-states (98 T of handler
 * plus 19 T of IM2 acknowledge) is 11.7 us at 10 MHz, so a single interrupt
 * landing inside a transfer put the host further behind than one byte's slack,
 * and with only about two byte-times of buffering in the SIO's transmit path
 * the transmitter ran dry.  Under CTC load at 1 ms that failed ~65% of writes.
 *
 * At 24 us the slack is 18.4 us per byte, comfortably more than one ISR, so a
 * single interrupt is absorbed within the byte it lands in.
 *
 * The cost is 12.4 ms per 512-byte block instead of 6.2 ms -- about 41 kB/s.
 * That is ample for CP/M storage, where SD command latency dominates anyway,
 * and it buys tolerance of the interrupt load that real console traffic will
 * produce.  Reads are unaffected: their 3-byte RX FIFO already absorbs ~18 us
 * and they ran clean under the same load. */
/* BISECT: back to the 12 us that ran 1864 passes clean.
 *
 * 24 us was correct reasoning for interrupt headroom on the write path, but
 * reads started failing their CRC after it went in and I have no mechanism --
 * this constant is used only in bulk_run_receive(), the WRITE direction, and
 * writes are passing while every read fails.  Restoring the known-good value
 * to confirm the changes are even the cause. */
#define BULK_RX_TARGET_BYTE_US  24u
#define BULK_RX_BYTE_GAP_US     (BULK_RX_TARGET_BYTE_US - BULK_SPI_BYTE_US)

#if (BULK_RX_TARGET_BYTE_US <= BULK_SPI_BYTE_US)
#error "BULK_RX_TARGET_BYTE_US must exceed the SPI clocking time per byte"
#endif

static void bulk_rx_byte_gap(void)
{
    __delay_us(BULK_RX_BYTE_GAP_US);
}

static const uint8_t *armed_buf;
static uint8_t       *armed_rx_buf;
static BulkCommitFn   armed_commit;
static uint8_t        armed_dir;
static uint16_t       armed_length;
static uint8_t        armed_xfer_id;
static uint8_t        xfer_id_counter;
static uint8_t        last_xfer_id;
static uint8_t        last_status;

/* Bounded wait for the host's RTS on channel A.  Bounded so a host that never
 * arrives fails one transfer instead of wedging the controller. */
static bool wait_for_host_ready(void)
{
    uint16_t ms;

    for (ms = 0u; ms < BULK_HOST_READY_TIMEOUT_MS; ms++) {
        if (SIO1A_INT_PORT == SIO1A_INT_ACTIVE)
            return true;
        __delay_ms(1);
    }

    return false;
}

static void sync_a_release(void)
{
    SYNCA_LAT = SYNCA_IDLE;
}

/* Bit position, within the hand-clocked byte, where /SYNCA is driven low.
 *
 * One bit EARLIER than the command lane's EXTSYNC_SYNC_DROP_BIT.  Both lanes
 * now share sio_link_clock_sync_byte(); this constant is the only difference
 * between them.
 *
 * That is measured, not guessed.  With the drop at bit 1 (mirroring channel B)
 * the bulk lane read back 80h where the ramp's first byte is 00h.  The ramp on
 * the wire is LSB-first:
 *
 *     byte 0 = 00 : 0 0 0 0 0 0 0 0
 *     byte 1 = 01 : 1 0 0 0 0 0 0 0
 *
 * A receive window starting one bit late assembles wire positions 1..8 =
 * 0,0,0,0,0,0,0,1, which LSB-first is 80h.  A window one bit early would have
 * produced 00h, indistinguishable from correct -- so the direction is certain.
 * Dropping /SYNC a bit earlier moves the window back into alignment.
 *
 * RULED OUT 2026-08-23: Auto Enables is not the cause.
 *
 * Channel A was run with WR3 = D1h -- Auto Enables off, otherwise byte-identical
 * to the command channel's WR3 -- against a drop at bit 1.  It still came back
 * exactly one bit late.  The bulk ramp read 80h for 00h, and a sector read
 * returned 2A D5 where the boot signature is 55 AA, which is
 * (55h >> 1) and (AAh >> 1) | 80h: a whole-stream one-bit shift, not corruption.
 *
 * The result is clean.  A stuck RTS was the worry going in, since Auto Enables
 * off also stops /CTSA gating the transmitter -- but a stuck RTS would have
 * produced a timeout or no data at all, and instead all 512 bytes arrived
 * correctly framed and merely shifted.
 *
 * Everything reachable from software has now been eliminated:
 *
 *   WR3            byte-identical (tested: D1h on A behaves as F1h does)
 *   WR4            byte-identical, 30h, External Sync, x1 clock (inspection)
 *   setup clocks   identical count and shape (inspection)
 *   bit-bang shape identical; /SYNC drops at the same point within its bit
 *   gate timing    ruled out (tested: see the select in run_if_armed)
 *
 * RxCA and RxCB come from the same PIC pin, each through a '125 gated by its
 * own channel select, and both are pulled up.  /SYNCA and /SYNCB run directly
 * from the PIC, ungated.  Given the pull-ups, gate-open drives RxC high->low
 * (a falling edge, harmless -- the SIO clocks receive data on the rising edge)
 * and gate-close gives low->high, one phantom rising edge after every transfer
 * on BOTH channels.  Symmetric, so it does not explain A against B either.
 *
 * So the difference is in hardware and is not currently explained.  The
 * measurement that would settle it is a rising-edge COUNT at the SIO's RxC pin
 * -- after the '125, so it is what the receiver actually sees -- between /SYNC
 * going low and the end of that byte, taken on each channel.  That count is
 * exactly what sets the window.  Another firmware experiment will not find it.
 *
 * WR7 is the one remaining software asymmetry (7Eh on B, 00h on A) but should
 * be inert in External Sync mode, where the /SYNC pin -- not the sync character
 * registers -- establishes framing. */
#define BULK_SYNC_DROP_BIT  0u

void bulk_channel_arm(const uint8_t *buf, uint16_t length, uint8_t xfer_id)
{
    armed_buf     = buf;
    armed_rx_buf  = 0;
    armed_commit  = 0;
    armed_dir     = BULK_DIR_MCU_TO_Z80;
    armed_length  = length;
    armed_xfer_id = xfer_id;
}

void bulk_channel_arm_receive(uint8_t *buf, uint16_t length, uint8_t xfer_id,
                              BulkCommitFn commit)
{
    armed_buf     = 0;
    armed_rx_buf  = buf;
    armed_commit  = commit;
    armed_dir     = BULK_DIR_Z80_TO_MCU;
    armed_length  = length;
    armed_xfer_id = xfer_id;
}

const uint8_t *bulk_channel_rx_window(void)
{
    return rx_window;
}

uint8_t bulk_channel_last_xfer_id(void)
{
    return last_xfer_id;
}

uint8_t bulk_channel_last_status(void)
{
    return last_status;
}

uint8_t bulk_channel_next_xfer_id(void)
{
    xfer_id_counter++;
    if (xfer_id_counter == 0u)
        xfer_id_counter = 1u;   /* 0 is reserved for "no transfer" */
    return xfer_id_counter;
}

/* MCU -> Z80.  The MCU places the /SYNC edge, so it owns the byte boundary
 * and the host simply reads `length` bytes. */
static bool bulk_run_send(void)
{
    uint16_t i;
    uint16_t crc;
    uint8_t  discard;
    bool     ok = true;

    /* Enable the host's receiver, and mark the bulk phase live. */
    DCDA_LAT = DCDA_ASSERTED;
    CTSA_LAT = CTSA_ASSERTED;
    __delay_us(BULK_DCD_SETTLE_US);

    /* Select last, immediately before clocking, matching channel B.
     *
     * This used to be asserted before the /DCDA settle, leaving the clock gate
     * open and idle for 100 us.  /SIOA_CS gates RxCA through a '125, so that
     * was a candidate for the one-bit offset against channel B.  Tested
     * 2026-08-23 with BULK_SYNC_DROP_BIT held at 0: both the ramp and a sector
     * read still passed, so gate-open timing does NOT affect where the receive
     * window lands.  Candidate ruled out.
     *
     * The ordering is kept anyway: it is proven on hardware and it removes an
     * asymmetry against the command lane for no cost. */
    SIOA_CS_LAT = SIOA_CS_ASSERTED;

    SIO_MOSI_LAT = 1;

    /* Two setup clocks with /SYNCA still idle, as on the command lane. */
    SIO_SCK_LAT = 1;
    __delay_us(EXTSYNC_BIT_DELAY_US);
    SIO_SCK_LAT = 0;
    __delay_us(EXTSYNC_BIT_DELAY_US);
    SIO_MOSI_LAT = 0;
    SIO_SCK_LAT = 1;
    __delay_us(EXTSYNC_BIT_DELAY_US);
    SIO_SCK_LAT = 0;

    /* Byte 0 carries the sync edge and is still delivered as data. */
    sio_link_clock_sync_byte(armed_buf[0], SIO_LINK_CH_BULK,
                             BULK_SYNC_DROP_BIT);
    crc = sio_link_crc16_update(0u, armed_buf[0]);

    sio_link_set_baud(BULK_SPI_BAUD);
    sio_link_clear_fifos();
    sio_link_pins_to_spi();
    for (i = 1u; i < armed_length; i++) {
        if (!sio_link_exchange(armed_buf[i], &discard)) {
            ok = false;
            break;
        }
        crc = sio_link_crc16_update(crc, armed_buf[i]);
        bulk_byte_gap();
    }

    /* CRC-16 trailer, most significant byte first.  The host reads
     * length + BULK_CRC_BYTES and checks it; the lane has no other integrity
     * check, so without this a corrupted block is indistinguishable from a
     * good one at both ends. */
    if (ok) {
        if (!sio_link_exchange((uint8_t)(crc >> 8), &discard))
            ok = false;
        bulk_byte_gap();
    }
    if (ok) {
        if (!sio_link_exchange((uint8_t)crc, &discard))
            ok = false;
        bulk_byte_gap();
    }

    /* The SIO exposes its final received byte only after further clocks. */
    (void)sio_link_exchange(0xFFu, &discard);
    sio_link_pins_to_lat();

    sync_a_release();
    SIO_MOSI_LAT = 1;

    /* Deasserting /CTSA is the completion edge the host watches for.
     * Deasserting /DCDA disables its receiver again, so nothing that happens
     * on the shared clock afterwards can be mistaken for bulk data. */
    CTSA_LAT = CTSA_IDLE;
    DCDA_LAT = DCDA_IDLE;

    SIOA_CS_LAT = SIOA_CS_IDLE;

    armed_length = 0u;

    /* DONE state: the bytes are on the wire.  For a read that is the whole
     * story.  The write direction cannot report success here -- see
     * bulk_run_receive(), which defers DONE until the commit has run. */
    last_xfer_id = armed_xfer_id;
    last_status  = ok ? IOC_STATUS_OK : IOC_STATUS_BULK_FAIL;

    return ok;
}

/* Z80 -> MCU.  The MCU still supplies every clock edge, but the host owns the
 * byte boundary, so the payload is captured raw and de-shifted afterwards.
 *
 * /CTSA is what makes this direction work: under Auto Enables it gates the
 * host's TRANSMITTER, so the host cannot put a bit on the wire until the MCU
 * says so.  /DCDA stays IDLE throughout -- that gates the host's RECEIVER, and
 * nothing is being sent to it.  Leaving it deasserted means the clocks driven
 * here cannot be latched by the host as phantom received bytes. */
static bool bulk_run_receive(void)
{
    uint16_t i;
    uint16_t bit_index;
    uint16_t window;
    uint16_t length;
    uint16_t crc;
    uint16_t wire_crc;
    bool     ok = true;

    /* Hold the length locally.  armed_length is cleared during teardown below,
     * before the payload is de-shifted, so the copy loop must not read it --
     * doing so silently copies nothing and leaves the destination buffer at
     * whatever it held before, which then gets committed as if it were the
     * received data. */
    length = armed_length;

    /* Payload, CRC trailer, preamble, and slack for a late-starting
     * transmitter. */
    window = (uint16_t)(length + BULK_CRC_BYTES + 2u +
                        (BULK_RX_SEARCH_BITS / 8u) + 2u);
    if (window > BULK_RX_WINDOW_BYTES)
        window = BULK_RX_WINDOW_BYTES;

    CTSA_LAT = CTSA_ASSERTED;
    __delay_us(BULK_DCD_SETTLE_US);

    SIOA_CS_LAT = SIOA_CS_ASSERTED;

    /* Marking idle on MOSI and /SYNCA asserted for the whole window, exactly
     * as external_sync_receive() does on the command lane.  Receiving needs no
     * intra-byte GPIO: there is no sync edge to place in this direction. */
    SIO_MOSI_LAT = 1;
    SYNCA_LAT    = SYNCA_ASSERTED;

    sio_link_set_baud(BULK_SPI_BAUD);
    sio_link_clear_fifos();
    sio_link_pins_to_spi();
    for (i = 0u; i < window; i++) {
        if (!sio_link_exchange(0xFFu, &rx_window[i])) {
            ok = false;
            break;
        }
        bulk_rx_byte_gap();
    }
    sio_link_pins_to_lat();

    sync_a_release();
    SIO_MOSI_LAT = 1;

    SIOA_CS_LAT = SIOA_CS_IDLE;

    /* /CTSA deliberately stays ASSERTED past the end of the byte stream, until
     * the commit below has finished.  For a write it means "this transfer is
     * still in progress", and the commit IS part of the transfer -- the card
     * has not been touched yet when the last byte lands.
     *
     * This is not cosmetic.  The command-lane request detector is edge
     * triggered on /SIO1B_INT, and the PIC samples that line only in its main
     * loop -- so it is blind for the whole card write.  A host that releases
     * channel A and immediately issues the DONE query asserts its RTS while
     * the PIC is inside the write; when the PIC returns, the line is already
     * low and there is no edge left to see.  The request is lost and the host
     * times out after ~11 s.
     *
     * Holding /CTSA across the commit gives the host something real to wait
     * on, so by the time it asks for DONE the PIC is back in its loop and has
     * sampled the idle level.  A host that watches /CTSA cannot lose the race;
     * one that does not, still can. */

    armed_length = 0u;
    last_xfer_id = armed_xfer_id;

    if (!ok) {
        last_status = IOC_STATUS_BULK_FAIL;
        CTSA_LAT = CTSA_IDLE;
        return false;
    }

    if (!find_bulk_start(&bit_index)) {
        /* Clocked the window but never saw the preamble: the host either never
         * transmitted or started so late it fell outside the search.  Distinct
         * from a bus failure, and worth its own code -- it points at the host
         * side, not the link. */
        last_status = IOC_STATUS_BULK_NO_SYNC;
        CTSA_LAT = CTSA_IDLE;
        return false;
    }

    crc = 0u;
    for (i = 0u; i < length; i++) {
        armed_rx_buf[i] = rx_wire_byte((uint16_t)(bit_index + (i * 8u)));
        crc = sio_link_crc16_update(crc, armed_rx_buf[i]);
    }

    /* CRC-16 trailer follows the payload, most significant byte first. */
    wire_crc  = (uint16_t)rx_wire_byte((uint16_t)(bit_index + (length * 8u))) << 8;
    wire_crc |= (uint16_t)rx_wire_byte((uint16_t)(bit_index + ((length + 1u) * 8u)));

    if (wire_crc != crc) {
        /* Do NOT commit.  A block that fails here reached the MCU intact
         * enough to be de-shifted but is not the block the host sent, and
         * writing it would be a silent wrong-data write to the card. */
        last_status = IOC_STATUS_BULK_CRC;
        CTSA_LAT = CTSA_IDLE;
        return false;
    }

    /* Only now is DONE meaningful.  Bytes arriving says nothing about whether
     * they were stored. */
    last_status = (armed_commit != 0) ? armed_commit() : IOC_STATUS_OK;

    /* Transfer is genuinely over: release the busy indication. */
    CTSA_LAT = CTSA_IDLE;

    return (last_status == IOC_STATUS_OK);
}

bool bulk_channel_run_if_armed(void)
{
    if (armed_length == 0u)
        return true;

    /* READY has gone out; wait for the host to say it is ready to move bytes.
     * Same signal in both directions: RTS on channel A. */
    if (!wait_for_host_ready()) {
        armed_length = 0u;
        last_xfer_id = armed_xfer_id;
        last_status  = IOC_STATUS_BULK_NO_HOST;
        return false;
    }

    if (armed_dir == BULK_DIR_Z80_TO_MCU)
        return bulk_run_receive();

    return bulk_run_send();
}
