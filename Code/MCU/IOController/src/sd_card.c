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

#define SD_IF_COND_ARG           0x000001AAuL  /* 2.7-3.6 V, check pattern AAh */
#define SD_OCR_CCS               0x40000000uL  /* block addressing when set */
#define SD_ACMD41_HCS            0x40000000uL  /* host supports high capacity */

/* ---------------------------------------------------------------------------
 * Iteration bounds
 *
 * These must be sized against the HOST's patience, not just the card's.  The
 * Z80 BIOS waits about 10.7 s for a reply byte (0xFFFF x 0x20 poll iterations
 * at 51 T-states, 10 MHz).  If the PIC is still talking to the card when that
 * expires, IOCALL reports a transport timeout and the host sees only its A5h
 * fill -- indistinguishable from the link being broken.
 *
 * So the whole SD operation has to finish comfortably inside ~10 s, and it is
 * far better to give up early with a status code than to run long.
 *
 * Byte times: 400 kHz init clock -> 20 us/byte; 1 MHz data clock -> 8 us/byte.
 * One sd_command() is at most 17 bytes (1 idle + 6 command + 10 R1 polls).
 *
 *   sd_command at init speed   ~ 340 us
 *   ACMD41 iteration (x2 cmds) ~ 680 us
 *   1200 iterations            ~ 0.8 s   <- SD spec allows 1 s for ACMD41
 *   token poll, 25000 bytes    ~ 0.2 s   <- SD spec read access max is 100 ms
 *
 * Worst case total is therefore about 1 s, an order of magnitude inside the
 * host timeout.
 * --------------------------------------------------------------------------- */
#define SD_R1_POLL_BYTES         10u
#define SD_IDLE_RETRIES          20u
#define SD_INIT_CLOCK_BYTES      12u   /* 96 clocks; spec minimum is 74 */
#define SD_POWER_SETTLE_MS       10u   /* spec minimum is 1 ms after Vdd stable */
#define SD_CMD0_RETRY_GAP_MS     2u

/* Clock rate for the initialisation phase.  The SD spec allows 100-400 kHz;
 * 400 kHz is the top of that window and the least forgiving of a long or
 * poorly terminated path, which a mezzanine connector is.  125 kHz is the
 * slowest SPI1 reaches from Fosc and is still in spec. */
#define SD_INIT_BAUD             SPI1_BAUD_125KHZ

/* Clock for the data phase, once the card is initialised.  Separate from the
 * init rate because the card is only obliged to accept 100-400 kHz until it
 * reports ready.  Lower this first if CMD17 or the data token misbehave: a
 * card that initialises cleanly at 125 kHz and then fails at 1 MHz is a signal
 * integrity problem, not a protocol one. */
#define SD_DATA_BAUD             SPI1_BAUD_1MHZ

/* Whole-read attempts.  Only CRC failures and a missing data token are retried
 * -- see sd_card_read_block().  A rejected CMD17 or an absent card fails the
 * same way every time. */
#define SD_READ_ATTEMPTS         3u
#define SD_ACMD41_RETRIES        1200u
#define SD_TOKEN_POLL_BYTES      25000u

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

static void sd_select(void)
{
    IO_SD_CS_LAT = IO_SD_CS_ASSERTED;
}

/* Deselect, then give the card its trailing clock.
 *
 * The SD spec wants one clock after CS rises so the card releases DO.  That
 * clock is gated away on this board (see the power-up step in sd_card_init),
 * so the byte reaches nothing -- but the card tri-states DO on deselect
 * regardless, and the write costs 8 us and stays correct if the gating is ever
 * removed. */
