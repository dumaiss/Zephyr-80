#include <xc.h>
#include <stdint.h>
#include <stdbool.h>
#include "config.h"
#include "spi1_bus.h"
#include "sd_card.h"

/* ---------------------------------------------------------------------------
 * SD card, SPI mode
 * ---------------------------------------------------------------------------
 *
 * Bring-up sequence, which is fixed by the SD physical layer spec:
 *
 *   1. At least 74 clocks with the select DEASSERTED, so the card enters its
 *      native power-up state.  This is the one place the select must be high
 *      while the bus is clocked.
 *   2. CMD0 with the select asserted -> the card switches to SPI mode and
 *      answers R1 = 01h (idle).
 *   3. CMD8 tells v2.00+ cards the supply voltage and echoes a check pattern.
 *      A card that rejects it as an illegal command is v1.x.
 *   4. ACMD41 (CMD55 then CMD41) is polled until the card leaves idle.  This is
 *      the slow step -- up to about a second on some cards.
 *   5. CMD58 reports the OCR, whose CCS bit says whether the card is addressed
 *      by block (SDHC/SDXC) or by byte (standard capacity).
 *   6. Byte-addressed cards get CMD16 to pin the block length at 512.
 *
 * Clocking: steps 1-6 must run between 100 and 400 kHz, which is why the bus is
 * reconfigured twice.  Everything after runs at the faster data rate.
 *
 * CRC: SPI mode ignores CRC except on CMD0 and CMD8, whose values are constants
 * for the fixed arguments used here.  Nothing is computed, so this does not
 * reintroduce a checksum layer anywhere.
 * --------------------------------------------------------------------------- */

#define SD_CMD0_GO_IDLE          0u
#define SD_CMD8_SEND_IF_COND     8u
#define SD_CMD16_SET_BLOCKLEN    16u
#define SD_CMD17_READ_SINGLE     17u
#define SD_CMD24_WRITE_SINGLE    24u
#define SD_CMD55_APP_CMD         55u
#define SD_CMD58_READ_OCR        58u
#define SD_ACMD41_SEND_OP_COND   41u

#define SD_CRC_CMD0              0x95u  /* valid for argument 00000000h */
#define SD_CRC_CMD8              0x87u  /* valid for argument 000001AAh */
#define SD_CRC_DUMMY             0x01u  /* stop bit only; ignored in SPI mode */

#define SD_R1_IDLE               0x01u
#define SD_R1_ILLEGAL_COMMAND    0x04u
#define SD_R1_READY              0x00u

#define SD_DATA_TOKEN            0xFEu
/* Write data-response, sent by the card after it takes a data block.  Only
 * bits 3:1 are meaningful; the rest are undefined and must be masked off. */
#define SD_DATA_RESP_MASK        0x1Fu
#define SD_DATA_RESP_ACCEPTED    0x05u
/* Busy-wait after a write: the card holds DO low while it programs.
 *
 * The byte count is derived from SD_DATA_BYTE_US, preserving the ~480 ms
 * real-time bound when the stretch-test clock is scaled back.  At 4 MHz this
 * is 240000 bytes, so the polling loop deliberately uses uint32_t. */
#define SD_WRITE_BUSY_TIMEOUT_US 480000uL
#define SD_WRITE_BUSY_BYTES      (SD_WRITE_BUSY_TIMEOUT_US / SD_DATA_BYTE_US)

#define SD_IF_COND_ARG           0x000001AAuL  /* 2.7-3.6 V, check pattern AAh */
#define SD_OCR_CCS               0x40000000uL  /* block addressing when set */
#define SD_ACMD41_HCS            0x40000000uL  /* host supports high capacity */

