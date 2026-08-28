#include <xc.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
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

/* Character synchronisation, once.
 *
 * The SIO manual is explicit: in External Sync mode "the SYNC input must be
 * held Low until character synchronization is lost", and assembly of received
 * data continues until the SIO is reset, until the receiver is disabled (by
 * command or by DCD under Auto Enables), or until the CPU sets Enter Hunt
 * Phase.  That list is exhaustive -- a receive OVERRUN is not on it, so the
 * Z80's receiver may overrun harmlessly while it transmits a request and keep
 * its character alignment.
 *
 * So /SYNCB is asserted once, at the moment the boundary is established, and
 * never released.  Releasing it per transaction -- which this firmware used to
 * do -- forced the host back into Hunt every time and made the hand-clocked
 * sync byte necessary on every reply.
 *
 * Establishing the boundary still needs a falling edge at a precise bit
 * position, so the bit-banged sequence survives for exactly one reply.  After
 * that link_synced is set and replies are pure SPI.
 *
 * ALIGNMENT RULE for everything that follows: once the host is synchronised it
 * counts eight clocks per character, so the PIC must never emit a number of
 * clock edges that is not a multiple of eight.  The two "setup clocks" in the
 * reply path are exactly such an emission, which is why they now run only in
 * the sync-establishing branch. */
static bool link_synced;

/* Timer1 counts the physical RB3/SCK rising edges.  Unlike a software exchange
 * counter, this sees PPS handover glitches and clocks emitted by the SPI module
 * itself.  The pin input buffer remains available while RB3 is an output. */
static uint16_t last_rx_edges;
static uint16_t last_tx_edges;

static void edge_counter_init(void)
{
    T1CON    = 0x00u;             /* stopped, 1:1 prescale, synchronized */
    T1GCON   = 0x00u;             /* no gate */
    T1CKIPPS = SIO_SCK_T1CKIPPS; /* RB3 */
    T1CLK    = 0x00u;             /* clock from T1CKIPPS */
    TMR1     = 0u;
    T1CON    = 0x02u;             /* RD16, still stopped */
}

static void edge_counter_start(void)
{
    T1CONbits.ON = 0;
    TMR1 = 0u;
    T1CONbits.ON = 1;
}

static uint16_t edge_counter_stop(void)
{
    T1CONbits.ON = 0;
    return TMR1;
}

static void sync_release(void)
{
    LINK_SYNC_LAT = SYNCB_IDLE;
}

void external_sync_request_resync(void)
{
    /* A fresh falling edge cannot exist unless /SYNCB is first returned high.
     * LINK_SYNC is the explicit recovery operation, so breaking the persistent
     * low level here is intentional: the next reply re-establishes the boundary
     * and then holds /SYNCB low again. */
    sync_release();
    link_synced = false;
}

uint16_t external_sync_last_rx_edges(void)
{
    return last_rx_edges;
}

uint16_t external_sync_last_tx_edges(void)
{
    return last_tx_edges;
}

bool external_sync_is_established(void)
{
    return link_synced;
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
    LINK_CLK_LAT  = 1;
    LINK_DOUT_LAT = 1;
    SIO_SCK_PPS  = SIO_PPS_SRC_LAT;
    SIO_MOSI_PPS = SIO_PPS_SRC_LAT;
}

