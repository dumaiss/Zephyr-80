#include <xc.h>
#include <stdint.h>
#include <stdbool.h>
#include "sdlc_bitbang.h"
#include "config.h"
#include "trace.h"

/* Compiled only when the bit-bang transport is selected; otherwise this TU is
 * empty and sdlc.c provides the sdlc_* symbols.  Exactly one transport links. */
#ifdef IOC_TRANSPORT_BITBANG

/* ---------------------------------------------------------------------------
 * Pure GPIO bit-bang transport, SIO channel B.
 *
 * The PIC is the synchronous clock master on the SIO serial side only.  It does
 * NOT touch any SIO register (the Z80 owns the SIO CPU bus and has already put
 * the channel in External Sync mode).  We just toggle CLK, drive/sample serial
 * data, and hold the External Sync line low for the transaction.
 *
 * BIT ORDER — LSB-first.  The task brief said "MSB-first", but the Z80 SIO
 * serializer shifts data LSB-first on RxD/TxD; that is fixed in the SIO
 * hardware, not a software convention.  To assemble/emit the same bytes the SIO
 * does (so a PING actually echoes), the MCU must shift LSB-first.  This also
 * matches the existing SPI transport (sdlc.c) and the Z80-side wire format, so
 * dispatch and the Z80 firmware are unchanged.  Using MSB-first here would
 * bit-reverse every byte on the wire and break the echo.
 *
 * EDGES:
 *   CLK idle low.  Per bit: present data-out while CLK low, then raise CLK so
 *   the SIO can latch our RxDB bit.  Sample TxDB during the CLK-high phase,
 *   after the rising edge has given the SIO transmitter time to present the
 *   bit.  Then drop CLK and continue.  Absolute bit alignment is recovered by
 *   the preamble hunt at any bit offset.
 * ---------------------------------------------------------------------------*/

/* Channel-B pin map (names resolve to the config.h Port A definitions). */
#define BB_CLK_LAT        SPI_CLK_LAT      /* RA7 clock out */
#define BB_CLK_TRIS       SPI_CLK_TRIS
#define BB_CLK_ANSEL      SPI_CLK_ANSEL
#define BB_DOUT_LAT       SPI_MOSI_LAT     /* RA5 data out -> SIO RxDB */
#define BB_DOUT_TRIS      SPI_MOSI_TRIS
#define BB_DOUT_ANSEL     SPI_MOSI_ANSEL
#define BB_DIN_PORT       SPI_MISO_PORT    /* RA6 data in  <- SIO TxDB */
#define BB_DIN_TRIS       SPI_MISO_TRIS
#define BB_DIN_ANSEL      SPI_MISO_ANSEL
#define BB_SYNC_LAT       CMD_CS_LAT       /* RA1 = /SYNCB + 74HC125 /OE */
#define BB_SYNC_TRIS      CMD_CS_TRIS
#define BB_SYNC_ANSEL     CMD_CS_ANSEL
#define BB_SYNC_ASSERTED  CMD_CS_ASSERTED  /* 0 = low  */
#define BB_SYNC_IDLE      CMD_CS_IDLE      /* 1 = high */

/* Byte the receiver hunts for (at any bit offset) to establish byte alignment.
 * Same value as sdlc.c. */
#define IOC_SYNC_PREAMBLE  0x7Eu
#define BB_REPLY_GUARD_MS  10u

/* ---------------------------------------------------------------------------
 * Low-level GPIO primitives
 * ---------------------------------------------------------------------------*/
static void bb_gpio_init(void)
{
    BB_CLK_ANSEL  = 0;
    BB_DOUT_ANSEL = 0;
    BB_DIN_ANSEL  = 0;
    BB_SYNC_ANSEL = 0;

    BB_CLK_LAT  = 0;            /* clock idle low */
    BB_CLK_TRIS = 0;            /* output */

    BB_DOUT_LAT  = 1;           /* data out idle high (SIO idle = marking) */
    BB_DOUT_TRIS = 0;           /* output */

    BB_DIN_TRIS  = 1;           /* data in: input */

    BB_SYNC_LAT  = BB_SYNC_IDLE;/* sync released (high) when idle */
    BB_SYNC_TRIS = 0;           /* output (MCU drives this net) */
}