/* ---------------------------------------------------------------------------
 * Iteration bounds
 *
 * These must be sized against the HOST's patience, not just the card's.  The
 * Z80 BIOS waits about 2.9 s for a reply byte (0xFFFF x 0x08 poll iterations
 * at about 5.6 us each).  If the PIC is still talking to the card when that
 * expires, IOCALL reports a transport timeout and the host sees only its A5h
 * fill -- indistinguishable from the link being broken.
 *
 * So the whole SD operation has to finish comfortably inside ~2.9 s, and it is
 * far better to give up early with a status code than to run long.
 *
 * Byte times: 125 kHz init clock -> 64 us/byte; 4 MHz data clock -> 2 us/byte.
 * One sd_command() is at most 17 bytes (1 idle + 6 command + 10 R1 polls).
 *
 *   sd_command at init speed, maximum R1 polling       ~ 1.09 ms
 *   ACMD41 iteration, immediate R1 from both commands  ~ 1.02 ms
 *   1200 immediate-response iterations                 ~ 1.23 s
 *   1200 maximum-R1-poll iterations                    ~ 2.61 s
 *   token poll, 75000 bytes at data speed              ~ 0.15 s
 *
 * Ordinary idle responses retain the full retry allowance.  Repeated illegal
 * responses take the bounded recovery path below and return far sooner.
 * --------------------------------------------------------------------------- */
#define SD_R1_POLL_BYTES         10u
#define SD_IDLE_RETRIES          20u
#define SD_INIT_CLOCK_BYTES      12u   /* 96 clocks; spec minimum is 74 */
#define SD_POWER_SETTLE_MS       10u   /* spec minimum is 1 ms after Vdd stable */
#define SD_CMD0_RETRY_GAP_MS     2u
#define SD_RECOVERY_SETTLE_MS    10u

/* Clock rate for the initialisation phase.  The SD spec allows 100-400 kHz;
 * 400 kHz is the top of that window and the least forgiving of a long or
 * poorly terminated path, which a mezzanine connector is.  125 kHz is the
 * slowest SPI1 reaches from Fosc and is still in spec. */
#define SD_INIT_BAUD             SPI1_BAUD_125KHZ

/* Clock for the data phase, once the card is initialised.  Separate from the
 * init rate because the card is only obliged to accept 100-400 kHz until it
 * reports ready.  Lower this first if CMD17 or the data token misbehave: a
 * card that initialises cleanly at 125 kHz and then fails at the data rate is
 * a signal-integrity problem, not a protocol one. */
#define SD_DATA_BAUD             SPI1_BAUD_4MHZ
#define SD_DATA_BYTE_US          \
    ((8uL * 2uL * (SD_DATA_BAUD + 1uL)) / 64uL)

/* Whole-read attempts.  Only CRC failures and a missing data token are retried
 * -- see sd_card_read_block().  A rejected CMD17 or an absent card fails the
 * same way every time. */
#define SD_READ_ATTEMPTS         3u
#define SD_ACMD41_RETRIES        1200u
#define SD_ACMD41_ILLEGAL_LIMIT  8u
#define SD_INIT_ATTEMPTS         2u    /* initial attempt plus one recovery */
#define SD_TOKEN_TIMEOUT_US      150000uL
#define SD_TOKEN_POLL_BYTES      (SD_TOKEN_TIMEOUT_US / SD_DATA_BYTE_US)

/* CRC-16-CCITT (poly 1021h, init 0000h, MSB first) -- the algorithm SD uses
 * for data blocks.  Nibble table: two lookups per byte, 32 bytes of flash, and
 * about 800 us for a 512-byte block.  A bitwise loop would be ~2.6 ms, which
 * would nearly double the read; a 256-entry table saves ~200 us more for 512
 * bytes of flash and is not worth it here. */
static const uint16_t crc16_nibble[16] = {
    0x0000u, 0x1021u, 0x2042u, 0x3063u,
    0x4084u, 0x50A5u, 0x60C6u, 0x70E7u,
    0x8108u, 0x9129u, 0xA14Au, 0xB16Bu,
    0xC18Cu, 0xD1ADu, 0xE1CEu, 0xF1EFu
};

