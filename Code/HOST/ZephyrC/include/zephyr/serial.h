/* serial.h -- SIO0/A (RS-232 user port) and SIO0/B (USB console port).
 *
 * Both ports are polled: nothing buffers received bytes in the background, so
 * read often, and hold the far end off with zep_serial_rts() around anything
 * slow.  See DOC/API.md section 4.
 */
#ifndef ZEPHYR_SERIAL_H
#define ZEPHYR_SERIAL_H

#include <zephyr/zephyr.h>

typedef enum {
    ZEP_SERIAL_USER = 0,       /* SIO0/A: RS-232, baud from CTC0 */
    ZEP_SERIAL_CONSOLE = 1     /* SIO0/B: USB, lent by the BIOS console */
} zep_port_t;

#define ZEP_SERIAL_RTSCTS   0x01   /* hardware flow control */

/* Console port: baud must be 0 or 115200.  User port: 115200 / n, n = 1-256.
 * The user port claims CTC0 while open. */
uint8_t  zep_serial_open(zep_port_t p, uint32_t baud, uint8_t flags);
void     zep_serial_close(zep_port_t p);

int      zep_serial_getc(zep_port_t p);                      /* -1: nothing waiting */
int      zep_serial_getc_ms(zep_port_t p, uint16_t ms);      /* -1: timeout */
uint8_t  zep_serial_putc(zep_port_t p, uint8_t c);           /* ZEP_OK or ZEP_ETIMEOUT */

/* Read up to n bytes, waiting at most ms for each one.  Returns bytes read. */
uint16_t zep_serial_read(zep_port_t p, uint8_t *buf, uint16_t n, uint16_t ms);
/* Write n bytes; stops at the first transmit timeout.  Returns bytes written. */
uint16_t zep_serial_write(zep_port_t p, const uint8_t *buf, uint16_t n);

#define ZEP_SERIAL_RX_READY  0x01
#define ZEP_SERIAL_TX_EMPTY  0x04
#define ZEP_SERIAL_CTS       0x20
#define ZEP_SERIAL_OVERRUN   0x40
#define ZEP_SERIAL_FRAMING   0x80
/* Reading clears latched receive errors. */
uint8_t  zep_serial_status(zep_port_t p);
void     zep_serial_rts(zep_port_t p, uint8_t asserted);

#endif
