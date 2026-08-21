#include <xc.h>
#include <stdint.h>
#include <stdbool.h>
#include "external_sync.h"
#include "config.h"

/* ---------------------------------------------------------------------------
 * Z80 SIO1/B External Sync link
 * ---------------------------------------------------------------------------
 *
 * This file is the whole PIC-side transport.  It deliberately does not contain
 * SIO register writes; the Z80 BIOS owns the SIO CPU bus.  The PIC is only the
 * serial-side clock/data/sync source.
 *
 * The SIO is configured by the BIOS for External Sync.  In that mode /SYNCB is
 * an input.  The external logic must provide the sync edge that tells the SIO
 * where character assembly starts.
 *
 * Clock and data are the board-wide shared bus, so SIOB_CS must be asserted for
 * the whole transaction: it is what puts SIO1/B on SIO_MISO and keeps the SD
 * card, USB bridge and controller latch off it.  /SYNCB is a separate pin and
 * carries only the sync strobe.
 *
 * Wire direction names are from the PIC's point of view:
 *
 *   SIO_MOSI -> SIO RXDB   reply data sent to the Z80
 *   SIO_MISO <- SIO TXDB   request data received from the Z80
 *   SIO_SCK  -> SIO RXTXCB shared receive/transmit clock
 *   SYNCB    -> SIO /SYNCB External Sync strobe
 *   SIOB_CS  -> bus select for SIO1/B
 *
 * Bytes on the Z80 SIO serial pins are LSB-first.  Do not change the bit order
 * to match a CPU-memory dump; the SIO shifts bit 0 first on the wire.
 */

/* Pin aliases for the SIO1/B External Sync link. */
#define LINK_CLK_LAT        SIO_SCK_LAT
#define LINK_CLK_TRIS       SIO_SCK_TRIS
#define LINK_CLK_ANSEL      SIO_SCK_ANSEL

#define LINK_DOUT_LAT       SIO_MOSI_LAT
#define LINK_DOUT_TRIS      SIO_MOSI_TRIS
#define LINK_DOUT_ANSEL     SIO_MOSI_ANSEL

#define LINK_DIN_PORT       SIO_MISO_PORT
#define LINK_DIN_TRIS       SIO_MISO_TRIS
#define LINK_DIN_ANSEL      SIO_MISO_ANSEL

#define LINK_SYNC_LAT       SYNCB_LAT
#define LINK_SYNC_TRIS      SYNCB_TRIS
#define LINK_SYNC_ANSEL     SYNCB_ANSEL

static uint8_t rx_window[EXTSYNC_RX_WINDOW_BYTES];

static void sync_assert(void)
{
    LINK_SYNC_LAT = SYNCB_ASSERTED;
}

static void sync_release(void)
{
    LINK_SYNC_LAT = SYNCB_IDLE;
}

static void bus_select_siob(void)
{
    SIOB_CS_LAT = SIOB_CS_ASSERTED;
}

static void bus_release_siob(void)
{
    SIOB_CS_LAT = SIOB_CS_IDLE;
}

/* ---------------------------------------------------------------------------
 * SPI2 link
 * ---------------------------------------------------------------------------
 *
 * SPI2SCKPPS and SPI2SDIPPS are left at their reset values: they already point
 * at RB3 and RB2, which is how this board is wired.  Only the output routes are
 * claimed, and only while a transfer is in flight -- the bit-banged phase of a
 * reply needs LATB to own RB1/RB3.
 *
 * Master mode reads SCK back through SPI2SCKPPS, so the input mapping matters
 * even though the module is the one generating the clock.  That is why the
 * output route alone is not enough.
 */
static void spi_pins_to_lat(void)
{
    /* Park the idle levels the bit-bang path expects before handing the pins
     * back, so the changeover produces no edge on either wire. */
    LINK_CLK_LAT  = 0;
    LINK_DOUT_LAT = 1;
    SIO_SCK_PPS  = SIO_PPS_SRC_LAT;
    SIO_MOSI_PPS = SIO_PPS_SRC_LAT;
}

static void spi_pins_to_spi(void)
{
    /* CKP = 0 means the module also idles SCK low, so this matches the level
     * LATB3 is already holding and the switch is glitch-free. */
    SIO_SCK_PPS  = EXTSYNC_PPS_SRC_SPI2_SCK;
    SIO_MOSI_PPS = EXTSYNC_PPS_SRC_SPI2_SDO;
}