static uint16_t crc16_update(uint16_t crc, uint8_t data)
{
    crc = (uint16_t)((crc << 4) ^ crc16_nibble[((crc >> 12) ^ (data >> 4)) & 0x0Fu]);
    crc = (uint16_t)((crc << 4) ^ crc16_nibble[((crc >> 12) ^ (data & 0x0Fu)) & 0x0Fu]);
    return crc;
}

static uint8_t trace[SD_TRACE_BYTES];
static bool    trace_armed;

const uint8_t *sd_card_trace(void)
{
    return trace;
}

static bool card_ready;
static bool block_addressed;

bool sd_card_is_initialized(void)
{
    return card_ready;
}

static void sd_select(void)
{
    spi1_bus_select(SPI1_DEVICE_SD_CARD);
}

/* Deselect, then give the card its trailing clocks.
 *
 * The clocks reach the card with CS high -- there is no gating on this bus --
 * so these two bytes give the card 16 idle clocks to release DO and finish
 * internal housekeeping before another SPI1 device can be selected. */
static void sd_deselect(void)
{
    spi1_bus_select(SPI1_DEVICE_NONE);
    (void)spi1_bus_write(0xFFu);
    (void)spi1_bus_write(0xFFu);
}

/* Issue a command and return its R1 response, or FFh if the card never
 * answered.  R1 is the first byte with bit 7 clear. */
/* Set by any SPI transfer that timed out, so a stalled bus aborts the operation
 * instead of being mistaken for a card that keeps answering FFh.  Without this
 * a dead bus multiplies every retry bound into its maximum duration. */
static bool bus_failed;

static uint8_t sd_xfer(uint8_t out)
{
    uint8_t in = 0xFFu;

    if (!spi1_bus_transfer(out, &in))
        bus_failed = true;

    return in;
}

static uint8_t sd_command(uint8_t cmd, uint32_t arg, uint8_t crc)
{
    uint8_t i;
    uint8_t r1;

    (void)sd_xfer(0xFFu);           /* one idle byte before the command */

    (void)sd_xfer((uint8_t)(0x40u | cmd));
    (void)sd_xfer((uint8_t)(arg >> 24));
    (void)sd_xfer((uint8_t)(arg >> 16));
    (void)sd_xfer((uint8_t)(arg >> 8));
    (void)sd_xfer((uint8_t)arg);
    (void)sd_xfer(crc);

    for (i = 0u; i < SD_R1_POLL_BYTES; i++) {
        if (bus_failed)
            return 0xFFu;
        r1 = sd_xfer(0xFFu);
        if (trace_armed && (i < SD_TRACE_BYTES))
            trace[i] = r1;
        if ((r1 & 0x80u) == 0u)
            return r1;
    }

    return 0xFFu;
}

/* Read the 4-byte trailer of an R3/R7 response, most significant byte first. */
static uint32_t sd_read_r37_trailer(void)
{
    uint32_t v = 0uL;
    uint8_t i;

    for (i = 0u; i < 4u; i++)
        v = (v << 8) | (uint32_t)sd_xfer(0xFFu);

    return v;
}

static void bump(uint16_t *counter);
static uint16_t read_retries;
static uint16_t reinits;

