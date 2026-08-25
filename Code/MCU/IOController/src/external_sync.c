#include <xc.h>
#include <stdint.h>
#include <stdbool.h>
#include "external_sync.h"
#include "timebase.h"
#include "config.h"
#include "sio_link.h"

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
void sio_link_pins_to_lat(void)
{
    /* Park the idle levels the bit-bang path expects before handing the pins
     * back, so the changeover produces no edge on either wire. */
    LINK_CLK_LAT  = 0;
    LINK_DOUT_LAT = 1;
    SIO_SCK_PPS  = SIO_PPS_SRC_LAT;
    SIO_MOSI_PPS = SIO_PPS_SRC_LAT;
}

void sio_link_pins_to_spi(void)
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

void sio_link_set_baud(uint8_t baud)
{
    SPI2CON0bits.EN = 0;
    SPI2BAUD = baud;
    SPI2CON0bits.EN = 1;
    PIR5bits.SPI2RXIF = 0;
}

/* Empty both FIFOs.
 *
 * Nothing else resets the 2-byte receive FIFO, so a transfer left half-finished
 * by an earlier aborted transaction leaves a stale byte in it.  The next
 * sio_link_exchange() would then return that stale byte immediately without clocking
 * anything, and every byte after it would be shifted by one position -- the
 * frame decoder would never find a valid header, the PIC would send no reply,
 * and the host would report a transport timeout with its buffer still A5h.
 *
 * CLRBF is the XC8 header's name for the bit the datasheet calls CLB. */
void sio_link_clear_fifos(void)
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
bool sio_link_exchange(uint8_t out, uint8_t *in)
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
void sio_link_byte_gap(void)
{
    __delay_us(EXTSYNC_BYTE_GAP_US);
}

static const uint16_t link_crc16_nibble[16] = {
    0x0000u, 0x1021u, 0x2042u, 0x3063u,
    0x4084u, 0x50A5u, 0x60C6u, 0x70E7u,
    0x8108u, 0x9129u, 0xA14Au, 0xB16Bu,
    0xC18Cu, 0xD1ADu, 0xE1CEu, 0xF1EFu
};

uint16_t sio_link_crc16_update(uint16_t crc, uint8_t data)
{
    crc = (uint16_t)((crc << 4) ^ link_crc16_nibble[((crc >> 12) ^ (data >> 4)) & 0x0Fu]);
    crc = (uint16_t)((crc << 4) ^ link_crc16_nibble[((crc >> 12) ^ (data & 0x0Fu)) & 0x0Fu]);
    return crc;
}

void sio_link_write_data_bit(uint8_t bit)
{
    LINK_DOUT_LAT = (uint8_t)(bit & 1u);
}

/* Hand-clock one byte with that channel's /SYNC dropped inside `drop_bit`.
 * Declared in sio_link.h, where the contract and the per-channel drop_bit are
 * documented.  Shared by both lanes.
 *
 * The bit shape is the electrical protocol, not incidental control flow:
 *
 *   - bits before drop_bit are clocked with /SYNC still high
 *   - drop_bit is clocked, then /SYNC is driven low before the falling edge
 *   - the remaining bits are clocked with /SYNC low
 *   - bits 0 and 1 carry no trailing gap; bits 2..7 do
 *
 * That last asymmetry is deliberate and matches the working bench timing.  An
 * earlier refactor into generic bit helpers changed the setup/sync shape and
 * the host saw only untouched A5h bytes in its receive buffer -- so this loop
 * is written to reproduce the proven waveform exactly, and the `i >= 2u` gap
 * condition is load-bearing.  Verify against a scope, not against taste.
 */
