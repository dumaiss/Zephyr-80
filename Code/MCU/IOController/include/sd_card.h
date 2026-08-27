#ifndef SD_CARD_H
#define SD_CARD_H

#include <stdint.h>
#include <stdbool.h>

/* SD card on the port C peripheral bus (SPI1), select /IO_SD_CS on RA2.
 *
 * Card sits on the mezzanine connector.  SPI mode only -- no SD native 4-bit
 * bus, no DMA, no multi-block.  Enough to read blocks for bring-up.
 */

#define SD_BLOCK_SIZE 512u

/* ===========================================================================
 * BELT AND SUSPENDERS
 * ===========================================================================
 *
 * Several settings here are deliberately conservative.  They were added while
 * chasing a card that had stopped responding entirely -- which turned out to be
 * flux residue on the socket contacts, not firmware -- and the path has since
 * behaved intermittently: it began working again after several attempts, which
 * is the signature of a marginal contact rather than a fixed fault.
 *
 * They are all cheap and all currently earning their keep.  None should be
 * relaxed until the hardware is known good.  When it is, tighten them ONE at a
 * time and re-test, so a regression names its own cause.
 *
 *   setting                default    cost            relax to      why it is there
 *   ---------------------- ---------- --------------- ------------- ------------------------
 *   SD_INIT_BAUD           125 kHz    ~3 ms first     400 kHz       bottom of the spec's
 *                                     access                        100-400 kHz window; the
 *                                                                   most forgiving of a long
 *                                                                   mezzanine path
 *   SD_DATA_BAUD           1 MHz      --              2-4 MHz       raise only after the CRC
 *                                                                   check has been clean for
 *                                                                   a while; a card that inits
 *                                                                   and then fails is signal
 *                                                                   integrity, not protocol
 *   SD_INIT_CLOCK_BYTES    12 (96)    ~1 ms           10 (80)       spec minimum is 74
 *   init clocks with CS    CS high    --              (keep)        REQUIRED, not optional:
 *   high                                                            this is what puts the card
 *                                                                   into SPI mode at all.  Do
 *                                                                   not move these clocks
 *                                                                   inside the select
 *   SD_POWER_SETTLE_MS     10 ms      10 ms first     1 ms          spec minimum is 1 ms after
 *                                     access                        Vdd is stable
 *   SD_IDLE_RETRIES        20         --              10            CMD0 retries; only paid on
 *                                                                   failure
 *   SD_CMD0_RETRY_GAP_MS   2 ms       --              0             lets a card still powering
 *                                                                   up catch the next CMD0
 *   SD_READ_ATTEMPTS       3          --              1             retries CRC and missing
 *                                                                   token only; both are what
 *                                                                   a marginal bus produces
 *   CRC-16 verification    on         ~800 us/block   (keep)        the one to keep regardless:
 *                                                                   without it a corrupted
 *                                                                   sector reads as SD_OK
 *
 * CORRECTED, and worth knowing for every port C device: SPI_CLK is NOT gated by
 * the device selects.  There is no hardware between the PIC and the port C
 * devices that blocks the clock; it runs wherever the firmware clocks it.
 *
 * This entry previously claimed the opposite, "confirmed on a scope".  What the
 * scope actually showed was clock and select coinciding -- which they did
 * because the firmware only ever clocked while a select was asserted.  That
 * correlation was recorded as a hardware fact, and the spec-required CS-high
 * power-up burst was deleted as useless on the strength of it.  It is not
 * useless; it is the step that puts the card into SPI mode, and losing it is
 * the likeliest cause of the intermittent all-FFh CMD0 traces that followed.
 *
 * Order to relax, cheapest risk first:
 *   1. SD_POWER_SETTLE_MS -> 1 ms, SD_IDLE_RETRIES -> 10
 *   2. SD_INIT_BAUD -> 400 kHz
 *   3. SD_DATA_BAUD upward, watching for SD_ERR_CRC
 *   4. SD_READ_ATTEMPTS -> 1  (last: this is the one masking marginal reads)
 *
 * Keep the CRC check.  It is what makes steps 2-5 safe to attempt at all: a
 * bus problem shows up as SD_ERR_CRC instead of silently wrong data.
 * =========================================================================== */

/* ---------------------------------------------------------------------------
 * Card presence
 *
 * SD_PRESENT on RC0 is the ONLY thing that can report a card as absent.
 *
 * Do not try to infer absence from the bus.  A seated card that has not entered
 * SPI mode is exactly as silent as an empty socket, so silence is reported as
 * SD_ERR_NO_RESPONSE and sd_card_trace() is what separates the cases.
 *
 * Set SD_HAS_PRESENT_PIN to 1 once RC0 is connected; the check then runs first
 * and answers instantly instead of after ten CMD0 retries.
 * --------------------------------------------------------------------------- */
#ifndef SD_HAS_PRESENT_PIN
#define SD_HAS_PRESENT_PIN 1
#endif

/* Level on RC0 when a card is seated: LOW means present.  Confirmed against the
 * board, not assumed -- the socket closes its detect switch to ground on
 * insertion, which is the usual wiring. */
#define SD_PRESENT_ACTIVE  0

/* ---------------------------------------------------------------------------
 * SD_BUSY activity LED
 *
 * Set to 0 to stop driving RC1 entirely (the pin stays a parked-low output).
 * That is the bisect for "the card stopped initialising when the LED went in":
 * if a card is detected again with this at 0, the LED is disturbing the card
 * electrically rather than anything in the firmware being wrong.
 *
 * The suspect mechanism is supply sag.  The LED is switched on at the very
 * start of a card access -- which is precisely the power-up and ACMD41 phase,
 * where an SD card draws its heaviest current and is least tolerant of a
 * drooping rail.  If that is it, the options are to move the assert to after
 * initialisation (losing the long visible flash), raise the LED series
 * resistor, or drive it from something other than the card's rail.
 * --------------------------------------------------------------------------- */