SdStatus sd_card_init(void)
{
    uint8_t  r1;
    uint16_t tries;
    uint8_t  i;
    uint8_t  init_attempt;
    uint8_t  illegal_replies;
    bool     v2_card;
    uint32_t ocr;

#if SD_HAS_PRESENT_PIN
    /* Checked BEFORE the cached-success shortcut below, deliberately.  Removing
     * a card power-cycles it, so it comes back knowing nothing about the SPI
     * session this driver believes it still has.  Letting the cache answer
     * first would report SD_OK for a card that is not even in the socket. */
    SD_PRESENT_ANSEL = 0;
    SD_PRESENT_TRIS  = 1;
    if (SD_PRESENT_PORT != SD_PRESENT_ACTIVE) {
        card_ready = false;
        return SD_ERR_NO_CARD;
    }
#endif

    if (card_ready)
        return SD_OK;

    /* Past the cache, so a real initialisation sequence is about to run.  This
     * is the expensive half of a retried read and the number worth watching. */
    bump(&reinits);

    block_addressed = false;
    bus_failed      = false;

    /* SD DO is high-Z until the card is selected and in SPI mode.  A weak
     * pull-up makes an undriven line read as a clean FFh rather than noise,
     * which is what the trace above assumes -- and it is standard practice on
     * SD SPI wiring anyway. */
    WPUCbits.WPUC4 = 1;

    /* Step 1: power-up clocks, CS and DI held HIGH, as the spec requires.
     *
     * This is how a card is put into SPI mode: it samples CS on the first clock
     * edges it sees, and CS must be HIGH then.  Clocked with CS low instead, a
     * card is entitled to stay in SD mode and ignore CMD0 forever -- which
     * presents as an all-FFh CMD0 trace and SD_ERR_NO_RESPONSE.
     *
     * There is NO hardware gate on SPI_CLK to the port C devices.  An earlier
     * version of this comment asserted there was one, "confirmed on a scope",
     * and moved the burst to CS low on that basis.  The scope showed only that
     * clock and CS coincided -- which they did because this firmware clocked
     * exclusively while a select was asserted.  Correlation was recorded as a
     * hardware fact and then used to justify dropping the one step the spec is
     * least willing to bend on.  The clock reaches the card whatever CS is
     * doing, so the compliant sequence is available and is what runs here.
     *
     * The delay first lets the rail settle; cards want at least 1 ms after Vdd
     * is stable before they are clocked. */
    spi1_bus_configure(SD_INIT_BAUD, SPI1_MSB_FIRST);
    __delay_ms(SD_POWER_SETTLE_MS);

    sd_deselect();
    for (i = 0u; i < SD_INIT_CLOCK_BYTES; i++) {
        if (!spi1_bus_write(0xFFu))
            return SD_ERR_BUS;
    }

    for (init_attempt = 0u; init_attempt < SD_INIT_ATTEMPTS; init_attempt++) {
        /* A repeated illegal ACMD41 response triggers one protocol restart.
         * CS and MOSI remain high for more than the required 80 clocks, then
         * the card gets a short settling interval before CMD0 starts over. */
        if (init_attempt != 0u) {
            sd_deselect();
            for (i = 0u; i < SD_INIT_CLOCK_BYTES; i++) {
                if (!spi1_bus_write(0xFFu))
                    return SD_ERR_BUS;
            }
            __delay_ms(SD_RECOVERY_SETTLE_MS);
        }

        /* Step 2: CMD0.  Retried because a card that was mid-transaction before
         * a warm reset can swallow the first attempt.
         *
         * Silence here is reported as NO_RESPONSE, never as NO_CARD.  An earlier
         * version inferred "socket empty" from every byte reading FFh, which is
         * wrong: a seated card that has not entered SPI mode is equally silent,
         * so the code claimed the card was absent exactly when it was present
         * and misbehaving.  Only the presence pin can say a card is missing.
         * Use the trace bytes to tell silence apart from garbage. */
        r1 = 0xFFu;

        /* Capture the first CMD0 transaction in this initialization attempt. */
        for (i = 0u; i < SD_TRACE_BYTES; i++)
            trace[i] = 0u;
        trace_armed = true;
        for (i = 0u; i < SD_IDLE_RETRIES; i++) {
            sd_select();
            r1 = sd_command(SD_CMD0_GO_IDLE, 0uL, SD_CRC_CMD0);
            trace_armed = false;
            sd_deselect();
            if (r1 == SD_R1_IDLE)
                break;
            /* Give a card still finishing its internal power-up a moment before
             * the next complete CMD0 transaction. */
            __delay_ms(SD_CMD0_RETRY_GAP_MS);
        }
        if (r1 != SD_R1_IDLE)
            return SD_ERR_NO_RESPONSE;

        /* From here the trace doubles as an init-stage snapshot.  A later CMD17
         * or CMD24 clears and reuses it, but an init failure leaves these bytes
         * intact for PROFILE/PING to report. */
        trace[0] = r1;                 /* final CMD0 response */

        /* Step 3: CMD8 separates v2.00+ from v1.x.  Its R7 trailer is part of
         * the same transaction and must be consumed before deselecting. */
        sd_select();
        r1 = sd_command(SD_CMD8_SEND_IF_COND, SD_IF_COND_ARG, SD_CRC_CMD8);
        trace[1] = r1;
        if (r1 == SD_R1_IDLE) {
            uint32_t if_cond = sd_read_r37_trailer();

            sd_deselect();
            /* The card must echo the voltage range and check pattern back. */
            if ((if_cond & 0x00000FFFuL) !=
                (SD_IF_COND_ARG & 0x00000FFFuL))
                return SD_ERR_UNUSABLE;
            v2_card = true;
        } else {
            sd_deselect();
            if ((r1 & SD_R1_ILLEGAL_COMMAND) != 0u)
                v2_card = false;
            else
                return SD_ERR_UNUSABLE;
        }

        /* Step 4: CMD55 and ACMD41 are adjacent but separate transactions.
         * A valid CMD55 prefix may report ready or idle; any error response is
         * not followed by an application command. */
        illegal_replies = 0u;
        for (tries = 0u; tries < SD_ACMD41_RETRIES; tries++) {
            sd_select();
            trace[2] = sd_command(SD_CMD55_APP_CMD, 0uL, SD_CRC_DUMMY);
            sd_deselect();

            trace[4] = (uint8_t)tries;
            trace[5] = (uint8_t)(tries >> 8);
            trace[6] = SPI1BAUD;
            /* Bit 2 distinguishes the recovery pass from the initial pass.
             * Without it, both attempts can end with the same final snapshot. */
            trace[7] = (uint8_t)((bus_failed ? 0x01u : 0u) |
                                 ((SD_PRESENT_PORT == SD_PRESENT_ACTIVE) ?
                                  0x02u : 0u) |
                                 ((init_attempt != 0u) ? 0x04u : 0u));
            if (bus_failed)
                return SD_ERR_BUS;
            if ((trace[2] != SD_R1_IDLE) &&
                (trace[2] != SD_R1_READY))
                return SD_ERR_UNUSABLE;

            sd_select();
            r1 = sd_command(SD_ACMD41_SEND_OP_COND,
                            v2_card ? SD_ACMD41_HCS : 0uL,
                            SD_CRC_DUMMY);
            sd_deselect();

            trace[3] = r1;
            trace[7] = (uint8_t)((bus_failed ? 0x01u : 0u) |
                                 ((SD_PRESENT_PORT == SD_PRESENT_ACTIVE) ?
                                  0x02u : 0u) |
                                 ((init_attempt != 0u) ? 0x04u : 0u));
            if ((r1 == SD_R1_READY) || bus_failed)
                break;

            if (r1 == (SD_R1_IDLE | SD_R1_ILLEGAL_COMMAND)) {
                illegal_replies++;
                /* The recovery attempt gets one chance to prove that its full
                 * clocks/CMD0/CMD8 restart cleared the illegal-command state. */
                if ((init_attempt != 0u) ||
                    (illegal_replies >= SD_ACMD41_ILLEGAL_LIMIT))
                    break;
            }
        }

        if (bus_failed)
            return SD_ERR_BUS;
        if (r1 == SD_R1_READY)
            break;
        if ((r1 == (SD_R1_IDLE | SD_R1_ILLEGAL_COMMAND)) &&
            (init_attempt == 0u) &&
            (illegal_replies >= SD_ACMD41_ILLEGAL_LIMIT))
            continue;

        return SD_ERR_NOT_READY;
    }

    if (r1 != SD_R1_READY)
        return SD_ERR_NOT_READY;

    /* Step 5: CCS in the OCR decides block versus byte addressing.  Only v2
     * cards can be high capacity, so v1 skips straight to CMD16. */
    if (v2_card) {
        sd_select();
        r1 = sd_command(SD_CMD58_READ_OCR, 0uL, SD_CRC_DUMMY);
        if (r1 == SD_R1_READY)
            ocr = sd_read_r37_trailer();
        sd_deselect();
        if (r1 != SD_R1_READY)
            return SD_ERR_UNUSABLE;
        block_addressed = ((ocr & SD_OCR_CCS) != 0uL);
    }

    /* Step 6: byte-addressed cards need the block length pinned at 512. */
    if (!block_addressed) {
        sd_select();
        r1 = sd_command(SD_CMD16_SET_BLOCKLEN, SD_BLOCK_SIZE, SD_CRC_DUMMY);
        sd_deselect();
        if (r1 != SD_R1_READY)
            return SD_ERR_UNUSABLE;
    }

    card_ready = true;
    return SD_OK;
}