static void sd_deselect(void)
{
    IO_SD_CS_LAT = IO_SD_CS_IDLE;
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

SdStatus sd_card_init(void)
{
    uint8_t  r1;
    uint16_t tries;
    uint8_t  i;
    bool     v2_card;
    uint32_t ocr;

    if (card_ready)
        return SD_OK;

    block_addressed = false;
    bus_failed      = false;

    /* SD DO is high-Z until the card is selected and in SPI mode.  A weak
     * pull-up makes an undriven line read as a clean FFh rather than noise,
     * which is what the trace above assumes -- and it is standard practice on
     * SD SPI wiring anyway. */
    WPUCbits.WPUC4 = 1;

#if SD_HAS_PRESENT_PIN
    /* Definitive and instant, once RC0 is wired. */
    SD_PRESENT_ANSEL = 0;
    SD_PRESENT_TRIS  = 1;
    if (SD_PRESENT_PORT != SD_PRESENT_ACTIVE)
        return SD_ERR_NO_CARD;
#endif

    /* Step 1: power-up clocks.
     *
     * The spec asks for at least 74 clocks with CS and DI held HIGH.  On this
     * board that is impossible: SPI_CLK to the port C devices is GATED BY THE
     * DEVICE SELECT, confirmed on a scope -- the clock only runs while a select
     * is asserted, exactly as the SIO bus gates on its channel selects.  Clocks
     * sent with CS high reach nothing.
     *
     * So the power-up clocks are sent with CS LOW.  That is a deliberate
     * deviation from the spec's letter, forced by the hardware, and it is safe:
     * DI is held high throughout, so the card sees no start bit (SD commands
     * begin 0b01) and simply ignores the traffic while its internal
     * initialisation clocks tick.
     *
     * An earlier version also sent a burst with CS high, on the theory that the
     * gating might not exist.  It was pure waste -- ~0.8 ms of clocks delivered
     * to a gate that was closed -- and has been removed now the gating is
     * measured rather than guessed.
     *
     * The delay first lets the rail settle; cards want at least 1 ms after Vdd
     * is stable before they are clocked. */
    spi1_bus_configure(SD_INIT_BAUD, SPI1_MSB_FIRST);
    __delay_ms(SD_POWER_SETTLE_MS);

    IO_SD_CS_LAT = IO_SD_CS_ASSERTED;
    for (i = 0u; i < SD_INIT_CLOCK_BYTES; i++) {
        if (!spi1_bus_write(0xFFu))
            return SD_ERR_BUS;
    }
    sd_deselect();

    /* Step 2: CMD0.  Retried because a card that was mid-transaction before a
     * warm reset can swallow the first attempt.
     *
     * Silence here is reported as NO_RESPONSE, never as NO_CARD.  An earlier
     * version inferred "socket empty" from every byte reading FFh, which is
     * wrong: a seated card that has not entered SPI mode is equally silent, so
     * the code claimed the card was absent exactly when it was present and
     * misbehaving.  Only the presence pin can say a card is missing.  Use the
     * trace bytes to tell silence apart from garbage. */
    sd_select();
    r1 = 0xFFu;

    /* Capture the first attempt's response bytes for diagnostics. */
    for (i = 0u; i < SD_TRACE_BYTES; i++)
        trace[i] = 0u;
    trace_armed = true;
    for (i = 0u; i < SD_IDLE_RETRIES; i++) {
        r1 = sd_command(SD_CMD0_GO_IDLE, 0uL, SD_CRC_CMD0);
        trace_armed = false;   /* first attempt only */
        if (r1 == SD_R1_IDLE)
            break;
        /* Deselect between attempts and give the card a moment: a card still
         * finishing its internal power-up will ignore CMD0 entirely. */
        sd_deselect();
        __delay_ms(SD_CMD0_RETRY_GAP_MS);
        sd_select();
    }
    if (r1 != SD_R1_IDLE) {
        sd_deselect();
        return SD_ERR_NO_RESPONSE;
    }

    /* Step 3: CMD8 separates v2.00+ from v1.x. */
    r1 = sd_command(SD_CMD8_SEND_IF_COND, SD_IF_COND_ARG, SD_CRC_CMD8);
    if (r1 == SD_R1_IDLE) {
        uint32_t if_cond = sd_read_r37_trailer();

        /* The card must echo the voltage range and check pattern back. */
        if ((if_cond & 0x00000FFFuL) != (SD_IF_COND_ARG & 0x00000FFFuL)) {
            sd_deselect();
            return SD_ERR_UNUSABLE;
        }
        v2_card = true;
    } else if ((r1 & SD_R1_ILLEGAL_COMMAND) != 0u) {
        v2_card = false;
    } else {
        sd_deselect();
        return SD_ERR_UNUSABLE;
    }

    /* Step 4: poll ACMD41 until the card reports ready. */
    for (tries = 0u; tries < SD_ACMD41_RETRIES; tries++) {
        (void)sd_command(SD_CMD55_APP_CMD, 0uL, SD_CRC_DUMMY);
        r1 = sd_command(SD_ACMD41_SEND_OP_COND,
                        v2_card ? SD_ACMD41_HCS : 0uL,
                        SD_CRC_DUMMY);
        if (r1 == SD_R1_READY)
            break;
        if (bus_failed)
            break;
    }
    if (bus_failed) {
        sd_deselect();
        return SD_ERR_BUS;
    }
    if (r1 != SD_R1_READY) {
        sd_deselect();
        return SD_ERR_NOT_READY;
    }

    /* Step 5: CCS in the OCR decides block versus byte addressing.  Only v2
     * cards can be high capacity, so v1 skips straight to CMD16. */
    if (v2_card) {
        r1 = sd_command(SD_CMD58_READ_OCR, 0uL, SD_CRC_DUMMY);
        if (r1 != SD_R1_READY) {
            sd_deselect();
            return SD_ERR_UNUSABLE;
        }
        ocr = sd_read_r37_trailer();
        block_addressed = ((ocr & SD_OCR_CCS) != 0uL);
    }

    /* Step 6: byte-addressed cards need the block length pinned at 512. */
    if (!block_addressed) {
        r1 = sd_command(SD_CMD16_SET_BLOCKLEN, SD_BLOCK_SIZE, SD_CRC_DUMMY);
        if (r1 != SD_R1_READY) {
            sd_deselect();
            return SD_ERR_UNUSABLE;
        }
    }

    sd_deselect();
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
    for (i = 0u; i < SD_TOKEN_POLL_BYTES; i++) {
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

#if SD_CMD0_LOOP
/* Power-up clocks plus a single CMD0, repeated forever.  See sd_card.h. */
void sd_card_cmd0_loop(void)
{
    uint8_t i;

    spi1_bus_configure(SD_INIT_BAUD, SPI1_MSB_FIRST);
    WPUCbits.WPUC4 = 1;

    for (;;) {
        /* Clocks with CS asserted, matching sd_card_init(): the port C clock is
         * gated by the select, so a CS-high burst would reach nothing. */
        sd_select();
        for (i = 0u; i < SD_INIT_CLOCK_BYTES; i++)
            (void)spi1_bus_write(0xFFu);

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
SdStatus sd_card_read_block(uint32_t lba, uint8_t *buf)
{
    SdStatus st;

    uint8_t attempt;

#if SD_BUSY_LED
    SD_BUSY_LAT = SD_BUSY_ASSERTED;
#endif

    /* Retry only the failures a marginal bus actually causes.  A rejected
     * CMD17 or a dead card will fail identically every time, so retrying those
     * just wastes the host's patience. */
    st = SD_ERR_READ;
    for (attempt = 0u; attempt < SD_READ_ATTEMPTS; attempt++) {
        st = sd_read_block_inner(lba, buf);
        if ((st != SD_ERR_CRC) && (st != SD_ERR_NO_TOKEN))
            break;
    }

#if SD_BUSY_LED
    SD_BUSY_LAT = SD_BUSY_IDLE;
#endif

    return st;
}