static void spi_init(void)
{
    SPI2CON0 = 0x00;
    SPI2CON0bits.MST   = 1;   /* master: the PIC supplies every clock edge */
    /* With TXR/RXR = 1/1 and BMODE = 1 the datasheet's Full-Duplex mode applies:
     * "data will be transmitted/received as soon as the SPIxTXB register is
     * written to".  SPIxTCNT is explicitly optional in that combination, so
     * this code never writes it -- which also avoids the documented roll-over
     * when the counter decrements past zero. */
    SPI2CON0bits.BMODE = 1;   /* SPI2TWIDTH = 0 (reset) => full-byte transfers */
    SPI2CON0bits.LSBF  = 1;   /* the Z80 SIO shifts bit 0 first on the wire */

    SPI2CON1 = 0x00;
    SPI2CON1bits.CKP = 0;     /* clock idles low */
    SPI2CON1bits.CKE = 1;     /* data changes on the falling edge  -> Mode 0 */
    SPI2CON1bits.SMP = 0;     /* sample input mid data-output time */

    SPI2CON2 = 0x00;
    SPI2CON2bits.TXR = 1;     /* full duplex: a write to TXB starts a transfer */
    SPI2CON2bits.RXR = 1;     /* and the received byte lands in RXB */

    SPI2CLK  = EXTSYNC_SPI_CLKSEL;
    SPI2BAUD = EXTSYNC_SPI_BAUD;

    SPI2CON0bits.EN = 1;
}

/* Empty both FIFOs.
 *
 * Nothing else resets the 2-byte receive FIFO, so a transfer left half-finished
 * by an earlier aborted transaction leaves a stale byte in it.  The next
 * spi_exchange() would then return that stale byte immediately without clocking
 * anything, and every byte after it would be shifted by one position -- the
 * frame decoder would never find a valid header, the PIC would send no reply,
 * and the host would report a transport timeout with its buffer still A5h.
 *
 * CLRBF is the XC8 header's name for the bit the datasheet calls CLB. */
static void spi_clear_fifos(void)
{
    SPI2STATUSbits.CLRBF = 1;
    PIR5bits.SPI2RXIF = 0;
}

/* Exchange one byte.  Returns false if the module did not complete in time.
 *
 * Completion is detected with SPI2RXIF, NOT SPI2STATUS.RXBF.  The receive side
 * is a 2-byte FIFO and RXBF means "receive buffer is *full*", so after a
 * single-byte exchange the occupancy is 1 of 2 and RXBF never sets.  Waiting on
 * it spins until the timeout on every byte, even though the byte was clocked
 * out correctly -- the transfer starts as soon as SPIxTXB is written, so the
 * wire looks fine while the firmware concludes it failed.
 *
 * SPI2RXIF sets when a byte lands in the FIFO at all, which is the condition
 * this code actually cares about.  Reading SPI2RXB clears it.  Interrupts are
 * disabled globally, so the flag is used purely as status.
 *
 * The wait is bounded so a module that never completes cannot wedge the PIC in
 * a spin loop until reset. */
static bool spi_exchange(uint8_t out, uint8_t *in)
{
    uint16_t guard = EXTSYNC_SPI_TIMEOUT_LOOPS;

    SPI2TXB = out;

    while (!PIR5bits.SPI2RXIF) {
        if (--guard == 0u)
            return false;
    }

    *in = SPI2RXB;
    return true;
}

/* Hold the byte rate at what the bit-banged path produced.  The Z80 BIOS polls
 * RR0 in software behind a 3-byte FIFO, so byte rate -- not bit rate -- is what
 * keeps the host from overrunning.  See external_sync.h for the arithmetic. */
static void spi_byte_gap(void)
{
    __delay_us(EXTSYNC_BYTE_GAP_US);
}

static void write_data_bit(uint8_t bit)
{
    LINK_DOUT_LAT = (uint8_t)(bit & 1u);
}

/* Clock one reply byte into the SIO receiver.
 *
 * This is intentionally open-coded.  The placement of sync_assert() is part of
 * the electrical protocol, not incidental control flow:
 *
 *   - bit 0 is clocked while /SYNCB is still high
 *   - bit 1 is clocked, then /SYNCB is driven low before the falling clock edge
 *   - bits 2..7 are clocked while /SYNCB remains low
 *
 * That sequence matches the working bench timing for External Sync on SIO1/B.
 * A previous refactor into generic bit helpers changed the setup/sync shape and
 * the host saw only untouched A5h bytes in its receive buffer.
 */