/* Body of the block read.  Wrapped below so SD_BUSY is released on every exit
 * path, of which this has several. */
static SdStatus sd_read_block_inner(uint32_t lba, uint8_t *buf)
{
    SdStatus st;
    uint8_t  r1;
    uint8_t  token;
    uint32_t address;
    uint32_t token_count;
    uint16_t i;
    uint16_t crc;
    uint16_t card_crc;

    st = sd_card_init();
    if (st != SD_OK)
        return st;

    bus_failed = false;

    /* Standard-capacity cards address by byte, high-capacity ones by block. */
    address = block_addressed ? lba : (lba * SD_BLOCK_SIZE);

    spi1_bus_configure(SD_DATA_BAUD, SPI1_MSB_FIRST);
    sd_select();

    /* Re-arm the trace so a read failure reports CMD17's response rather than
     * CMD0's, which by this point is known to have succeeded. */
    for (i = 0u; i < SD_TRACE_BYTES; i++)
        trace[i] = 0u;
    trace_armed = true;

    r1 = sd_command(SD_CMD17_READ_SINGLE, address, SD_CRC_DUMMY);
    trace_armed = false;

    if (r1 != SD_R1_READY) {
        sd_deselect();
        return SD_ERR_READ;
    }

    /* The card sends FFh until its data is ready, then the FEh start token. */
    token = 0xFFu;
    for (token_count = 0uL; token_count < SD_TOKEN_POLL_BYTES; token_count++) {
        token = sd_xfer(0xFFu);
        if (token != 0xFFu)
            break;
        if (bus_failed)
            break;
    }
    if (bus_failed) {
        sd_deselect();
        return SD_ERR_BUS;
    }
    if (token != SD_DATA_TOKEN) {
        /* Record whatever did arrive.  FEh is the data token; a 0Xh byte is an
         * SD error token whose low nibble gives the reason. */
        trace[SD_TRACE_BYTES - 1u] = token;
        sd_deselect();
        return SD_ERR_NO_TOKEN;
    }

    crc = 0u;
    for (i = 0u; i < SD_BLOCK_SIZE; i++) {
        buf[i] = sd_xfer(0xFFu);
        crc = crc16_update(crc, buf[i]);
    }

    /* The card always sends a CRC-16 after the block.  SPI mode does not
     * require the host to check it, and this driver originally discarded it --
     * but on a marginal bus that turns a corrupted sector into a silent
     * SD_OK.  Checking it costs ~800 us and converts corruption into a clean,
     * retryable error, which is the difference between a subtly wrong
     * filesystem and a failed read. */
    card_crc  = (uint16_t)sd_xfer(0xFFu) << 8;
    card_crc |= (uint16_t)sd_xfer(0xFFu);

    if (bus_failed) {
        sd_deselect();
        return SD_ERR_BUS;
    }

    if (card_crc != crc) {
        trace[SD_TRACE_BYTES - 4u] = (uint8_t)(crc >> 8);
        trace[SD_TRACE_BYTES - 3u] = (uint8_t)crc;
        trace[SD_TRACE_BYTES - 2u] = (uint8_t)(card_crc >> 8);
        trace[SD_TRACE_BYTES - 1u] = (uint8_t)card_crc;
        sd_deselect();
        return SD_ERR_CRC;
    }

    sd_deselect();
    return SD_OK;
}