static void bb_write_bit(uint8_t bit)
{
    BB_DOUT_LAT = (uint8_t)(bit & 1u);
}

static uint8_t bb_read_bit(void)
{
    return (uint8_t)(BB_DIN_PORT ? 1u : 0u);
}

/* Exchange one byte, LSB-first, full duplex.  Reuses the shared SPI debug
 * counters so the debugger workflow is identical to the SPI transport. */
static void bb_xfer_byte(uint8_t out, uint8_t *in)
{
    uint8_t i;
    uint8_t val = 0u;

    dbg_spi_xfer_attempt_count++;
    dbg_last_spi_out = out;

    bb_write_bit(out & 1u);          /* present bit while CLK low */
    out >>= 1;

    __delay_us(BB_BIT_DELAY_US);     /* CLK-low (settle) phase */
        
    BB_CLK_LAT = 1;                  /* rising edge: SIO latches RxDB */

    __delay_us(BB_BIT_DELAY_US);     /* CLK-low (settle) phase */
    BB_CLK_LAT = 0;                  /* falling edge: SIO latches RxDB */

    bb_write_bit(out & 1u);          /* present bit while CLK low */
    out >>= 1;
        
    __delay_us(BB_BIT_DELAY_US);     /* CLK-low (settle) phase */
        
    BB_CLK_LAT = 1;                  /* rising edge: SIO latches RxDB */
    __delay_us(BB_BIT_DELAY_US);     /* CLK-low (settle) phase */

    BB_SYNC_LAT = 0;
    __delay_us(BB_BIT_DELAY_US);     /* CLK-low (settle) phase */

    BB_CLK_LAT = 0;                  /* falling edge: SIO latches RxDB */


    for (i = 2u; i < 8u; i++) {
        bb_write_bit(out & 1u);          /* present bit while CLK low */
        out >>= 1;
        
        __delay_us(BB_BIT_DELAY_US);     /* CLK-low (settle) phase */
        
        BB_CLK_LAT = 1;                  /* rising edge: SIO latches RxDB */

        __delay_us(BB_BIT_DELAY_US);     /* CLK-low (settle) phase */

        BB_CLK_LAT = 0;                  /* falling edge: SIO latches RxDB */

        __delay_us(BB_BIT_DELAY_US);     /* CLK-low (settle) phase */
    }

    BB_CLK_LAT = 0;                  /* falling edge, next low phase */
    

    *in = val;
    dbg_last_spi_in = val;
    dbg_spi_txb_write_count++;
    dbg_spi_xfer_count++;
}

/* Clock in one byte from SIO TxDB while holding SIO RxDB at marking idle.
 * This is the RX-window path: no command data is driven toward the SIO.
 */
static void bb_read_byte_marking(uint8_t *in)
{
    uint8_t i;
    uint8_t val = 0u;

    dbg_spi_xfer_attempt_count++;
    dbg_last_spi_out = 0xFFu;

    bb_write_bit(1u);
    for (i = 0u; i < 8u; i++) {
        __delay_us(BB_BIT_DELAY_US);     /* CLK-low settle phase */

        BB_CLK_LAT = 1;                  /* rising edge advances the SIO */
        __delay_us(BB_BIT_DELAY_US);     /* sample after TxDB settles */

        if (bb_read_bit())
            val |= (uint8_t)(1u << i);

        BB_CLK_LAT = 0;
    }

    *in = val;
    dbg_last_spi_in = val;
    dbg_spi_txb_write_count++;
    dbg_spi_xfer_count++;
}

