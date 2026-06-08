#ifndef SDLC_H
#define SDLC_H

#include <stdint.h>
#include <stdbool.h>
#include "ioc_frame.h"

/* SDLC frame transport for the IO Controller Command channel.
 *
 * Hardware notes:
 *   - MCU is the synchronous clock master.  SPI_CLK (RA7) supplies TXC/RXC
 *     to both SIO1/A (Bulk, RA0) and SIO1/B (Command, RA1).
 *   - SPI_CLK is physically shared and not gated per consumer.  When it
 *     toggles, all attached consumers see clock edges.  Only one CS may be
 *     asserted at a time.
 *   - CMD_CS (RA1) is the KiCad net name; it is electrically connected to
 *     Z80 SIO1/B SYNCB.
 *   - Clocking alone does not trigger a useful Z80 SIO interrupt.  A valid
 *     complete SDLC frame (correct flags, zero-bit stuffing, valid FCS) is
 *     required before the SIO accepts data or asserts its interrupt output.
 *
 * Wire format per frame:
 *   opening flag (0x7E, not stuffed)
 *   32-byte IOC frame payload (bit-stuffed, LSB-first)
 *   2-byte FCS (bit-stuffed, LSB-first, low byte first)
 *   closing flag (0x7E, not stuffed)
 *
 * Only IO_CH_COMMAND is active in Phase 1.  IO_CH_BULK calls return false.
 */

/* BAUD divider for ~250 kHz at 64 MHz HFINTOSC.
 * Clock = Fosc / (2 * (SPI1BAUD + 1)) = 64 MHz / 256 = 250 kHz exactly.
 * Exact rate is not critical; close enough is fine for bring-up.
 */
#define SDLC_BAUD_250KHZ  127u

/* Maximum receive window in SPI bytes.
 * 80 bytes = 640 bit-slots.  A worst-case stuffed 34-byte payload fits in
 * ~43 bytes; 80 bytes leaves room for idle bits before the opening flag.
 * Increase if hardware tests show frames arriving late in the window.
 */
#define SDLC_RX_WINDOW_BYTES  80u

/* SPI module init.  Call once from main before any SDLC operations. */
void sdlc_spi_init(void);

/* Configure SPI for Command-channel SDLC at 250 kHz.
 * Deasserts all CS lines first, then sets rate/mode.
 * Call before sdlc_recv_frame or sdlc_send_frame if rate may have changed.
 */
void sdlc_command_config_250khz(void);

/* Assert / deassert Command CS (SIO_PORTB_CS = RA1 = SIO1/B SYNCB).
 * sdlc_recv_frame and sdlc_send_frame call these internally; exposed here
 * for diagnostics.
 */
void sdlc_command_select(void);
void sdlc_command_deselect(void);

/* Deassert all four CS lines.  Call at startup and between consumers. */
void sdlc_all_deselect(void);

/* Receive one SDLC frame on the given channel.
 *
 * Clocks in SDLC_RX_WINDOW_BYTES SPI bytes, then decodes the bit stream:
 * hunts for opening flag, destuffs data bits, validates FCS, copies 32-byte
 * IOC payload to *frame.
 *
 * timeout_bytes: not used in Phase 1 (full window always clocked).
 *                Reserved for future timer-based receive with early exit.
 *
 * Returns true if a valid 32-byte frame with correct FCS was found.
 * Returns false on malformed frame, wrong length, bad FCS, or no frame.
 */
bool sdlc_recv_frame(IocChannel ch, IocFrame *frame, uint16_t timeout_bytes);

/* Transmit one SDLC frame on the given channel.
 *
 * Precomputes the full stuffed SDLC bitstream (flag + payload + FCS + flag)
 * into a local buffer, then clocks it out via SPI.  No per-bit timing
 * pressure; all bit manipulation happens before the SPI transfer starts.
 *
 * Returns true on success, false if ch is not IO_CH_COMMAND.
 */
bool sdlc_send_frame(IocChannel ch, const IocFrame *frame);

#endif /* SDLC_H */