/* Write one 512-byte block with CMD24.
 *
 * Mirrors sd_read_block_inner(): initialise, select, issue the command, move
 * the data, release.  Three things differ and each is a distinct failure:
 *
 *   - the card ACKs the data with a data-response byte, not just R1.  Only
 *     bits 3:1 are defined, so it must be masked before comparing.
 *   - after accepting the block the card pulls DO low and holds it there while
 *     it programs.  Nothing else may be clocked to it until that clears.
 *   - the CRC-16 is mandatory in the packet.  SPI mode ignores it unless CRC
 *     mode is on, but sending a real one costs nothing here (the table is
 *     already used by the read path) and makes the write self-checking if CRC
 *     mode is ever enabled.
 *
 * There is deliberately no retry wrapper.  A failed read can be retried
 * harmlessly; a write that failed midway has already changed the card, so
 * retrying is a decision for the caller, not something to bury in here.
 */
static SdStatus sd_write_block_inner(uint32_t lba, const uint8_t *buf)
{
    SdStatus st;
    uint8_t  r1;
    uint8_t  resp;
    uint32_t address;
    uint32_t busy_count;
    uint16_t i;
    uint16_t crc;

    st = sd_card_init();
    if (st != SD_OK)
        return st;

    bus_failed = false;

    address = block_addressed ? lba : (lba * SD_BLOCK_SIZE);

    spi1_bus_configure(SD_DATA_BAUD, SPI1_MSB_FIRST);
    sd_select();

    for (i = 0u; i < SD_TRACE_BYTES; i++)
        trace[i] = 0u;
    trace_armed = true;

    r1 = sd_command(SD_CMD24_WRITE_SINGLE, address, SD_CRC_DUMMY);
    trace_armed = false;

    if (r1 != SD_R1_READY) {
        sd_deselect();
        return SD_ERR_WRITE;
    }

    /* One idle byte between the command response and the data packet, then the
     * start token. */
    (void)sd_xfer(0xFFu);
    (void)sd_xfer(SD_DATA_TOKEN);

    crc = 0u;
    for (i = 0u; i < SD_BLOCK_SIZE; i++) {
        (void)sd_xfer(buf[i]);
        crc = crc16_update(crc, buf[i]);
    }

    (void)sd_xfer((uint8_t)(crc >> 8));
    (void)sd_xfer((uint8_t)crc);

    if (bus_failed) {
        sd_deselect();
        return SD_ERR_BUS;
    }

    resp = sd_xfer(0xFFu);
    trace[0] = resp;
    if ((resp & SD_DATA_RESP_MASK) != SD_DATA_RESP_ACCEPTED) {
        sd_deselect();
        return SD_ERR_WRITE_REJECTED;
    }

    /* Card holds DO low while programming.  Any non-zero byte means done. */
    for (busy_count = 0uL; busy_count < SD_WRITE_BUSY_BYTES; busy_count++) {
        if (sd_xfer(0xFFu) != 0x00u)
            break;
        if (bus_failed)
            break;
    }

    if (bus_failed) {
        sd_deselect();
        return SD_ERR_BUS;
    }

    if (busy_count >= SD_WRITE_BUSY_BYTES) {
        sd_deselect();
        return SD_ERR_WRITE_BUSY;
    }

    sd_deselect();
    return SD_OK;
}

