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
#define SD_IDLE_RETRIES          10u
#define SD_ACMD41_RETRIES        1200u
#define SD_TOKEN_POLL_BYTES      25000u

static bool card_ready;
static bool block_addressed;

static void sd_select(void)
{
    IO_SD_CS_LAT = IO_SD_CS_ASSERTED;
}

static void sd_deselect(void)
{
    IO_SD_CS_LAT = IO_SD_CS_IDLE;
    /* The card releases DO one clock after the select goes high; an idle byte
     * gives it that clock so it does not hold the shared bus. */
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

    /* Step 1: 80 clocks with the select high puts the card in a known state. */
    spi1_bus_configure(SPI1_BAUD_400KHZ, SPI1_MSB_FIRST);
    sd_deselect();
    for (i = 0u; i < 10u; i++) {
        if (!spi1_bus_write(0xFFu))
            return SD_ERR_BUS;
    }

    /* Step 2: CMD0.  Retried because a card that was mid-transaction before a
     * warm reset can swallow the first attempt. */
    sd_select();
    r1 = 0xFFu;
    for (i = 0u; i < SD_IDLE_RETRIES; i++) {
        r1 = sd_command(SD_CMD0_GO_IDLE, 0uL, SD_CRC_CMD0);
        if (r1 == SD_R1_IDLE)
            break;
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

SdStatus sd_card_read_block(uint32_t lba, uint8_t *buf)
{
    SdStatus st;
    uint8_t  r1;
    uint8_t  token;
    uint32_t address;
    uint16_t i;

    st = sd_card_init();
    if (st != SD_OK)
        return st;

    bus_failed = false;

    /* Standard-capacity cards address by byte, high-capacity ones by block. */
    address = block_addressed ? lba : (lba * SD_BLOCK_SIZE);

    spi1_bus_configure(SPI1_BAUD_1MHZ, SPI1_MSB_FIRST);
    sd_select();

    r1 = sd_command(SD_CMD17_READ_SINGLE, address, SD_CRC_DUMMY);
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
        sd_deselect();
        return SD_ERR_READ;
    }

    for (i = 0u; i < SD_BLOCK_SIZE; i++)
        buf[i] = sd_xfer(0xFFu);

    /* Two CRC bytes always follow the block and are discarded: SPI mode does
     * not require the host to check them. */
    (void)sd_xfer(0xFFu);
    (void)sd_xfer(0xFFu);

    if (bus_failed) {
        sd_deselect();
        return SD_ERR_BUS;
    }

    sd_deselect();
    return SD_OK;
}
