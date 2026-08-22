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

/* Give the Z80 time to return from IOCALL and enter its read loop before the
 * clock starts.  The PIC is clock master and there is no ready signal from the
 * host on this lane, so this delay is the only thing preventing the transfer
 * from starting before anyone is listening.  The SIO's 3-byte receive FIFO
 * covers only ~48 us at the current byte rate, which is nowhere near enough. */
#define BULK_START_GUARD_MS  20u

static const uint8_t *armed_buf;
static uint16_t       armed_length;
static uint8_t        armed_xfer_id;
static uint8_t        xfer_id_counter;
static uint8_t        last_xfer_id;
static uint8_t        last_status;

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

    __delay_ms(BULK_START_GUARD_MS);

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
    clock_sync_byte_a(armed_buf[0]);

    sio_link_clear_fifos();
    sio_link_pins_to_spi();
    for (i = 1u; i < armed_length; i++) {
        if (!sio_link_exchange(armed_buf[i], &discard)) {
            ok = false;
            break;
        }
        sio_link_byte_gap();
    }

    /* The SIO exposes its final received byte only after further clocks. */
    (void)sio_link_exchange(0xFFu, &discard);
    sio_link_pins_to_lat();

    sync_a_release();
    SIO_MOSI_LAT = 1;
    SIOA_CS_LAT = SIOA_CS_IDLE;

    armed_length = 0u;

    /* DONE state: the bytes are on the wire.  For a read that is the whole
     * story; a future write would additionally have to commit to the card
     * before reporting OK here. */
    last_xfer_id = armed_xfer_id;
    last_status  = ok ? IOC_STATUS_OK : IOC_STATUS_BULK_FAIL;

    return ok;
}