static void clock_reply_byte(uint8_t value)
{
    uint8_t i;

    write_data_bit(value & 1u);
    value >>= 1;
    __delay_us(EXTSYNC_BIT_DELAY_US);
    LINK_CLK_LAT = 1;
    __delay_us(EXTSYNC_BIT_DELAY_US);
    LINK_CLK_LAT = 0;

    write_data_bit(value & 1u);
    value >>= 1;
    __delay_us(EXTSYNC_BIT_DELAY_US);
    LINK_CLK_LAT = 1;
    __delay_us(EXTSYNC_BIT_DELAY_US);
    sync_assert();
    __delay_us(EXTSYNC_BIT_DELAY_US);
    LINK_CLK_LAT = 0;

    for (i = 2u; i < 8u; i++) {
        write_data_bit(value & 1u);
        value >>= 1;
        __delay_us(EXTSYNC_BIT_DELAY_US);
        LINK_CLK_LAT = 1;
        __delay_us(EXTSYNC_BIT_DELAY_US);
        LINK_CLK_LAT = 0;
        __delay_us(EXTSYNC_BIT_DELAY_US);
    }
}

static uint8_t rx_wire_bit(uint16_t bit_index)
{
    return (uint8_t)((rx_window[bit_index >> 3] >> (bit_index & 7u)) & 1u);
}

/* Read a byte from an arbitrary bit position in rx_window[].
 *
 * The PIC capture window is byte-oriented only because the PIC samples eight
 * clocks at a time.  The Z80 request itself may start at any bit phase inside
 * that window, so receive decode works in bit indexes and reconstructs
 * LSB-first bytes from there.
 */
static uint8_t read_wire_byte(uint16_t bit_index)
{
    uint8_t i;
    uint8_t value = 0u;

    for (i = 0u; i < 8u; i++) {
        if (rx_wire_bit((uint16_t)(bit_index + i)))
            value |= (uint8_t)(1u << i);
    }

    return value;
}

static bool is_command_class(uint8_t value)
{
    return (value == CMD_PING) || (value == CMD_RESET);
}

static bool find_frame_start(uint16_t *bit_index)
{
    uint16_t start;

    for (start = 0u; start < 16u; start++) {
        uint8_t cls = read_wire_byte(start);
        uint8_t seq = read_wire_byte((uint16_t)(start + 8u));
        uint8_t status = read_wire_byte((uint16_t)(start + 16u));
        uint8_t len = read_wire_byte((uint16_t)(start + 24u));

        if (!is_command_class(cls))
            continue;

        if (seq != 0x01u || status != 0x00u)
            continue;

        if (cls == CMD_RESET && len == 0x00u) {
            *bit_index = start;
            return true;
        }

        if (cls == CMD_PING && (len == 0x00u || len == 0x10u)) {
            *bit_index = start;
            return true;
        }
    }

    return false;
}

/* Locate the host alignment byte.
 *
 * The BIOS currently clocks a single 7Eh byte before the 32-byte mailbox.  The
 * PIC does not require it for framing, but accepting it keeps the firmware
 * compatible with the current BIOS while the host side is still in bring-up.
 * This scan is a byte-alignment aid only; it is not packet framing.
 */
static uint16_t find_alignment_end(void)
{
    uint16_t bit_index;
    uint8_t shift = 0u;

    for (bit_index = 0u;
         bit_index < (uint16_t)(EXTSYNC_RX_WINDOW_BYTES * 8u);
         bit_index++) {
        shift = (uint8_t)((shift >> 1) | (rx_wire_bit(bit_index) << 7u));
        if (bit_index >= 7u && shift == EXTSYNC_ALIGNMENT_BYTE)
            return (uint16_t)(bit_index + 1u);
    }

    return 0xFFFFu;
}

static bool copy_received_frame(IocFrame *frame)
{
    uint16_t start;
    uint8_t i;

    if (rx_window[0] == EXTSYNC_ALIGNMENT_BYTE) {
        for (i = 0u; i < IOC_FRAME_SIZE; i++)
            frame->bytes[i] = rx_window[(uint8_t)(i + 1u)];
        return true;
    }

    start = find_alignment_end();
    if (start == 0xFFFFu) {
        if (!find_frame_start(&start))
            return false;
    }

    if ((uint16_t)(start + (uint16_t)(IOC_FRAME_SIZE * 8u)) >
        (uint16_t)(EXTSYNC_RX_WINDOW_BYTES * 8u)) {
        return false;
    }

    for (i = 0u; i < IOC_FRAME_SIZE; i++) {
        frame->bytes[i] =
            read_wire_byte((uint16_t)(start + (uint16_t)i * 8u));
    }

    if (frame->bytes[IOC_OFF_CLASS] == EXTSYNC_ALIGNMENT_BYTE) {
        for (i = 0u; i < (uint8_t)(IOC_FRAME_SIZE - 1u); i++)
            frame->bytes[i] = frame->bytes[(uint8_t)(i + 1u)];
        frame->bytes[IOC_FRAME_SIZE - 1u] = 0u;
    }

    return true;
}

