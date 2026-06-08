#include "trace.h"

volatile TraceEvent trace_ring[TRACE_DEPTH];
volatile uint8_t    trace_head = 0;

volatile uint8_t dbg_rts_sample = 0xffu;
volatile uint8_t dbg_last_trace = 0u;
volatile uint8_t dbg_last_cmd = 0u;
volatile uint8_t dbg_last_seq = 0u;
volatile uint8_t dbg_last_sdlc_error = DBG_SDLC_ERR_NONE;
volatile uint8_t dbg_last_spi_status = 0u;
volatile uint8_t dbg_last_spi_con0 = 0u;
volatile uint8_t dbg_last_spi_con1 = 0u;
volatile uint8_t dbg_last_spi_con2 = 0u;
volatile uint8_t dbg_last_spi_clk = 0u;
volatile uint8_t dbg_last_spi_baud = 0u;
volatile uint8_t dbg_last_spi_out = 0u;
volatile uint8_t dbg_last_spi_in = 0u;
volatile uint8_t dbg_last_pmd6 = 0u;
volatile uint8_t dbg_last_ra7pps = 0u;
volatile uint8_t dbg_last_spi1sckpps = 0u;
volatile uint8_t dbg_spi_clk_gpio_low_sample = 0xffu;
volatile uint8_t dbg_spi_clk_gpio_high_sample = 0xffu;
volatile uint16_t dbg_sdlc_rx_count = 0u;
volatile uint16_t dbg_spi_xfer_attempt_count = 0u;
volatile uint16_t dbg_spi_txb_write_count = 0u;
volatile uint16_t dbg_spi_xfer_count = 0u;
volatile uint16_t dbg_spi_timeout_count = 0u;
volatile uint16_t dbg_spi_clk_gpio_pulse_count = 0u;
volatile uint16_t dbg_main_loop_count = 0u;
volatile uint16_t dbg_rts_seen_count = 0u;

volatile uint8_t  dbg_rx_snapshot[16] = {0};
volatile uint16_t dbg_rx_nonff_count = 0u;
volatile uint16_t dbg_rx_flag_count = 0u;

void trace_push(uint8_t code, uint8_t a, uint8_t b, uint8_t c)
{
    dbg_last_trace = code;
    trace_ring[trace_head].code = code;
    trace_ring[trace_head].a    = a;
    trace_ring[trace_head].b    = b;
    trace_ring[trace_head].c    = c;
    trace_head = (uint8_t)((trace_head + 1) & (TRACE_DEPTH - 1));
}
