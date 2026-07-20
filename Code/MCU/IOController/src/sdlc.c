#include <xc.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include "sdlc.h"
#include "config.h"
#include "trace.h"

/* Built only when the SPI/External-Sync transport is selected.  When
 * IOC_TRANSPORT_BITBANG is defined this TU is empty and sdlc_bitbang.c provides
 * the sdlc_* symbols instead.  See config.h for the transport switch. */
#ifndef IOC_TRANSPORT_BITBANG

/* ---------------------------------------------------------------------------
 * Software (bit-banged) SPI on RA5/RA6/RA7.
 *
 * The PIC18F57Q84 SPI1 peripheral CANNOT be routed to Port A: PPS *output*
 * for SCK1/SDO1 is only available on Ports B/C/D (only SS may land on Port A).
 * The board hardwires the shared SPI bus to RA5 (MOSI), RA6 (MISO), RA7 (CLK),
 * so the hardware SPI engine can never drive these pins — RA7PPS=SCK1 is
 * accepted into the register but connects to nothing, which is exactly why the
 * pin read back the right PPS code yet emitted zero clock edges.
 *
 * We therefore bit-bang SPI Mode 0, LSB-first, to match the previous intended
 * config (CKP=0 idle-low SCK, CKE=1 → data sampled on the rising/leading edge):
 *
 *   RA5 SPI_MOSI  output   driven before each rising edge
 *   RA6 SPI_MISO  input    sampled at each rising edge
 *   RA7 SPI_CLK   output   idle low; one low→high→low pulse per bit
 *
 * LSB-first matches the Z80 SIO synchronous serializer: bit 0 of each byte is
 * the first wire bit.
 * ---------------------------------------------------------------------------*/

/* Half bit period.  ~2 us each side → ~4 us/bit → ~250 kHz is the target rate.
 * TEMPORARILY slowed to 100 us each side → ~5 kHz so a single transaction is a
 * ~100 ms burst that a slow scope can catch, and the RA7-clock/RA6-MISO phase
 * relationship is easy to read.  Restore to 2u after timing is validated. */
#define SPI_BIT_HALF_US  100u

static void spi_gpio_init(void)
{
    SPI_CLK_ANSEL  = 0;
    SPI_MOSI_ANSEL = 0;
    SPI_MISO_ANSEL = 0;

    SPI_CLK_LAT  = 0;   /* idle low (CKP=0) */
    SPI_CLK_TRIS = 0;   /* output */

    SPI_MOSI_LAT  = 1;  /* idle high / marking */
    SPI_MOSI_TRIS = 0;  /* output */

    SPI_MISO_TRIS = 1;  /* input */
}

/* ---------------------------------------------------------------------------
 * Bit-banged SPI byte exchange, Mode 0, LSB-first.
 *
 * Always succeeds (no hardware flag to stall on), so it returns true and the
 * SPI_TX/RX_TIMEOUT error paths are no longer reachable; receive-window
 * framing errors are reported by the higher-level decode.
 * ---------------------------------------------------------------------------*/
static bool spi_xfer(uint8_t out, uint8_t *in)
{
    uint8_t i;
    uint8_t inval = 0u;

    dbg_spi_xfer_attempt_count++;
    dbg_last_spi_out = out;

    for (i = 0u; i < 8u; i++) {
        /* Present this bit (LSB first) while SCK is low, then let both our
         * MOSI and the SIO's TxD settle for the whole low phase. */
        SPI_MOSI_LAT = (uint8_t)(out & 1u);
        out >>= 1;
        __delay_us(SPI_BIT_HALF_US);

        /* Sample MISO at the END of the low phase, just before the rising
         * edge.  By now the SIO's TxD has been stable for a full half-bit no
         * matter which clock edge the SIO updates it on, so this avoids
         * sampling a same-edge transition.  Bit alignment is recovered by the
         * software preamble hunt, which tolerates a constant bit offset. */
        if (SPI_MISO_PORT)
            inval |= (uint8_t)(1u << i);

        /* Rising edge: SIO latches our MOSI. */
        SPI_CLK_LAT = 1;
        __delay_us(SPI_BIT_HALF_US);

        /* Falling edge: end of this bit. */
        SPI_CLK_LAT = 0;
    }

    SPI_MOSI_LAT = 1;   /* return MOSI to marking idle between bytes */

    *in = inval;
    dbg_last_spi_in = inval;
    dbg_spi_txb_write_count++;
    dbg_spi_xfer_count++;
    return true;
}

/* ---------------------------------------------------------------------------
 * SPI / CS helpers
 * ---------------------------------------------------------------------------*/

