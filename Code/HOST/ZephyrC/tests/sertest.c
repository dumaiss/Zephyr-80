/* SERTEST.COM -- the console serial port through ZephyrC.
 *
 * Opens SIO0/B, sends "READY", reads one line from the PC, sends it back
 * reversed, checks that a read times out on a quiet line, then closes.
 * Run it with a peer on the other end of the port (see tests/serpeer.py).
 */
#include <stdio.h>
#include <string.h>
#include <zephyr/serial.h>

static uint8_t line[64];

int main(void)
{
    uint8_t len = 0, i, r;
    int c;

    printf("SERTEST - ZephyrC console port\n");
    r = zep_serial_open(ZEP_SERIAL_CONSOLE, 115200UL, ZEP_SERIAL_RTSCTS);
    if (r != ZEP_OK) {
        printf("open failed: %u\n", r);
        return 1;
    }
    if (zep_serial_open(ZEP_SERIAL_CONSOLE, 0, 0) != ZEP_EBUSY)
        printf("second open not refused  FAIL\n");

    zep_serial_write(ZEP_SERIAL_CONSOLE, (const uint8_t *)"READY\r\n", 7);

    while (len < sizeof(line)) {
        c = zep_serial_getc_ms(ZEP_SERIAL_CONSOLE, 10000);
        if (c < 0 || c == '\n')
            break;
        if (c != '\r')
            line[len++] = (uint8_t)c;
    }
    for (i = 0; i < len / 2; i++) {
        uint8_t t = line[i];
        line[i] = line[len - 1 - i];
        line[len - 1 - i] = t;
    }
    zep_serial_write(ZEP_SERIAL_CONSOLE, line, len);
    zep_serial_write(ZEP_SERIAL_CONSOLE, (const uint8_t *)"\r\n", 2);

    c = zep_serial_getc_ms(ZEP_SERIAL_CONSOLE, 300);
    zep_serial_close(ZEP_SERIAL_CONSOLE);

    printf("received %u bytes\n", len);
    printf(c < 0 ? "quiet-line timeout: ok\n" : "quiet-line timeout: FAIL (got %d)\n", c);
    printf("SERTEST done\n");
    return 0;
}