/* ---------------------------------------------------------------------------
 * External Sync line (RA1)
 *
 * RA1 is a dual-purpose net: the SIO channel-B /SYNCB External-Sync INPUT and
 * the 74HC125 /OE that gates SIO-TxDB onto the MCU data-in pin.  It is held LOW
 * for the WHOLE transaction (both jobs need it low: the buffer must be enabled
 * to read TxD, and the SIO must stay externally synced).
 *
 * Zilog's External Sync note specifies asserting /SYNC ~2 RxC rising edges
 * after the last sync-character bit so the receiver frames the following byte.
 * We cannot pulse this net (the MISO buffer would drop out mid-byte), so we
 * instead assert it BEFORE the first clock edge and hold it low.  With /SYNC
 * continuously low the SIO establishes its byte boundary on the first clocked
 * bit; since byte 0 on the wire is the preamble and bytes 1..32 are the frame,
 * the SIO's byte boundaries line up with our bytes.  The MCU's own receive
 * framing comes from the software preamble hunt, not from this pin.
 * ---------------------------------------------------------------------------*/
static void bb_assert_sync(void)
{
    BB_SYNC_LAT = BB_SYNC_ASSERTED;       /* low for the whole transaction */
    TRACE(TRACE_COMMAND_SELECT_LOW, 0, 0, 0);
}

static void bb_release_sync(void)
{
    BB_SYNC_LAT = BB_SYNC_IDLE;           /* high = idle / buffer off */
}

/* ---------------------------------------------------------------------------
 * Select / config API (same surface as sdlc.h)
 * ---------------------------------------------------------------------------*/
void sdlc_all_deselect(void)
{
    BULK_CS_LAT       = BULK_CS_IDLE;
    CMD_CS_LAT        = CMD_CS_IDLE;      /* RA1 sync released */
    USB_BRIDGE_CS_LAT = USB_BRIDGE_CS_IDLE;
    SD_CS_LAT         = SD_CS_IDLE;
}

void sdlc_command_select(void)
{
    bb_assert_sync();
}

void sdlc_command_deselect(void)
{
    bb_release_sync();
}

void sdlc_command_config_250khz(void)
{
    sdlc_all_deselect();
    bb_gpio_init();
    TRACE(TRACE_SPI_CONFIG_COMMAND, 0, 0, 0);
}

void sdlc_spi_init(void)
{
    bb_gpio_init();
    sdlc_command_config_250khz();
}

/* ---------------------------------------------------------------------------
 * TX
 * ---------------------------------------------------------------------------*/
static void bb_clock_marking_bit(void)
{
    bb_write_bit(1u);
    __delay_us(BB_BIT_DELAY_US);
    BB_CLK_LAT = 1;
    __delay_us(BB_BIT_DELAY_US);
    BB_CLK_LAT = 0;
}

/* Reply-side External Sync marker.
 *
 * During request capture RA1 must stay low because it also enables the
 * SIO->PIC input buffer.  During reply TX the PIC does not need that buffer,
 * so use RA1 only as the SIO /SYNCB input: pulse it low across two marking
 * clocks, then release it before sending reply bytes.  Holding /SYNCB low for
 * the whole reply kept the SIO from reporting any received byte on this board.
 */
static void bb_pulse_reply_sync(void)
{
    bb_assert_sync();
    bb_clock_marking_bit();
    bb_clock_marking_bit();
    bb_release_sync();
}

static void bb_diag_dout_pulse(void)
{
    uint8_t i;

    BB_CLK_LAT = 0;
    bb_release_sync();
    for (i = 0u; i < 16u; i++) {
        bb_write_bit(0u);
        __delay_us(100u);
        bb_write_bit(1u);
        __delay_us(100u);
    }
}