void sdlc_all_deselect(void)
{
    BULK_CS_LAT        = BULK_CS_IDLE;
    CMD_CS_LAT         = CMD_CS_IDLE;   /* RA1 high: MISO buffer off, SIO desel */
    USB_BRIDGE_CS_LAT  = USB_BRIDGE_CS_IDLE;
    SD_CS_LAT          = SD_CS_IDLE;
}

void sdlc_command_select(void)
{
    /* RA1 low for the whole transaction: enables the 74HC125 SIO->MISO buffer
     * and drives SIO1/B /SYNCB low (External Sync mode = SYNC is an input). */
    CMD_CS_LAT = CMD_CS_ASSERTED;
    TRACE(TRACE_COMMAND_SELECT_LOW, 0, 0, 0);
}

void sdlc_command_deselect(void)
{
    CMD_CS_LAT = CMD_CS_IDLE;
}

/* Prepare the Command-channel bit-banged SPI bus.
 *
 * With software SPI there is no rate/mode register to program: timing is set
 * by SPI_BIT_HALF_US and the Mode-0 LSB-first sequence in spi_xfer().  This
 * just deasserts all CS lines and parks the bus pins at their idle levels
 * (SCK low, MOSI high) so no consumer sees a spurious edge.
 */
void sdlc_command_config_250khz(void)
{
    sdlc_all_deselect();
    spi_gpio_init();
    TRACE(TRACE_SPI_CONFIG_COMMAND, 0, 0, 0);
}

void sdlc_spi_init(void)
{
    /* CS lines were deasserted in platform_init(); set up the bit-bang bus
     * pins and idle levels.  Do not assert any CS here. */
    spi_gpio_init();
    sdlc_command_config_250khz();
}

/* ---------------------------------------------------------------------------
 * External Sync framing
 *
 * SDLC cannot be used on this board (SIO /SYNCB is an MCU-owned net that also
 * gates the MISO buffer), so the SIO runs in External Sync mode and the bytes
 * on the wire are transparent: no flags, no zero-bit stuffing, no hardware FCS.
 * Framing is just a sync preamble (for byte alignment) followed by the fixed
 * 32-byte IOC frame.  No CRC/FCS is used for this bring-up.
 *
 * IOC_SYNC_PREAMBLE: a byte the receiver hunts for at any bit offset to find
 * byte alignment.  PING/RESET payloads are mostly zero, so 0x7E (six
 * consecutive 1s) cannot occur inside the frame; a longer/unique preamble may
 * be needed once arbitrary payloads are carried.
 * ---------------------------------------------------------------------------*/
#define IOC_SYNC_PREAMBLE  0x7Eu

bool sdlc_send_frame(IocChannel ch, const IocFrame *frame)
{
    uint8_t i;
    uint8_t ignored;

    if (ch != IO_CH_COMMAND)
        return false;

    sdlc_command_select();

    /* Preamble byte for the host to byte-align on. */
    if (!spi_xfer(IOC_SYNC_PREAMBLE, &ignored)) {
        sdlc_command_deselect();
        TRACE(TRACE_SDLC_TX_ERROR, dbg_last_sdlc_error, 0, 0);
        return false;
    }

    /* 32 transparent frame bytes (spi_xfer drives each byte LSB-first). */
    for (i = 0u; i < IOC_FRAME_SIZE; i++) {
        if (!spi_xfer(frame->bytes[i], &ignored)) {
            sdlc_command_deselect();
            TRACE(TRACE_SDLC_TX_ERROR, dbg_last_sdlc_error, i, 0);
            return false;
        }
    }

    sdlc_command_deselect();
    return true;
}

/* ---------------------------------------------------------------------------
 * RX — bit stream decode
 *
 * Clock in SDLC_RX_WINDOW_BYTES SPI bytes with MOSI held 0xFF (marking idle).
 * Then decode the received bit stream: hunt for the optional software preamble
 * and copy the following 32 transparent bytes to the caller.
 * ---------------------------------------------------------------------------*/

static uint8_t rx_buf[SDLC_RX_WINDOW_BYTES];

/* Extract one wire bit from rx_buf at bit index wi.
 * SPI is configured LSB-first, so bit 0 of each received byte arrived first
 * on the wire.  The bit index maps directly: byte = wi/8, bit = wi%8.
 */
#define RX_WIRE_BIT(wi) \
    (uint8_t)((rx_buf[(wi) >> 3] >> ((wi) & 7u)) & 1u)

