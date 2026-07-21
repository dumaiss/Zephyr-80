#ifndef EXTERNAL_SYNC_H
#define EXTERNAL_SYNC_H

#include <stdbool.h>
#include "ioc_frame.h"

/* GPIO-driven Z80 SIO External Sync transport.
 *
 * Hardware:
 *
 *   PIC18F57Q84                    Z80 SIO1/B
 *   -----------                    ----------
 *   RA7  clock out  -------------> RXTXCB
 *   RA5  data out   -------------> RXDB
 *   RA6  data in    <------------- TXDB
 *   RA1  sync/gate  -------------> /SYNCB and 74HC125 /OE
 *   RF1  RTS input  <------------- /RTSB
 *
 * The PIC owns only the SIO serial-side signals.  The Z80 BIOS owns the SIO
 * register bus and must configure channel B for External Sync mode.
 *
 * Link contract:
 *   - RTSB low tells the PIC that the Z80 BIOS is inside one IOCALL.
 *   - The PIC supplies all serial clock edges.
 *   - Bytes are shifted least-significant bit first, matching the Z80 SIO
 *     serializer.
 *   - The mailbox body is exactly 32 raw bytes.  The transport does not add
 *     bytes before or after the mailbox body, apart from the required trailing
 *     idle clocks used to flush the SIO receiver.
 *
 * See docs/external_sync_protocol.md for the timing walkthrough and the SIO
 * manual references behind the /SYNCB handling.
 */

#define EXTSYNC_BIT_DELAY_US     50u
#define EXTSYNC_REPLY_GUARD_MS   10u
#define EXTSYNC_ALIGNMENT_BYTE   0x7Eu

/* The host request currently occupies either:
 *   byte 0..31: direct frame, or
 *   byte 1..32: one leading host alignment byte, then the frame.
 *
 * Clock a small fixed window so the firmware stays simple while the host BIOS
 * is still being simplified.
 */
#define EXTSYNC_RX_WINDOW_BYTES  80u

void external_sync_init(void);
bool external_sync_receive(IocFrame *frame);
void external_sync_send(const IocFrame *frame);

#endif /* EXTERNAL_SYNC_H */
