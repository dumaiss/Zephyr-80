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

static void write_data_bit(uint8_t bit)
{
    LINK_DOUT_LAT = (uint8_t)(bit & 1u);
}

static uint8_t read_data_bit(void)
{
    return (uint8_t)(LINK_DIN_PORT ? 1u : 0u);
}

static uint8_t clock_input_byte_marking(void)
{
    uint8_t i;
    uint8_t value = 0u;

    write_data_bit(1u);

    for (i = 0u; i < 8u; i++) {
        __delay_us(EXTSYNC_BIT_DELAY_US);
        LINK_CLK_LAT = 1;
        __delay_us(EXTSYNC_BIT_DELAY_US);

        if (read_data_bit())
            value |= (uint8_t)(1u << i);

        LINK_CLK_LAT = 0;
    }

    return value;
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
}

bool external_sync_receive(IocFrame *frame)
{
    uint8_t i;

    bus_select_siob();
    sync_assert();
    for (i = 0u; i < EXTSYNC_RX_WINDOW_BYTES; i++)
        rx_window[i] = clock_input_byte_marking();
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

    for (i = 0u; i < IOC_FRAME_SIZE; i++)
        clock_reply_byte(frame->bytes[i]);

    /* The SIO reports the final byte ready only after more clock edges arrive.
     * One trailing marking byte flushes byte 31 to the Z80 poller.  The host
     * does not consume this idle byte as part of the fixed 32-byte frame. */
    clock_reply_byte(0xFFu);

    sync_release();
    LINK_DOUT_LAT = 1;
    bus_release_siob();
}