void sio_link_pins_to_spi(void)
{
    /* CKP = 1 means the module also idles SCK high, matching both LATB3 and
     * the 100k pull-up on each gated SIO clock. */
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
    /* Mode 3: idle high, data changes on falling edges, sample on rising.
     *
     * The high idle is mandatory on this board.  /SIOB_CS and /SIOA_CS gate
     * SCK through a 74AHCT125, and each gated output has a 100k pull-up.  With
     * CKP = 0, releasing either select changed the SIO clock from driven low to
     * pulled high: one extra receive-clock edge per phase, two per command
     * transaction. */
    SPI2CON1bits.CKP = 1;     /* clock idles high */
    SPI2CON1bits.CKE = 0;     /* data changes on the falling edge -> Mode 3 */
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

/* Byte-wide CCITT table.  The former nibble table saved 480 bytes of flash,
 * but XC8's unoptimised 16-bit shifts made it the largest measured cost in a
 * 512-byte bulk reply.  One lookup also fits naturally inside SPI2's shift
 * time when bulk_run_send() streams its CRC. */
static const uint16_t link_crc16_byte[256] = {
    0x0000u, 0x1021u, 0x2042u, 0x3063u, 0x4084u, 0x50A5u, 0x60C6u, 0x70E7u,
    0x8108u, 0x9129u, 0xA14Au, 0xB16Bu, 0xC18Cu, 0xD1ADu, 0xE1CEu, 0xF1EFu,
    0x1231u, 0x0210u, 0x3273u, 0x2252u, 0x52B5u, 0x4294u, 0x72F7u, 0x62D6u,
    0x9339u, 0x8318u, 0xB37Bu, 0xA35Au, 0xD3BDu, 0xC39Cu, 0xF3FFu, 0xE3DEu,
    0x2462u, 0x3443u, 0x0420u, 0x1401u, 0x64E6u, 0x74C7u, 0x44A4u, 0x5485u,
    0xA56Au, 0xB54Bu, 0x8528u, 0x9509u, 0xE5EEu, 0xF5CFu, 0xC5ACu, 0xD58Du,
    0x3653u, 0x2672u, 0x1611u, 0x0630u, 0x76D7u, 0x66F6u, 0x5695u, 0x46B4u,
    0xB75Bu, 0xA77Au, 0x9719u, 0x8738u, 0xF7DFu, 0xE7FEu, 0xD79Du, 0xC7BCu,
    0x48C4u, 0x58E5u, 0x6886u, 0x78A7u, 0x0840u, 0x1861u, 0x2802u, 0x3823u,
    0xC9CCu, 0xD9EDu, 0xE98Eu, 0xF9AFu, 0x8948u, 0x9969u, 0xA90Au, 0xB92Bu,
    0x5AF5u, 0x4AD4u, 0x7AB7u, 0x6A96u, 0x1A71u, 0x0A50u, 0x3A33u, 0x2A12u,
    0xDBFDu, 0xCBDCu, 0xFBBFu, 0xEB9Eu, 0x9B79u, 0x8B58u, 0xBB3Bu, 0xAB1Au,
    0x6CA6u, 0x7C87u, 0x4CE4u, 0x5CC5u, 0x2C22u, 0x3C03u, 0x0C60u, 0x1C41u,
    0xEDAEu, 0xFD8Fu, 0xCDECu, 0xDDCDu, 0xAD2Au, 0xBD0Bu, 0x8D68u, 0x9D49u,
    0x7E97u, 0x6EB6u, 0x5ED5u, 0x4EF4u, 0x3E13u, 0x2E32u, 0x1E51u, 0x0E70u,
    0xFF9Fu, 0xEFBEu, 0xDFDDu, 0xCFFCu, 0xBF1Bu, 0xAF3Au, 0x9F59u, 0x8F78u,
    0x9188u, 0x81A9u, 0xB1CAu, 0xA1EBu, 0xD10Cu, 0xC12Du, 0xF14Eu, 0xE16Fu,
    0x1080u, 0x00A1u, 0x30C2u, 0x20E3u, 0x5004u, 0x4025u, 0x7046u, 0x6067u,
    0x83B9u, 0x9398u, 0xA3FBu, 0xB3DAu, 0xC33Du, 0xD31Cu, 0xE37Fu, 0xF35Eu,
    0x02B1u, 0x1290u, 0x22F3u, 0x32D2u, 0x4235u, 0x5214u, 0x6277u, 0x7256u,
    0xB5EAu, 0xA5CBu, 0x95A8u, 0x8589u, 0xF56Eu, 0xE54Fu, 0xD52Cu, 0xC50Du,
    0x34E2u, 0x24C3u, 0x14A0u, 0x0481u, 0x7466u, 0x6447u, 0x5424u, 0x4405u,
    0xA7DBu, 0xB7FAu, 0x8799u, 0x97B8u, 0xE75Fu, 0xF77Eu, 0xC71Du, 0xD73Cu,
    0x26D3u, 0x36F2u, 0x0691u, 0x16B0u, 0x6657u, 0x7676u, 0x4615u, 0x5634u,
    0xD94Cu, 0xC96Du, 0xF90Eu, 0xE92Fu, 0x99C8u, 0x89E9u, 0xB98Au, 0xA9ABu,
    0x5844u, 0x4865u, 0x7806u, 0x6827u, 0x18C0u, 0x08E1u, 0x3882u, 0x28A3u,
    0xCB7Du, 0xDB5Cu, 0xEB3Fu, 0xFB1Eu, 0x8BF9u, 0x9BD8u, 0xABBBu, 0xBB9Au,
    0x4A75u, 0x5A54u, 0x6A37u, 0x7A16u, 0x0AF1u, 0x1AD0u, 0x2AB3u, 0x3A92u,
    0xFD2Eu, 0xED0Fu, 0xDD6Cu, 0xCD4Du, 0xBDAAu, 0xAD8Bu, 0x9DE8u, 0x8DC9u,
    0x7C26u, 0x6C07u, 0x5C64u, 0x4C45u, 0x3CA2u, 0x2C83u, 0x1CE0u, 0x0CC1u,
    0xEF1Fu, 0xFF3Eu, 0xCF5Du, 0xDF7Cu, 0xAF9Bu, 0xBFBAu, 0x8FD9u, 0x9FF8u,
    0x6E17u, 0x7E36u, 0x4E55u, 0x5E74u, 0x2E93u, 0x3EB2u, 0x0ED1u, 0x1EF0u
};

uint16_t sio_link_crc16_update(uint16_t crc, uint8_t data)
{
    uint8_t index = (uint8_t)(crc >> 8) ^ data;

    return (uint16_t)((crc << 8) ^ link_crc16_byte[index]);
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
 *   - drop_bit is clocked, then /SYNC is driven low before the next falling edge
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
        LINK_CLK_LAT = 0;
        __delay_us(EXTSYNC_BIT_DELAY_US);

        /* Rising edge: the SIO samples this bit. */
        LINK_CLK_LAT = 1;

        if (i == drop_bit) {
            /* After this bit's rising edge, before the next falling edge. */
            if (channel == SIO_LINK_CH_BULK)
                SYNCA_LAT = SYNCA_ASSERTED;
            else
                SYNCB_LAT = SYNCB_ASSERTED;
            __delay_us(EXTSYNC_BIT_DELAY_US);
        }

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
           (value == CMD_LINK_SYNC) ||
           (value == CMD_XFER_STATUS);
}

/* The bit offset of the last CRC-verified marker.  Requests normally retain a
 * stable transmitter phase, so trying it first avoids a complete bit search. */
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

/* Decode and validate one common packet whose A5 marker begins at start_bit. */
static bool packet_at(uint16_t start_bit, IocFrame *frame)
{
    uint16_t cursor;
    uint16_t end_bit;
    uint16_t length;
    uint16_t crc = 0u;
    uint16_t wire_crc;
    uint8_t type;
    uint8_t sequence;
    uint8_t status;
    uint8_t data_len;
    uint8_t i;

    if (read_wire_byte(start_bit) != IOC_PACKET_SYNC0 ||
        read_wire_byte((uint16_t)(start_bit + 8u)) != IOC_PACKET_SYNC1)
        return false;

    cursor = (uint16_t)(start_bit + 16u);
    length = read_wire_byte(cursor);
    crc = sio_link_crc16_update(crc, (uint8_t)length);
    cursor = (uint16_t)(cursor + 8u);
    length |= (uint16_t)read_wire_byte(cursor) << 8;
    crc = sio_link_crc16_update(crc, (uint8_t)(length >> 8));

    if (length < IOC_PACKET_FIXED_LEN ||
        length > (uint16_t)(IOC_PACKET_FIXED_LEN + IOC_COMMAND_MAX_DATA))
        return false;

    end_bit = (uint16_t)(start_bit +
              (uint16_t)(2u + 2u + length + IOC_PACKET_CRC_BYTES) * 8u);
    if (end_bit > (uint16_t)(EXTSYNC_RX_WINDOW_BYTES * 8u))
        return false;

    cursor = (uint16_t)(cursor + 8u);
    type = read_wire_byte(cursor);
    if (!is_command_class(type))
        return false;
    crc = sio_link_crc16_update(crc, type);

    cursor = (uint16_t)(cursor + 8u);
    sequence = read_wire_byte(cursor);
    crc = sio_link_crc16_update(crc, sequence);

    cursor = (uint16_t)(cursor + 8u);
    status = read_wire_byte(cursor);
    if (status != IOC_STATUS_OK)
        return false;
    crc = sio_link_crc16_update(crc, status);

    data_len = (uint8_t)(length - IOC_PACKET_FIXED_LEN);
    memset(frame->bytes, 0, IOC_FRAME_SIZE);
    frame->bytes[IOC_OFF_CLASS] = type;
    frame->bytes[IOC_OFF_SEQ] = sequence;
    frame->bytes[IOC_OFF_STATUS] = status;
    frame->bytes[IOC_OFF_LEN] = data_len;
    for (i = 0u; i < data_len; i++) {
        cursor = (uint16_t)(cursor + 8u);
        frame->bytes[IOC_OFF_PAYLOAD + i] = read_wire_byte(cursor);
        crc = sio_link_crc16_update(crc,
                                    frame->bytes[IOC_OFF_PAYLOAD + i]);
    }

    cursor = (uint16_t)(cursor + 8u);
    wire_crc = (uint16_t)read_wire_byte(cursor) << 8;
    cursor = (uint16_t)(cursor + 8u);
    wire_crc |= read_wire_byte(cursor);
    return wire_crc == crc;
}

static bool copy_received_frame(IocFrame *frame)
{
    uint16_t start;

    if (window_is_idle())
        return false;

    if (last_good_valid && packet_at(last_good_bit, frame))
        return true;

    for (start = 0u; start < EXTSYNC_FRAME_SEARCH_BITS; start++) {
        if (!packet_at(start, frame))
            continue;

        last_good_bit = start;
        last_good_valid = true;
        return true;
    }

    return false;
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

    LINK_CLK_LAT  = 1;
    LINK_CLK_TRIS = 0;

    LINK_DOUT_LAT  = 1;
    LINK_DOUT_TRIS = 0;

    LINK_DIN_TRIS = 1;

    /* TRIS still governs the pin drivers under PPS, so the directions set above
     * remain correct once the SPI module owns RB1/RB3. */
    spi_init();
    sio_link_clear_fifos();
    sio_link_pins_to_lat();

    /* Left IDLE HIGH here, deliberately.
     *
     * The boundary is established by the FALLING edge of /SYNCB inside the
     * hand-clocked byte, so the line has to be high beforehand for that edge to
     * exist at all.  An earlier version of this asserted it here and never
     * released it, which made sync_assert() inside that byte a no-op and meant
     * the edge was never delivered -- the receiver would have hunted forever.
     *
     * Sequence: idle high from here -> first reply drops it at the proven bit
     * position -> it stays low for the life of the link, which is what the SIO
     * manual requires ("the SYNC input must be held Low until character
     * synchronization is lost"). */
    link_synced = false;
    last_rx_edges = 0u;
    last_tx_edges = 0u;
    edge_counter_init();
    sync_release();
}

bool external_sync_receive(IocFrame *frame)
{
    uint8_t i;
    uint16_t t_rx;
    uint16_t t_dec;
    bool     ok;

    /* Receive needs no intra-byte GPIO at all: MOSI just idles marking, which
     * is what shifting out FFh does.  So the entire request window goes through
     * the SPI module. */
    /* Park HIGH before selecting the SIO.  The gated SIO clock is already high
     * through its pull-up, so enabling the '125 now produces no transition. */
    LINK_CLK_LAT = 1;
    edge_counter_start();
    bus_select_siob();

    sio_link_set_baud(EXTSYNC_SPI_BAUD);
    sio_link_clear_fifos();
    sio_link_pins_to_spi();
    t_rx = uprof_now();
    for (i = 0u; i < EXTSYNC_RX_WINDOW_BYTES; i++) {
        if (!sio_link_exchange(0xFFu, &rx_window[i])) {
            /* Give the pins and the bus back before bailing out, or the next
             * transaction starts with RB1/RB3 still routed to the module. */
            sio_link_pins_to_lat();
            last_rx_edges = edge_counter_stop();
            bus_release_siob();
            return false;
        }
        sio_link_byte_gap();
    }
    sio_link_pins_to_lat();
    last_rx_edges = edge_counter_stop();
    uprof_add(UPROF_RX, t_rx);

    bus_release_siob();

    t_dec = uprof_now();
    ok = copy_received_frame(frame);
    uprof_add(UPROF_DECODE, t_dec);

    return ok;
}

/* Send one common packet mapped from a BIOS-facing mailbox. */
void external_sync_send(const IocFrame *frame)
{
    uint8_t i;
    uint8_t discard;
    uint8_t data_len = frame->bytes[IOC_OFF_LEN];
    uint16_t length;
    uint16_t crc = 0u;

    if (data_len > IOC_COMMAND_MAX_DATA)
        data_len = IOC_COMMAND_MAX_DATA;
    length = (uint16_t)(IOC_PACKET_FIXED_LEN + data_len);

    /* Exact wire-order CRC coverage. */
    crc = sio_link_crc16_update(crc, (uint8_t)length);
    crc = sio_link_crc16_update(crc, (uint8_t)(length >> 8));
    crc = sio_link_crc16_update(crc, frame->bytes[IOC_OFF_CLASS]);
    crc = sio_link_crc16_update(crc, frame->bytes[IOC_OFF_SEQ]);
    crc = sio_link_crc16_update(crc, frame->bytes[IOC_OFF_STATUS]);
    for (i = 0u; i < data_len; i++)
        crc = sio_link_crc16_update(crc,
                                    frame->bytes[IOC_OFF_PAYLOAD + i]);

    __delay_us(EXTSYNC_REPLY_GUARD_US);
    /* Match the gated clock's pulled-up level before enabling its buffer. */
    LINK_CLK_LAT  = 1;
    LINK_DOUT_LAT = 1;
    edge_counter_start();
    bus_select_siob();

    if (!link_synced) {
        /* Two setup clocks with /SYNCB still idle high.  These are NOT a
         * multiple of eight and would shift a synchronised receiver's character
         * boundary, so they exist only on the path that is establishing the
         * boundary in the first place. */
        LINK_CLK_LAT = 0;
        __delay_us(EXTSYNC_BIT_DELAY_US);
        LINK_CLK_LAT = 1;

        __delay_us(EXTSYNC_BIT_DELAY_US);

        LINK_DOUT_LAT = 0;
        LINK_CLK_LAT = 0;
        __delay_us(EXTSYNC_BIT_DELAY_US);
        LINK_CLK_LAT = 1;
    }

    /* The hand-clocked byte establishes the SIO character boundary only.  It
     * is deliberately not packet marker A5: the physical channels require
     * different /SYNC drop positions, so its CPU-visible value is not a safe
     * protocol byte.  The complete packet marker follows through SPI. */
    if (!link_synced) {
        sio_link_clock_sync_byte(EXTSYNC_ESTABLISH_BYTE,
                                 SIO_LINK_CH_COMMAND,
                                 EXTSYNC_SYNC_DROP_BIT);
        link_synced = true;
    }

    /* Park the clock HIGH before the SPI module takes the pins.  CKP = 1 means
     * both owners agree on the level, so the PPS handover is edge-free.  DOUT
     * similarly returns to marking idle between characters. */
    LINK_CLK_LAT  = 1;
    LINK_DOUT_LAT = 1;

    sio_link_set_baud(EXTSYNC_SPI_BAUD);
    sio_link_clear_fifos();
    sio_link_pins_to_spi();

    /* Always send the complete marker as ordinary aligned packet bytes. */
    (void)sio_link_exchange(IOC_PACKET_SYNC0, &discard);
    sio_link_byte_gap();
    (void)sio_link_exchange(IOC_PACKET_SYNC1, &discard);
    sio_link_byte_gap();
    (void)sio_link_exchange((uint8_t)length, &discard);
    sio_link_byte_gap();
    (void)sio_link_exchange((uint8_t)(length >> 8), &discard);
    sio_link_byte_gap();
    (void)sio_link_exchange(frame->bytes[IOC_OFF_CLASS], &discard);
    sio_link_byte_gap();
    (void)sio_link_exchange(frame->bytes[IOC_OFF_SEQ], &discard);
    sio_link_byte_gap();
    (void)sio_link_exchange(frame->bytes[IOC_OFF_STATUS], &discard);
    sio_link_byte_gap();
    for (i = 0u; i < data_len; i++) {
        (void)sio_link_exchange(frame->bytes[IOC_OFF_PAYLOAD + i], &discard);
        sio_link_byte_gap();
    }
    (void)sio_link_exchange((uint8_t)(crc >> 8), &discard);
    sio_link_byte_gap();
    (void)sio_link_exchange((uint8_t)crc, &discard);
    sio_link_byte_gap();

    /* The SIO reports the final CRC byte ready only after further clocks.  This
     * FF remains in its receive pipeline and is deliberately ignored by the
     * next packet's A5/5A marker search. */
    (void)sio_link_exchange(0xFFu, &discard);
    sio_link_pins_to_lat();
    last_tx_edges = edge_counter_stop();

    /* /SYNCB is NOT released here.  It was, and that single line defeated the
     * whole persistent-sync change: the establishing reply delivered the falling
     * edge and then this put the line straight back high, leaving every
     * subsequent reply with no edge and a line the manual says must stay low.
     * It is dropped once, by the hand-clocked byte above, and held. */
    LINK_DOUT_LAT = 1;
    bus_release_siob();
}
