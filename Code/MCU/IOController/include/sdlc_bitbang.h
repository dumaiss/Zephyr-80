#ifndef SDLC_BITBANG_H
#define SDLC_BITBANG_H

#include <stdint.h>
#include <stdbool.h>
#include "ioc_frame.h"

/* GPIO bit-bang transport for the IO Controller — bring-up alternative to the
 * SPI/External-Sync transport in sdlc.c.
 *
 * This module exposes the SAME legacy sdlc_* API as sdlc.h so that main.c,
 * dispatch.c and IocFrame stay byte-for-byte unchanged.  The name is historical;
 * this bring-up is transparent External Sync, not SDLC.  Exactly one of the two
 * transports is compiled, selected by IOC_TRANSPORT_BITBANG in config.h:
 *   defined   -> sdlc_bitbang.c (this module)  built, sdlc.c compiled empty
 *   undefined -> sdlc.c built, sdlc_bitbang.c compiled empty
 *
 * Hardware role (HARD RULE): the PIC is on the SIO's SERIAL side only.  It does
 * NOT program any SIO register (WR0-WR7) — the Z80 owns the SIO CPU bus and is
 * assumed to have already put the SIO channel in External Sync mode.  This
 * module only generates the clock, drives/samples the serial data, and asserts
 * the External Sync line.  It contains zero SIO register init.
 *
 * Test channel = SIO channel B.  SIO1/A channel-A outputs failed hardware
 * probing, so bring-up uses the RA1/SYNCB/RF1 set:
 *   RA7  CLK         PIC drives        (bit-bang clock master, idle low)
 *   RA5  data OUT    PIC output  -> SIO RxDB   (idle high / marking)
 *   RA6  data IN     PIC input   <- SIO TxDB
 *   RA1  CMD_CS      PIC drives  = SIO /SYNCB External-Sync input AND the
 *                    74HC125 /OE that gates SIO-TxDB -> MCU data-in. Held low
 *                    for the whole transaction (enables the buffer + holds the
 *                    SIO externally synced); high when idle.
 *   RF1  SIO_CMD_RTS   PIC input  <- Z80, active low (polled in main.c).
 *
 * Wire format (transparent External Sync, identical to sdlc.c so the Z80 side
 * is unchanged):
 *   1 preamble byte (IOC_SYNC_PREAMBLE) for byte alignment
 *   32 transparent IocFrame bytes
 * No flags, no zero-bit stuffing, no FCS.  Bytes are shifted LSB-first to match
 * the Z80 SIO serializer (see the bit-order note in sdlc_bitbang.c).
 *
 * Only IO_CH_COMMAND is serviced (the active-channel sentinel, same contract as
 * sdlc.c); the pins driven are physically channel B.  IO_CH_BULK returns false.
 */

/* Half-bit period for the bit-bang clock.  Start slow so a scope/LA can catch a
 * single transaction and the CLK/data phase is easy to read; lower once timing
 * is validated.  ~50 us each side -> ~100 us/bit -> ~10 kHz. */
#define BB_BIT_DELAY_US  50u

/* Receive window, in bytes clocked in before decoding.  Same value and legacy
 * macro name as sdlc.h so main.c is unchanged. */
#define SDLC_RX_WINDOW_BYTES  80u

/* Transport init.  Call once from main before any frame operations.
 * Bit-bang version: park RA1/RA5/RA6/RA7 at their GPIO directions/idle levels.
 * No SPI peripheral, no PPS. */
void sdlc_spi_init(void);

/* Idle/configure the channel-B bit-bang bus.  No rate register to program with
 * GPIO; this just deasserts the selects and parks the bus pins.  Call before
 * sdlc_recv_frame / sdlc_send_frame. */
void sdlc_command_config_250khz(void);

/* Assert / deassert the channel-B External Sync line (RA1).  Called internally
 * by recv/send; exposed for diagnostics (mirrors sdlc.h). */
void sdlc_command_select(void);
void sdlc_command_deselect(void);

/* Park all selects at idle. */
void sdlc_all_deselect(void);

/* Receive one frame: hold sync low, clock in the receive-window bytes with
 * data-out idle, hunt the preamble at any bit offset, copy the 32-byte payload.
 * timeout_bytes is reserved (full window always clocked), matching sdlc.c.
 * Returns true if a frame was decoded; false on bad channel/length. */
bool sdlc_recv_frame(IocChannel ch, IocFrame *frame, uint16_t timeout_bytes);

/* Transmit one frame: hold sync low, clock out the preamble then the 32
 * transparent bytes, release sync.  Returns false if ch != IO_CH_COMMAND. */
bool sdlc_send_frame(IocChannel ch, const IocFrame *frame);

#endif /* SDLC_BITBANG_H */