SdStatus sd_card_write_block(uint32_t lba, const uint8_t *buf)
{
    SdStatus st;

    SD_BUSY_LAT = SD_BUSY_ASSERTED;
    st = sd_write_block_inner(lba, buf);
    SD_BUSY_LAT = SD_BUSY_IDLE;

    /* A write failure invalidates the cached "card is ready" state for the same
     * reason a read failure does: the card may have been swapped or dropped out
     * mid-transaction, and the next call must re-initialise rather than trust
     * a stale flag. */
    if ((st != SD_OK) && (st != SD_ERR_NO_CARD))
        card_ready = false;

    return st;
}

#if SD_CMD0_LOOP
/* Power-up clocks plus a single CMD0, repeated forever.  See sd_card.h. */
void sd_card_cmd0_loop(void)
{
    uint8_t i;

    spi1_bus_configure(SD_INIT_BAUD, SPI1_MSB_FIRST);
    WPUCbits.WPUC4 = 1;

    for (;;) {
        /* Clocks with CS HIGH, matching sd_card_init(). */
        sd_deselect();
        for (i = 0u; i < SD_INIT_CLOCK_BYTES; i++)
            (void)spi1_bus_write(0xFFu);

        sd_select();
        (void)sd_command(SD_CMD0_GO_IDLE, 0uL, SD_CRC_CMD0);
        sd_deselect();

        __delay_ms(50);
    }
}
#endif