void sio_link_clock_sync_byte(uint8_t value, SioLinkChannel channel,
                              uint8_t drop_bit)
{
    uint8_t i;

    for (i = 0u; i < 8u; i++) {
        sio_link_write_data_bit(value & 1u);
        value >>= 1;
        __delay_us(EXTSYNC_BIT_DELAY_US);
        LINK_CLK_LAT = 1;
        __delay_us(EXTSYNC_BIT_DELAY_US);

        if (i == drop_bit) {
            /* Between this bit's rising and falling edge. */
            if (channel == SIO_LINK_CH_BULK)
                SYNCA_LAT = SYNCA_ASSERTED;
            else
                SYNCB_LAT = SYNCB_ASSERTED;
            __delay_us(EXTSYNC_BIT_DELAY_US);
        }

        LINK_CLK_LAT = 0;

        if (i >= 2u)
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
    return (value == CMD_PING) ||
           (value == CMD_RESET) ||
           (value == CMD_SD_READ) ||
           (value == CMD_BULK_TEST) ||
           (value == CMD_SD_READ_BULK) ||
           (value == CMD_SD_WRITE_BULK) ||
           (value == CMD_SD_READ_REC) ||
           (value == CMD_SD_WRITE_REC) ||
           (value == CMD_SD_FLUSH) ||
           (value == CMD_PROFILE) ||
           (value == CMD_XFER_STATUS);
}

/* Verify the CRC of a candidate frame sitting at an arbitrary bit offset.
 *
 * This is the authority for dispatch.  The header checks below only exist to
 * keep the search from computing a CRC at all 128 candidate offsets, which
 * would cost about 2 ms per window; a header match narrows it to typically one.
 */
static bool frame_crc_ok(uint16_t bit_index)
{
    uint16_t crc = 0u;
    uint16_t wire;
    uint8_t  i;

    for (i = 0u; i < IOC_CRC_COVERED; i++)
        crc = sio_link_crc16_update(crc,
                  read_wire_byte((uint16_t)(bit_index + ((uint16_t)i * 8u))));

    wire  = (uint16_t)read_wire_byte(
                (uint16_t)(bit_index + ((uint16_t)IOC_OFF_CRC_LO * 8u)));
    wire |= (uint16_t)read_wire_byte(
                (uint16_t)(bit_index + ((uint16_t)IOC_OFF_CRC_HI * 8u))) << 8;

    return wire == crc;
}

static bool find_frame_start(uint16_t *bit_index)
{
    uint16_t start;

    for (start = 0u; start < EXTSYNC_FRAME_SEARCH_BITS; start++) {
        uint8_t cls = read_wire_byte(start);
        uint8_t status = read_wire_byte((uint16_t)(start + 16u));
        uint8_t len = read_wire_byte((uint16_t)(start + 24u));

        if (!is_command_class(cls))
            continue;

        /* The sequence number is now rolling, so it can no longer be matched
         * against a constant -- that evidence is replaced by the CRC below,
         * which is worth far more than the one byte it displaces. */
        if (status != 0x00u)
            continue;

        if (cls == CMD_RESET && len == 0x00u) {
            if (!frame_crc_ok(start))
                continue;
            *bit_index = start;
            return true;
        }

        if (cls == CMD_PING && (len == 0x00u || len == 0x10u)) {
            if (!frame_crc_ok(start))
                continue;
            *bit_index = start;
            return true;
        }

        /* The per-class length match is strict on purpose and is NOT redundant
         * with the class check above.  This loop walks 16 candidate bit offsets
         * and takes the first that looks like a header, so the header fields
         * are the only thing distinguishing the correct bit alignment from a
         * wrong one.  Every field that stops matching makes a false lock more
         * likely.  Adding a command means adding a clause here, deliberately. */
        if (cls == CMD_SD_READ && len == 0x00u) {
            if (!frame_crc_ok(start))
                continue;
            *bit_index = start;
            return true;
        }

        if (cls == CMD_BULK_TEST && (len == 0x00u || len == 0x02u)) {
            if (!frame_crc_ok(start))
                continue;
            *bit_index = start;
            return true;
        }

        if (cls == CMD_SD_READ_BULK && len == IOC_SD_LBA_PAYLOAD_LEN) {
            if (!frame_crc_ok(start))
                continue;
            *bit_index = start;
            return true;
        }

        if (cls == CMD_SD_WRITE_BULK && len == IOC_SD_LBA_PAYLOAD_LEN) {
            if (!frame_crc_ok(start))
                continue;
            *bit_index = start;
            return true;
        }

        /* Record-addressed access.  These were added with the SD storage
         * driver and NOT registered here, which is what this comment block
         * exists to prevent: find_frame_start() is the only path that checks a
         * candidate alignment against the CRC, so an unregistered class could
         * never be framed by it.  Those commands fell through to the alignment
         * heuristics in copy_received_frame(), which key on 7Eh -- a byte the
         * BIOS never sends, but which the host SIO emits as WR7 transmitter-
         * underrun fill.  The result was a frame locked on noise, dispatched
         * unverified: the PIC read a garbage class and answered
         * RSP_UNKNOWN_COMMAND with the host's class byte sitting in the
         * sequence slot, and the host rejected the reply as BAD_SEQ. */
        if ((cls == CMD_SD_READ_REC || cls == CMD_SD_WRITE_REC) &&
            len == IOC_SD_RECORD_PAYLOAD_LEN) {
            if (!frame_crc_ok(start))
                continue;
            *bit_index = start;
            return true;
        }

        if (cls == CMD_PROFILE && len == 0x00u) {
            if (!frame_crc_ok(start))
                continue;
            *bit_index = start;
            return true;
        }

        if (cls == CMD_SD_FLUSH && len == 0x00u) {
            if (!frame_crc_ok(start))
                continue;
            *bit_index = start;
            return true;
        }

        if (cls == CMD_XFER_STATUS && len == 0x00u) {
            if (!frame_crc_ok(start))
                continue;
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

/* Extract the request frame from the capture window.
 *
 * THE CRC DECIDES.  Every path below proposes a candidate alignment and then
 * asks frame_crc_ok() whether it is right; none of them may accept a guess on
 * its own authority.  The first two are shortcuts that skip the bit search when
 * the frame happens to sit on a byte boundary -- they save the ~2 ms a full
 * search costs, and nothing else.
 *
 * They used to return without checking anything, and that was the bug behind a
 * whole class of storage failures.  Both key on 7Eh, described here as an
 * alignment byte "the BIOS currently clocks before the mailbox".  The BIOS does
 * not, and never did in this firmware's lifetime; the only 7Eh on the wire is
 * WR7, the host SIO's transmitter-underrun FILL character, which appears
 * wherever the Z80 momentarily runs dry.  So the shortcuts were hunting through
 * a 48-byte window for a byte that marks nothing, and handing whatever followed
 * it straight to dispatch.
 *
 * A frame that validates nowhere returns false, and the caller sends no reply.
 * That is the right failure: the host waits out its receive timeout and retries
 * with RTS already released, which costs one transaction.  Answering a frame
 * that was never sent costs lane synchronisation, which costs everything after
 * it.
 */
/* The bit offset that last decoded a frame successfully.
 *
 * Frames arrive at a stable alignment -- the host asserts RTS and the PIC
 * starts clocking, so the phase relationship barely moves between transactions.
 * Trying the previous answer first turns the common case from a 128-offset walk
 * into a single 30-byte CRC.  It cannot cause a mis-decode: the CRC still has to
 * pass, exactly as it does for every other candidate.
 *
 * Measured before this existed: the alignment search was 4946 ms of a 9526 ms
 * SC2 load, 52% of the wall time. */
static uint16_t last_good_bit;
static bool     last_good_valid;

/* Nothing but idle in the window.
 *
 * The PIC enters service_command_request() on a LEVEL, so it clocks a window
 * whenever /SIO1B_INT is low -- including when the host has asserted but not yet
 * started transmitting.  Those windows read as all-FFh marking idle, contain no
 * frame, and used to cost a full failed search: alignment scan over 384 bits,
 * then every one of 128 offsets, matching nothing.  That is the expensive half
 * of the 4946 ms, because it happened about once per real transaction.
 *
 * A real frame always contains a zero bit somewhere -- the class, the length and
 * the status byte cannot all be FFh -- so this rejects only windows that could
 * never decode. */
static bool window_is_idle(void)
{
    uint8_t i;

    for (i = 0u; i < EXTSYNC_RX_WINDOW_BYTES; i++) {
        if (rx_window[i] != 0xFFu)
            return false;
    }

    return true;
}

static bool copy_received_frame(IocFrame *frame)
{
    uint16_t start;
    uint8_t i;

    if (window_is_idle())
        return false;

    /* Last known alignment, CRC-verified like any other candidate. */
    if (last_good_valid &&
        ((uint16_t)(last_good_bit + (uint16_t)(IOC_FRAME_SIZE * 8u)) <=
         (uint16_t)(EXTSYNC_RX_WINDOW_BYTES * 8u)) &&
        frame_crc_ok(last_good_bit)) {
        for (i = 0u; i < IOC_FRAME_SIZE; i++)
            frame->bytes[i] =
                read_wire_byte((uint16_t)(last_good_bit + (uint16_t)i * 8u));
        return true;
    }

    /* Shortcut: an alignment byte opens the window, so the frame would start on
     * the next byte boundary.  read_wire_byte(8n) == rx_window[n], so bit 8
     * names exactly that candidate. */
    if (rx_window[0] == EXTSYNC_ALIGNMENT_BYTE && frame_crc_ok(8u)) {
        for (i = 0u; i < IOC_FRAME_SIZE; i++)
            frame->bytes[i] = rx_window[(uint8_t)(i + 1u)];
        last_good_bit   = 8u;
        last_good_valid = true;
        return true;
    }

    /* Shortcut: an alignment byte somewhere further in.  Bounds first -- a
     * start that late leaves no room for 32 bytes, and frame_crc_ok() would
     * read off the end of the window. */
    start = find_alignment_end();
    if ((start != 0xFFFFu) &&
        ((uint16_t)(start + (uint16_t)(IOC_FRAME_SIZE * 8u)) <=
         (uint16_t)(EXTSYNC_RX_WINDOW_BYTES * 8u)) &&
        frame_crc_ok(start)) {
        for (i = 0u; i < IOC_FRAME_SIZE; i++)
            frame->bytes[i] =
                read_wire_byte((uint16_t)(start + (uint16_t)i * 8u));
        last_good_bit   = start;
        last_good_valid = true;
        return true;
    }

    /* The authority: walk every bit offset at which a frame still fits and take
     * the first whose header matches a registered command AND whose CRC
     * verifies. */
    if (!find_frame_start(&start))
        return false;

    for (i = 0u; i < IOC_FRAME_SIZE; i++)
        frame->bytes[i] = read_wire_byte((uint16_t)(start + (uint16_t)i * 8u));

    last_good_bit   = start;
    last_good_valid = true;

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
    sio_link_clear_fifos();
    sio_link_pins_to_lat();
}

bool external_sync_receive(IocFrame *frame)
{
    uint8_t i;
    uint16_t t_rx;
    uint16_t t_dec;
    bool     ok;

    bus_select_siob();
    sync_assert();

    /* Receive needs no intra-byte GPIO at all: /SYNCB is asserted for the whole
     * window and MOSI just idles marking, which is what shifting out FFh does.
     * So the entire window goes through the SPI module. */
    sio_link_set_baud(EXTSYNC_SPI_BAUD);
    sio_link_clear_fifos();
    sio_link_pins_to_spi();
    t_rx = uprof_now();
    for (i = 0u; i < EXTSYNC_RX_WINDOW_BYTES; i++) {
        if (!sio_link_exchange(0xFFu, &rx_window[i])) {
            /* Give the pins and the bus back before bailing out, or the next
             * transaction starts with RB1/RB3 still routed to the module. */
            sio_link_pins_to_lat();
            sync_release();
            bus_release_siob();
            return false;
        }
        sio_link_byte_gap();
    }
    sio_link_pins_to_lat();
    uprof_add(UPROF_RX, t_rx);

    sync_release();
    bus_release_siob();

    t_dec = uprof_now();
    ok = copy_received_frame(frame);
    uprof_add(UPROF_DECODE, t_dec);

    return ok;
}

/* Send one 32-byte reply mailbox.
 *
 * Walkthrough:
 *
 *   1. Wait briefly so the BIOS has switched SIO1/B from request transmit to
 *      reply receive, then take the shared bus with SIOB_CS.
 *   2. Send two setup clocks while /SYNCB is idle high.
 *   3. Clock the 32 reply bytes.  sio_link_clock_sync_byte() asserts /SYNCB at the
 *      proven bit position and keeps it low after that.
 *   4. Clock one trailing FFh byte.  The SIO exposes the final received byte to
 *      RR0/RX-ready only after additional clocks arrive on this board.
 *   5. Release /SYNCB and SIOB_CS, and return SIO_MOSI to marking idle high.
 */
void external_sync_send(IocFrame *frame)
{
    uint8_t i;
    uint16_t crc = 0u;

    /* Stamp the CRC before a single bit goes out.  The host rejects any reply
     * that fails it, which is what stops a mis-framed or stale reply being
     * accepted as the answer to the outstanding request. */
    for (i = 0u; i < IOC_CRC_COVERED; i++)
        crc = sio_link_crc16_update(crc, frame->bytes[i]);
    frame->bytes[IOC_OFF_CRC_LO] = (uint8_t)crc;
    frame->bytes[IOC_OFF_CRC_HI] = (uint8_t)(crc >> 8);

    __delay_us(EXTSYNC_REPLY_GUARD_US);
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

    /* Lead the reply with the 7Eh alignment byte.
     *
     * The Z80 BIOS reply scanner (IOC_CMD_RECV_SYNC) locks onto a frame start
     * only on 7Eh or on a hard-coded RSP_PING (81h).  A bare mailbox therefore
     * works for PING and nothing else: any other response class is scanned past
     * and reported as IOC_XPORT_BAD_FRAME with the host's buffer untouched.
     * Emitting 7Eh puts every reply on the BIOS's generic path, so response
     * classes can be added with no host-side change.
     *
     * The byte count is unaffected.  Both shapes sit at the same margin against
     * the SIO's one-byte RX-ready lag:
     *
     *   bare:     32 + 1 flush = 33 clocked, 32 readable; host reads 1 + 31
     *   preamble: 1 + 32 + 1   = 34 clocked, 33 readable; host reads 1 + 32
     *
     * This byte is also the bit-banged one.  sio_link_clock_sync_byte() drops /SYNCB
     * between bit 1's rising and falling edges, and no hardware shift register
     * can be interrupted at that point.  Every later call to sync_assert() is a
     * no-op because /SYNCB is already low, which is what lets the whole 32-byte
     * mailbox move to the SPI module without changing an edge that matters.
     *
     * If PING regresses, this is the change to back out: restore
     * the call below with frame->bytes[0] and start the loop that follows at
     * i = 1. */
    sio_link_clock_sync_byte(EXTSYNC_ALIGNMENT_BYTE, SIO_LINK_CH_COMMAND,
                             EXTSYNC_SYNC_DROP_BIT);

    sio_link_set_baud(EXTSYNC_SPI_BAUD);
    sio_link_clear_fifos();
    sio_link_pins_to_spi();
    for (i = 0u; i < IOC_FRAME_SIZE; i++) {
        uint8_t discard;

        if (!sio_link_exchange(frame->bytes[i], &discard))
            break;
        sio_link_byte_gap();
    }

    /* The SIO reports the final byte ready only after more clock edges arrive.
     * One trailing marking byte flushes byte 31 to the Z80 poller.  The host
     * does not consume this idle byte as part of the fixed 32-byte frame. */
    {
        uint8_t discard;
        (void)sio_link_exchange(0xFFu, &discard);
    }
    sio_link_pins_to_lat();

    sync_release();
    LINK_DOUT_LAT = 1;
    bus_release_siob();
}
