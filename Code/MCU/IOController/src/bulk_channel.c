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
 * The byte sequence below deliberately mirrors external_sync_send(): two setup
 * clocks, one hand-clocked byte carrying the /SYNC edge, then the remainder
 * through SPI2, then a trailing flush byte.  It is duplicated rather than
 * shared because that sequence is proven on channel B and unproven on A --
 * once A is working the two should be unified behind a channel parameter.
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

/* Pace the bulk lane to what the host's inlined read loop can drain. */
static void bulk_byte_gap(void)
{
    __delay_us(BULK_BYTE_GAP_US);
}

static const uint8_t *armed_buf;
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

static void sync_a_assert(void)
{
    SYNCA_LAT = SYNCA_ASSERTED;
}

static void sync_a_release(void)
{
    SYNCA_LAT = SYNCA_IDLE;
}

/* Hand-clock one byte with the /SYNCA edge inside it.
 *
 * Same shape as clock_reply_byte() in external_sync.c, but /SYNCA drops one bit
 * position EARLIER than /SYNCB does on the command lane.
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
 * Why the two channels differ is not established; the BIOS configures them
 * through different paths (sio1_ioc_init at boot for A, sio_command_init per
 * IOCALL for B), which is the first place to look if this ever needs revisiting.
 *
 * BULK_SYNC_DROP_BIT exists so the position can be bisected from the bench
 * without restructuring the sequence.  Do not collapse this into a generic bit
 * loop; the edge placement is the electrical protocol. */
#define BULK_SYNC_DROP_BIT  0u

static void clock_sync_byte_a(uint8_t value)
{
    uint8_t i;

    for (i = 0u; i < 8u; i++) {
        sio_link_write_data_bit(value & 1u);
        value >>= 1;
        __delay_us(EXTSYNC_BIT_DELAY_US);
        SIO_SCK_LAT = 1;
        __delay_us(EXTSYNC_BIT_DELAY_US);

        if (i == BULK_SYNC_DROP_BIT) {
            /* Between the rising and falling edge of this bit, as on the
             * command lane -- only at a different bit index. */
            sync_a_assert();
            __delay_us(EXTSYNC_BIT_DELAY_US);
        }

        SIO_SCK_LAT = 0;

        /* The command lane leaves no trailing gap on the first two bits and
         * one on the rest; keep that asymmetry. */
        if (i >= 2u)
            __delay_us(EXTSYNC_BIT_DELAY_US);
    }
}

void bulk_channel_arm(const uint8_t *buf, uint16_t length, uint8_t xfer_id)
{
    armed_buf     = buf;
    armed_length  = length;
    armed_xfer_id = xfer_id;
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

bool bulk_channel_run_if_armed(void)
{
    uint16_t i;
    uint8_t  discard;
    bool     ok = true;

    if (armed_length == 0u)
        return true;

    /* READY has gone out; wait for the host to say it is listening. */
    if (!wait_for_host_ready()) {
        armed_length = 0u;
        last_xfer_id = armed_xfer_id;
        last_status  = IOC_STATUS_BULK_NO_HOST;
        return false;
    }

    SIOA_CS_LAT = SIOA_CS_ASSERTED;

    /* Enable the host's receiver, and mark the bulk phase live. */
    DCDA_LAT = DCDA_ASSERTED;
    CTSA_LAT = CTSA_ASSERTED;
    __delay_us(BULK_DCD_SETTLE_US);

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
    clock_sync_byte_a(armed_buf[0]);

    sio_link_set_baud(BULK_SPI_BAUD);
    sio_link_clear_fifos();
    sio_link_pins_to_spi();
    for (i = 1u; i < armed_length; i++) {
        if (!sio_link_exchange(armed_buf[i], &discard)) {
            ok = false;
            break;
        }
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
     * story; a future write would additionally have to commit to the card
     * before reporting OK here. */
    last_xfer_id = armed_xfer_id;
    last_status  = ok ? IOC_STATUS_OK : IOC_STATUS_BULK_FAIL;

    return ok;
}
