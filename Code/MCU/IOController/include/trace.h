#ifndef TRACE_H
#define TRACE_H

#include <stdint.h>

/* RAM trace ring — readable via ICD/SNAP debugger, no UART required.
 *
 * Inspect trace_ring[] and trace_head in the debugger to see the event log.
 * trace_head points to the *next* slot to be written (oldest event is
 * trace_ring[trace_head] if the ring has wrapped, trace_ring[0] if not).
 */
#define TRACE_DEPTH  32

/* Event codes.
 * The TRACE_SDLC_* names are retained for debugger compatibility with the
 * existing trace workflow; in this bring-up they refer to External Sync
 * transparent byte transport events, not SDLC framing. */
#define TRACE_BOOT_MAIN_LOOP        0x01
#define TRACE_RTS_POLL_LOW          0x02
#define TRACE_COMMAND_SERVICE_ENTER 0x03
#define TRACE_COMMAND_SELECT_LOW    0x04
#define TRACE_SPI_CONFIG_COMMAND    0x05
#define TRACE_SDLC_RX_START         0x06
#define TRACE_SDLC_RX_GOT_FLAG      0x07
#define TRACE_SDLC_RX_GOT_FRAME     0x08
#define TRACE_SDLC_RX_BAD_FCS       0x09
#define TRACE_SDLC_RX_TIMEOUT       0x0A
#define TRACE_DISPATCH_CMD          0x0B
#define TRACE_PING_REPLY_START      0x0C
#define TRACE_PING_REPLY_SENT       0x0D
#define TRACE_RESET_CMD_RECEIVED    0x0E
#define TRACE_UNKNOWN_CMD           0x0F
#define TRACE_SDLC_TX_ERROR         0x10
#define TRACE_SDLC_RX_BAD_FRAME     0x11
#define TRACE_SPI_XFER_TIMEOUT      0x12
#define TRACE_SPI_CLK_GPIO_PULSE    0x13

/* Debug-visible transport error codes.
 * Legacy SDLC names are retained for debugger/source compatibility. */
#define DBG_SDLC_ERR_NONE           0x00
#define DBG_SDLC_ERR_BAD_CHANNEL    0x01
#define DBG_SDLC_ERR_NO_OPEN_FLAG   0x02
#define DBG_SDLC_ERR_NO_CLOSE_FLAG  0x03
#define DBG_SDLC_ERR_DESTUFF_ABORT  0x04
#define DBG_SDLC_ERR_BAD_LENGTH     0x05
#define DBG_SDLC_ERR_BAD_FCS        0x06
#define DBG_SDLC_ERR_SPI_TX_TIMEOUT 0x07
#define DBG_SDLC_ERR_SPI_RX_TIMEOUT 0x08

typedef struct {
    uint8_t code;
    uint8_t a;
    uint8_t b;
    uint8_t c;
} TraceEvent;

extern volatile TraceEvent trace_ring[TRACE_DEPTH];
extern volatile uint8_t    trace_head;

extern volatile uint8_t dbg_rts_sample;
extern volatile uint8_t dbg_last_trace;
extern volatile uint8_t dbg_last_cmd;
extern volatile uint8_t dbg_last_seq;
extern volatile uint8_t dbg_last_sdlc_error;
extern volatile uint8_t dbg_last_spi_status;
extern volatile uint8_t dbg_last_spi_con0;
extern volatile uint8_t dbg_last_spi_con1;
extern volatile uint8_t dbg_last_spi_con2;
extern volatile uint8_t dbg_last_spi_clk;
extern volatile uint8_t dbg_last_spi_baud;
extern volatile uint8_t dbg_last_spi_out;
extern volatile uint8_t dbg_last_spi_in;
extern volatile uint8_t dbg_last_pmd6;
extern volatile uint8_t dbg_last_ra7pps;
extern volatile uint8_t dbg_last_spi1sckpps;
extern volatile uint8_t dbg_spi_clk_gpio_low_sample;
extern volatile uint8_t dbg_spi_clk_gpio_high_sample;
extern volatile uint16_t dbg_sdlc_rx_count;
extern volatile uint16_t dbg_spi_xfer_attempt_count;
extern volatile uint16_t dbg_spi_txb_write_count;
extern volatile uint16_t dbg_spi_xfer_count;
extern volatile uint16_t dbg_spi_timeout_count;
extern volatile uint16_t dbg_spi_clk_gpio_pulse_count;
extern volatile uint16_t dbg_main_loop_count;
extern volatile uint16_t dbg_rts_seen_count;

/* Raw MISO receive-window diagnostics (populated by sdlc_recv_frame).
 *   dbg_rx_snapshot  — first 16 raw bytes clocked in on MISO this window.
 *   dbg_rx_nonff_count — how many receive-window bytes were != 0xFF
 *                        (0 ⇒ MISO was constant idle/marking, i.e. the SIO
 *                        never drove real data, or MISO is not wired/sampled).
 *   dbg_rx_flag_count  — legacy name; counts byte-aligned 0x7E software
 *                        preamble/fill bytes in the raw receive window. */
extern volatile uint8_t  dbg_rx_snapshot[16];
extern volatile uint16_t dbg_rx_nonff_count;
extern volatile uint16_t dbg_rx_flag_count;

/* Record one event.  ISR-safe (no locking — single writer assumed). */
void trace_push(uint8_t code, uint8_t a, uint8_t b, uint8_t c);

/* Convenience macro */
#define TRACE(code, a, b, c)  trace_push((code), (uint8_t)(a), (uint8_t)(b), (uint8_t)(c))

#endif /* TRACE_H */
