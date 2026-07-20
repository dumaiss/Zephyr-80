#ifndef SDLC_H
#define SDLC_H

#include <stdint.h>
#include <stdbool.h>
#include "ioc_frame.h"

/* External Sync byte transport for the IO Controller Command channel.
 *
 * The sdlc_* names are legacy API names retained so main.c, dispatch.c and
 * diagnostics do not churn during bring-up.  This transport is not SDLC: no
 * SDLC flags, no zero-bit stuffing, no FCS/CRC.
 *
 * Hardware notes:
 *   - MCU is the synchronous clock master.  SPI_CLK (RA7) supplies TXC/RXC
 *     to both SIO1/A (Bulk, RA0) and SIO1/B (Command, RA1).
 *   - SPI_CLK is physically shared and not gated per consumer.  When it
 *     toggles, all attached consumers see clock edges.  Only one CS may be
 *     asserted at a time.
 *   - CMD_CS (RA1) is the KiCad net name; it is electrically connected to
 *     Z80 SIO1/B SYNCB.
 *   - Clocking alone does not trigger a useful Z80 SIO interrupt.  Phase 1 uses
 *     foreground-polled transparent bytes in External Sync mode.
 *
 * Wire format per frame:
 *   optional preamble byte (0x7E) for byte alignment during bring-up
 *   32-byte IOC frame payload (transparent bytes, LSB-first on the wire)
 *
 * Only IO_CH_COMMAND is active in Phase 1.  IO_CH_BULK calls return false.
 */

/* BAUD divider for ~250 kHz at 64 MHz HFINTOSC.
 * Clock = Fosc / (2 * (SPI1BAUD + 1)) = 64 MHz / 256 = 250 kHz exactly.
 * Exact rate is not critical; close enough is fine for bring-up.
 */
#define SDLC_BAUD_250KHZ  127u

/* Maximum receive window in SPI bytes.
 * 80 bytes = 640 bit-slots.  A 32-byte payload fits with room for idle bits
 * before an optional software preamble.
 * Increase if hardware tests show frames arriving late in the window.
 */
#define SDLC_RX_WINDOW_BYTES  80u

/* SPI module init.  Call once from main before any transport operations. */
void sdlc_spi_init(void);

/* Configure SPI for Command-channel External Sync at 250 kHz.
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

/* Receive one External Sync byte frame on the given channel.
 *
 * Clocks in SDLC_RX_WINDOW_BYTES SPI bytes, then decodes the bit stream:
 * hunts for the optional preamble and copies the following 32-byte IOC payload
 * to *frame.
 *
 * timeout_bytes: not used in Phase 1 (full window always clocked).
 *                Reserved for future timer-based receive with early exit.
 *
 * Returns true if a 32-byte frame was found.
 * Returns false on wrong length or no frame.
 */
bool sdlc_recv_frame(IocChannel ch, IocFrame *frame, uint16_t timeout_bytes);

/* Transmit one External Sync byte frame on the given channel.
 *
 * Sends the optional preamble byte followed by the 32 transparent payload bytes.
 *
 * Returns true on success, false if ch is not IO_CH_COMMAND.
 */
bool sdlc_send_frame(IocChannel ch, const IocFrame *frame);

#endif /* SDLC_H */