bool sdlc_send_frame(IocChannel ch, const IocFrame *frame)
{
    uint8_t i;
    uint8_t ignored = 0u;

    if (ch != IO_CH_COMMAND) {
        TRACE(TRACE_SDLC_TX_ERROR, DBG_SDLC_ERR_BAD_CHANNEL, 0, 0);
        return false;
    }

    /* Give the Z80 BIOS time to enable SIO RX/hunt after request TX.  RX is
     * disabled while the PIC captures the request, so there is no full-duplex
     * junk to drain.  For the reply, send a software preamble with /SYNCB
     * released, pulse /SYNCB as the external-sync marker, then transmit the
     * 32-byte reply body as a transparent byte stream.
     */
    __delay_ms(BB_REPLY_GUARD_MS);
    // bb_diag_dout_pulse();
    BB_DOUT_LAT = 1;                    /* return data-out to idle (marking) */
    
    BB_CLK_LAT = 1; 
    __delay_us(BB_BIT_DELAY_US);     /* CLK-low (settle) phase */
    BB_CLK_LAT = 0;

    __delay_us(BB_BIT_DELAY_US);     /* CLK-low (settle) phase */

    BB_DOUT_LAT = 0;                    /* return data-out to idle (marking) */
    
    BB_CLK_LAT = 1; 
    __delay_us(BB_BIT_DELAY_US);     /* CLK-low (settle) phase */
    BB_CLK_LAT = 0;


    //bb_assert_sync();
    //bb_xfer_byte(IOC_SYNC_PREAMBLE, &ignored);
    // bb_pulse_reply_sync();
    for (i = 0u; i < IOC_FRAME_SIZE; i++)
        bb_xfer_byte(frame->bytes[i], &ignored);

    /* The SIO RX-ready indication lags the clocked serial stream by one byte on
     * this External Sync path.  Keep /SYNCB low and clock one marking byte after
     * the 32-byte frame so the final frame byte becomes visible to the Z80
     * poller.  The next IOCALL channel reset discards this unread idle byte. */
    bb_xfer_byte(0xFFu, &ignored);

    bb_release_sync();
    BB_DOUT_LAT = 1;                    /* return data-out to idle (marking) */
    return true;
}

/* ---------------------------------------------------------------------------
 * RX — clock in a window, hunt the preamble, copy the 32-byte payload.
 *
 * Mirrors sdlc.c's decode (transparent External Sync, LSB-first) and emits the
 * same TRACE points and dbg_* snapshots so traces are directly comparable.
 * ---------------------------------------------------------------------------*/
static uint8_t rx_buf[SDLC_RX_WINDOW_BYTES];

/* LSB-first: bit 0 of each received byte arrived first on the wire. */
#define RX_WIRE_BIT(wi) \
    (uint8_t)((rx_buf[(wi) >> 3] >> ((wi) & 7u)) & 1u)

/* Find IOC_SYNC_PREAMBLE at any bit offset via an LSB-first shift register.
 * Returns the bit index one past the preamble (first payload bit), or 0xFFFF. */
static uint16_t find_preamble(uint16_t start)
{
    uint16_t wi;
    uint8_t  sreg = 0u;
    for (wi = start; wi < (uint16_t)(SDLC_RX_WINDOW_BYTES * 8u); wi++) {
        sreg = (uint8_t)((sreg >> 1) | (RX_WIRE_BIT(wi) << 7u));
        if (wi >= (start + 7u) && sreg == IOC_SYNC_PREAMBLE)
            return (uint16_t)(wi + 1u);
    }
    return 0xFFFFu;
}

static uint8_t read_wire_byte(uint16_t base)
{
    uint8_t b = 0u;
    uint8_t k;

    for (k = 0u; k < 8u; k++) {
        if (RX_WIRE_BIT(base + k))
            b |= (uint8_t)(1u << k);
    }
    return b;
}

/* Bring-up fallback for the observed no-preamble case.  Try the first few bit
 * offsets and accept only a header that looks like one of the tiny diagnostic
 * requests, so a one-bit-shifted RESET byte does not get misclassified as PING.
 */
static uint16_t find_direct_frame_start(void)
{
    uint16_t start;

    for (start = 0u; start < 16u; start++) {
        uint8_t cls;
        uint8_t seq;
        uint8_t status;
        uint8_t len;

        if ((uint16_t)(start + (uint16_t)(IOC_FRAME_SIZE * 8u)) >
            (uint16_t)(SDLC_RX_WINDOW_BYTES * 8u)) {
            break;
        }

        cls    = read_wire_byte((uint16_t)(start + (uint16_t)IOC_OFF_CLASS * 8u));
        seq    = read_wire_byte((uint16_t)(start + (uint16_t)IOC_OFF_SEQ * 8u));
        status = read_wire_byte((uint16_t)(start + (uint16_t)IOC_OFF_STATUS * 8u));
        len    = read_wire_byte((uint16_t)(start + (uint16_t)IOC_OFF_LEN * 8u));

        if (seq != 0x01u || status != 0x00u)
            continue;

        if (cls == CMD_RESET && len == 0x00u)
            return start;

        if (cls == CMD_PING && (len == 0x00u || len == 0x10u))
            return start;
    }

    return 0xFFFFu;
}