#ifndef SD_BUSY_LED
#define SD_BUSY_LED 0
#endif

/* ---------------------------------------------------------------------------
 * CMD0 loop diagnostic
 *
 * Set to 1 to build a firmware that does nothing but issue the power-up clocks
 * and one CMD0, over and over at about 20 Hz, forever.  No retries, no ACMD41,
 * no Z80, no bulk lane.
 *
 * The point is a scope trace you can actually read on two channels with no
 * decoder: trigger on the /IO_SD_CS falling edge and the same 7-byte sequence
 * repeats every 50 ms, stable enough to step through bit by bit.  At 125 kHz a
 * bit is 8 us, so a byte is a comfortable 64 us wide.
 *
 * What to put on the two channels:
 *
 *   CH1 = SPI_CLK (RC3), CH2 = MOSI (RC5)   verify 40 00 00 00 00 95
 *   CH1 = SPI_CLK (RC3), CH2 = MISO (RC4)   watch for ANY card response
 *
 * Expected on MOSI after the CS falling edge, MSB first:
 *
 *   FF  11111111   idle byte
 *   40  01000000   start bit 0, transmission bit 1, command 000000
 *   00  00000000   argument
 *   00  00000000
 *   00  00000000
 *   00  00000000
 *   95  10010101   CRC7 + stop bit
 *
 * A live card drives DO low within a few byte times of the CRC.
 * --------------------------------------------------------------------------- */
#ifndef SD_CMD0_LOOP
#define SD_CMD0_LOOP 0
#endif

void sd_card_cmd0_loop(void);

typedef enum {
    SD_OK = 0,
    SD_ERR_NO_CARD,       /* presence pin says the socket is empty.  Only ever
                           * set from the pin -- silence on the bus is NOT
                           * evidence of absence, because a seated card that
                           * has not entered SPI mode is equally silent. */
    SD_ERR_NO_RESPONSE,   /* nothing answered CMD0.  Card may be present and
                           * misbehaving, or absent with no pin to say so.
                           * sd_card_trace() distinguishes the cases. */
    SD_ERR_UNUSABLE,      /* answered, but not a card this driver supports */
    SD_ERR_NOT_READY,     /* ACMD41 never reported ready */
    SD_ERR_READ,          /* CMD17 itself was rejected: R1 came back non-zero */
    SD_ERR_NO_TOKEN,      /* CMD17 accepted, but no FEh data token followed */
    SD_ERR_CRC,           /* block arrived but its CRC-16 did not match, and
                           * every retry also failed */
    SD_ERR_BUS,           /* the SPI module itself stalled */
    SD_ERR_WRITE,         /* CMD24 itself was rejected: R1 came back non-zero */
    SD_ERR_WRITE_REJECTED,/* the card refused the data packet.  trace[0] holds
                           * the raw data-response byte; bits 3:1 are the
                           * reason, 010 = CRC error, 110 = write error */
    SD_ERR_WRITE_BUSY     /* the card took the block but never stopped
                           * programming.  The block is in an unknown state --
                           * this is the one error where retrying blindly is
                           * NOT safe */
} SdStatus;

/* Run the SPI-mode initialisation sequence.
 *
 * Blocking, and can take up to about a second on a slow card because ACMD41 is
 * polled until the card leaves idle.  Safe to call repeatedly; a successful
 * result is cached and later calls return immediately. */
SdStatus sd_card_init(void);

/* True only while the driver has a successfully initialised SPI-mode session.
 * This is a state query: it never selects the card or starts initialisation.
 * Any failed read/write invalidates the state, while the next explicit card
 * operation is allowed to initialise it again. */
bool sd_card_is_initialized(void);

/* Read one 512-byte block into buf.
 *
 * Initialises the card first if that has not happened yet, so callers do not
 * have to sequence it.  lba is a block number; the driver converts to a byte
 * address internally for standard-capacity cards. */
SdStatus sd_card_read_block(uint32_t lba, uint8_t *buf);

/* Write one 512-byte block.  No retry wrapper, deliberately: a write that
 * failed partway has already changed the card, so whether to retry is the
 * caller's decision.  Drives SD_BUSY for the duration, like the read path. */
SdStatus sd_card_write_block(uint32_t lba, const uint8_t *buf);

/* Raw bytes the PIC clocked in while polling for CMD0's R1 response on the
 * FIRST attempt.  Diagnostic only.
 *
 * This distinguishes failures that look identical from the status byte:
 *
 *   all FFh      nothing is driving DO -- card not in SPI mode, not selected,
 *                not powered, or the PIC's SDI path is not connected
 *   all 00h      DO stuck low
 *   mixed junk   the card IS talking; the problem is bit alignment or clocking
 *   01h present  CMD0 actually worked and the failure is later
 *
 * After a READ failure the trace is re-armed and instead holds the CMD17
 * response: the R1 poll bytes, with the observed data token (or FFh if none
 * ever arrived) in the last slot. */
/* Silent-retry accounting.  A retried read returns SD_OK with correct data, so
 * these are the only evidence it happened; sd_card_reinits() is the expensive
 * one, since every retry forces a full CMD0/ACMD41 sequence at 125 kHz.  Both
 * saturate at 65535 rather than wrapping. */
uint16_t sd_card_read_retries(void);
uint16_t sd_card_reinits(void);

#define SD_TRACE_BYTES 8u 
const uint8_t *sd_card_trace(void);

#endif /* SD_CARD_H */