void external_sync_init(void)
{
    LINK_SYNC_ANSEL = 0;
    LINK_CLK_ANSEL  = 0;
    LINK_DOUT_ANSEL = 0;
    LINK_DIN_ANSEL  = 0;

    SIOB_CS_ANSEL = 0;
    SIOB_CS_LAT   = SIOB_CS_IDLE;
    SIOB_CS_TRIS  = 0;

    LINK_SYNC_LAT  = SYNCB_IDLE;
    LINK_SYNC_TRIS = 0;

    LINK_CLK_LAT  = 0;
    LINK_CLK_TRIS = 0;

    LINK_DOUT_LAT  = 1;
    LINK_DOUT_TRIS = 0;

    LINK_DIN_TRIS = 1;

    /* TRIS still governs the pin drivers under PPS, so the directions set above
     * remain correct once the SPI module owns RB1/RB3. */
    spi_init();
    spi_clear_fifos();
    spi_pins_to_lat();
}

bool external_sync_receive(IocFrame *frame)
{
    uint8_t i;

    bus_select_siob();
    sync_assert();

    /* Receive needs no intra-byte GPIO at all: /SYNCB is asserted for the whole
     * window and MOSI just idles marking, which is what shifting out FFh does.
     * So the entire window goes through the SPI module. */
    spi_clear_fifos();
    spi_pins_to_spi();
    for (i = 0u; i < EXTSYNC_RX_WINDOW_BYTES; i++) {
        if (!spi_exchange(0xFFu, &rx_window[i])) {
            /* Give the pins and the bus back before bailing out, or the next
             * transaction starts with RB1/RB3 still routed to the module. */
            spi_pins_to_lat();
            sync_release();
            bus_release_siob();
            return false;
        }
        spi_byte_gap();
    }
    spi_pins_to_lat();

    sync_release();
    bus_release_siob();

    return copy_received_frame(frame);
}

/* Send one 32-byte reply mailbox.
 *
 * Walkthrough:
 *
 *   1. Wait briefly so the BIOS has switched SIO1/B from request transmit to
 *      reply receive, then take the shared bus with SIOB_CS.
 *   2. Send two setup clocks while /SYNCB is idle high.
 *   3. Clock the 32 reply bytes.  clock_reply_byte() asserts /SYNCB at the
 *      proven bit position and keeps it low after that.
 *   4. Clock one trailing FFh byte.  The SIO exposes the final received byte to
 *      RR0/RX-ready only after additional clocks arrive on this board.
 *   5. Release /SYNCB and SIOB_CS, and return SIO_MOSI to marking idle high.
 */
void external_sync_send(const IocFrame *frame)
{
    uint8_t i;

    __delay_ms(EXTSYNC_REPLY_GUARD_MS);
    bus_select_siob();
    LINK_DOUT_LAT = 1;

    LINK_CLK_LAT = 1;
    __delay_us(EXTSYNC_BIT_DELAY_US);
    LINK_CLK_LAT = 0;

    __delay_us(EXTSYNC_BIT_DELAY_US);

    LINK_DOUT_LAT = 0;
    LINK_CLK_LAT = 1;
    __delay_us(EXTSYNC_BIT_DELAY_US);
    LINK_CLK_LAT = 0;

    /* Reply byte 0 is always bit-banged.  clock_reply_byte() drops /SYNCB
     * between bit 1's rising and falling edges, and no hardware shift register
     * can be interrupted at that point.  Every later call to sync_assert() is a
     * no-op because /SYNCB is already low, which is what lets bytes 1..31 move
     * to the SPI module without changing a single edge that matters. */
    clock_reply_byte(frame->bytes[0]);

    spi_clear_fifos();
    spi_pins_to_spi();
    for (i = 1u; i < IOC_FRAME_SIZE; i++) {
        uint8_t discard;

        if (!spi_exchange(frame->bytes[i], &discard))
            break;
        spi_byte_gap();
    }

    /* The SIO reports the final byte ready only after more clock edges arrive.
     * One trailing marking byte flushes byte 31 to the Z80 poller.  The host
     * does not consume this idle byte as part of the fixed 32-byte frame. */
    {
        uint8_t discard;
        (void)spi_exchange(0xFFu, &discard);
    }
    spi_pins_to_lat();

    sync_release();
    LINK_DOUT_LAT = 1;
    bus_release_siob();
}