/* Locate the IOC_SYNC_PREAMBLE byte in the wire bit stream at ANY bit offset
 * using an 8-bit shift register.  Returns the bit index ONE PAST the preamble
 * (i.e. the first bit of the frame payload), or 0xFFFF if not found.
 *
 * The shift register accumulates bits LSB-first, matching how the bytes are
 * transmitted, so after 8 matching bits it holds the preamble value.
 */
static uint16_t find_preamble(uint16_t start)
{
    uint16_t wi;
    uint8_t  sreg = 0u;
    for (wi = start; wi < (uint16_t)(SDLC_RX_WINDOW_BYTES * 8u); wi++) {
        sreg = (uint8_t)((sreg >> 1) | (RX_WIRE_BIT(wi) << 7u));
        if (wi >= (start + 7u) && sreg == IOC_SYNC_PREAMBLE)
            return (uint16_t)(wi + 1u);   /* first payload bit */
    }
    return 0xFFFFu;
}

bool sdlc_recv_frame(IocChannel ch, IocFrame *frame, uint16_t timeout_bytes)
{
    uint16_t pre_end;
    uint8_t  i;
    uint8_t  k;

    (void)timeout_bytes;   /* Phase 1: full window always clocked */

    TRACE(TRACE_SDLC_RX_START, ch, (uint8_t)SDLC_RX_WINDOW_BYTES, 0);
    dbg_last_sdlc_error = DBG_SDLC_ERR_NONE;

    if (ch != IO_CH_COMMAND) {
        dbg_last_sdlc_error = DBG_SDLC_ERR_BAD_CHANNEL;
        return false;
    }

    /* Clock in the receive window.  Output 0xFF (marking idle) on MOSI so the
     * Z80 SIO's RXD sees a benign idle pattern during the receive phase. */
    sdlc_command_select();
    for (i = 0u; i < SDLC_RX_WINDOW_BYTES; i++) {
        if (!spi_xfer(0xFFu, &rx_buf[i])) {
            sdlc_command_deselect();
            TRACE(TRACE_SDLC_RX_TIMEOUT, dbg_last_sdlc_error, i, 0);
            return false;
        }
        dbg_sdlc_rx_count++;
    }
    sdlc_command_deselect();

    /* Snapshot the raw MISO window for the debugger: how many bytes were
     * non-idle (!=0xFF), how many equal the preamble, plus the first 16 raw
     * bytes. */
    dbg_rx_nonff_count = 0u;
    dbg_rx_flag_count  = 0u;
    for (i = 0u; i < SDLC_RX_WINDOW_BYTES; i++) {
        if (i < 16u)
            dbg_rx_snapshot[i] = rx_buf[i];
        if (rx_buf[i] != 0xFFu)
            dbg_rx_nonff_count++;
        if (rx_buf[i] == IOC_SYNC_PREAMBLE)
            dbg_rx_flag_count++;
    }

    /* External Sync: transparent bytes.  Hunt the preamble at any bit offset
     * to establish byte alignment. */
    pre_end = find_preamble(0u);
    if (pre_end == 0xFFFFu) {
        dbg_last_sdlc_error = DBG_SDLC_ERR_NO_OPEN_FLAG;   /* no preamble seen */
        TRACE(TRACE_SDLC_RX_TIMEOUT, dbg_last_sdlc_error, 0, 0);
        return true;
    }
    TRACE(TRACE_SDLC_RX_GOT_FLAG, (uint8_t)pre_end, (uint8_t)(pre_end >> 8), 0);

    /* The 32 frame bytes must fit in the remaining window. */
    if ((uint16_t)(pre_end + (uint16_t)(IOC_FRAME_SIZE * 8u)) >
        (uint16_t)(SDLC_RX_WINDOW_BYTES * 8u)) {
        dbg_last_sdlc_error = DBG_SDLC_ERR_BAD_LENGTH;
        TRACE(TRACE_SDLC_RX_BAD_FRAME, dbg_last_sdlc_error, 0, 0);
        return false;
    }

    /* Read 32 transparent bytes (LSB-first) immediately after the preamble. */
    for (i = 0u; i < IOC_FRAME_SIZE; i++) {
        uint8_t  b    = 0u;
        uint16_t base = (uint16_t)(pre_end + (uint16_t)i * 8u);
        for (k = 0u; k < 8u; k++) {
            if (RX_WIRE_BIT(base + k))
                b |= (uint8_t)(1u << k);
        }
        frame->bytes[i] = b;
    }

    TRACE(TRACE_SDLC_RX_GOT_FRAME, frame->bytes[IOC_OFF_CLASS], frame->bytes[IOC_OFF_SEQ], 0);
    return true;
}

#endif /* !IOC_TRANSPORT_BITBANG */