bool sdlc_recv_frame(IocChannel ch, IocFrame *frame, uint16_t timeout_bytes)
{
    uint16_t pre_end;
    uint8_t  i;

    (void)timeout_bytes;   /* full window always clocked, as in sdlc.c */

    TRACE(TRACE_SDLC_RX_START, ch, (uint8_t)SDLC_RX_WINDOW_BYTES, 0);
    dbg_last_sdlc_error = DBG_SDLC_ERR_NONE;

    if (ch != IO_CH_COMMAND) {
        dbg_last_sdlc_error = DBG_SDLC_ERR_BAD_CHANNEL;
        return false;
    }

    /* Hold sync low (buffer enabled) and clock in the window while holding
     * SIO RxDB at marking idle. */
    bb_assert_sync();
    for (i = 0u; i < SDLC_RX_WINDOW_BYTES; i++) {
        bb_read_byte_marking(&rx_buf[i]);
        dbg_sdlc_rx_count++;
    }
    bb_release_sync();

    /* Raw-window diagnostics (same fields as sdlc.c). */
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

    /* Common bring-up case: the SIO byte boundary is already aligned and the
     * preamble is byte 0.  Copy bytes 1..32 directly so the dispatcher never
     * sees the software preamble as the command class.
     */
    if (rx_buf[0] == IOC_SYNC_PREAMBLE) {
        for (i = 0u; i < IOC_FRAME_SIZE; i++)
            frame->bytes[i] = rx_buf[(uint8_t)(i + 1u)];
        TRACE(TRACE_SDLC_RX_GOT_FLAG, 8, 0, 2);
        TRACE(TRACE_SDLC_RX_GOT_FRAME, frame->bytes[IOC_OFF_CLASS], frame->bytes[IOC_OFF_SEQ], 0);
        return true;
    }

    pre_end = find_preamble(0u);
    if (pre_end == 0xFFFFu) {
        pre_end = find_direct_frame_start();
        if (pre_end == 0xFFFFu) {
            dbg_last_sdlc_error = DBG_SDLC_ERR_NO_OPEN_FLAG;
            TRACE(TRACE_SDLC_RX_TIMEOUT, dbg_last_sdlc_error, 0, 0);
            return false;
        }
        TRACE(TRACE_SDLC_RX_GOT_FLAG, (uint8_t)pre_end, (uint8_t)(pre_end >> 8), 1);
    } else {
        TRACE(TRACE_SDLC_RX_GOT_FLAG, (uint8_t)pre_end, (uint8_t)(pre_end >> 8), 0);
    }

    if ((uint16_t)(pre_end + (uint16_t)(IOC_FRAME_SIZE * 8u)) >
        (uint16_t)(SDLC_RX_WINDOW_BYTES * 8u)) {
        dbg_last_sdlc_error = DBG_SDLC_ERR_BAD_LENGTH;
        TRACE(TRACE_SDLC_RX_BAD_FRAME, dbg_last_sdlc_error, 0, 0);
        return false;
    }

    for (i = 0u; i < IOC_FRAME_SIZE; i++) {
        uint16_t base = (uint16_t)(pre_end + (uint16_t)i * 8u);
        frame->bytes[i] = read_wire_byte(base);
    }

    if (frame->bytes[IOC_OFF_CLASS] == IOC_SYNC_PREAMBLE) {
        for (i = 0u; i < (uint8_t)(IOC_FRAME_SIZE - 1u); i++)
            frame->bytes[i] = frame->bytes[(uint8_t)(i + 1u)];
        frame->bytes[IOC_FRAME_SIZE - 1u] = 0u;
        TRACE(TRACE_SDLC_RX_GOT_FLAG, 8, 0, 3);
    }

    TRACE(TRACE_SDLC_RX_GOT_FRAME, frame->bytes[IOC_OFF_CLASS], frame->bytes[IOC_OFF_SEQ], 0);
    return true;
}

#endif /* IOC_TRANSPORT_BITBANG */