/* Raise SD_BUSY for the whole card access, including the lazy initialisation
 * the first call triggers.  That first one can run for the best part of a
 * second while ACMD41 is polled, so it is clearly visible; later reads are a
 * brief flicker.  Released on every exit path because the wrapper owns it. */
/* Retry and re-init counters.
 *
 * These exist because a retried read is INVISIBLE: it returns SD_OK with the
 * right bytes, and the only trace it leaves is time.  A marginal bus therefore
 * presents as "the card is mysteriously slow" rather than as an error, and no
 * amount of staring at throughput numbers distinguishes it from a protocol
 * cost.  One failed read costs a full re-initialisation -- 10 ms of settle plus
 * CMD0 and ACMD41 at 125 kHz -- so a few percent of retries dominates
 * everything else the driver does.
 *
 * Saturating rather than wrapping: "at least 65535" is the same answer as any
 * larger number, and a wrap would read as a small count. */
static void bump(uint16_t *counter)
{
    if (*counter != 0xFFFFu)
        (*counter)++;
}

uint16_t sd_card_read_retries(void) { return read_retries; }
uint16_t sd_card_reinits(void)      { return reinits; }

SdStatus sd_card_read_block(uint32_t lba, uint8_t *buf)
{
    SdStatus st;

    uint8_t attempt;

#if SD_BUSY_LED
    SD_BUSY_LAT = SD_BUSY_ASSERTED;
#endif

    /* Retry policy.
     *
     * A failure in the READ phase invalidates the cached initialisation before
     * retrying.  That is what makes card swaps work: removing a card
     * power-cycles it, so it comes back in SD mode knowing nothing about the
     * SPI session this driver believes it still has.  Without the invalidation
     * every read after a swap fails until the PIC is reset -- the cache said
     * "initialised" forever.
     *
     * A failure in the INIT phase is not retried here: initialisation already
     * retries CMD0 internally, and a card that is absent or unusable will fail
     * the same way every time, which would just burn the host's patience. */
    st = SD_ERR_READ;
    for (attempt = 0u; attempt < SD_READ_ATTEMPTS; attempt++) {
        st = sd_read_block_inner(lba, buf);

        if (st == SD_OK)
            break;

        if ((st == SD_ERR_NO_CARD) || (st == SD_ERR_NO_RESPONSE) ||
            (st == SD_ERR_UNUSABLE) || (st == SD_ERR_NOT_READY))
            break;   /* init failed; retrying changes nothing */

        bump(&read_retries);
        card_ready = false;   /* re-initialise on the next attempt */
    }

#if SD_BUSY_LED
    SD_BUSY_LAT = SD_BUSY_IDLE;
#endif

    return st;
}
