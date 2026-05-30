#ifndef SERIAL_PORT_H
#define SERIAL_PORT_H

/**
 * @file serial_port.h
 * POSIX serial port ownership and transmit helpers.
 *
 * Virtual Drip opens serial devices read/write: VDP operation packets arrive
 * from Zephyr as framed packets, while keyboard input is sent back to Zephyr as
 * raw terminal bytes. The implementation configures raw mode and protects writes
 * with a mutex because keyboard callbacks may transmit while the serial reader
 * thread is active.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/** Opaque owner of an open serial fd, path copy, baud rate, and TX mutex. */
typedef struct SerialPort SerialPort;

/**
 * Open and configure a serial device.
 *
 * The returned object owns the fd and must be released with serial_port_close().
 * Only baud rates supported by the implementation's termios mapping are valid.
 */
SerialPort *serial_port_open(const char *path, int baud_rate);

/** Close the fd, destroy the TX mutex, and free the SerialPort object. */
void serial_port_close(SerialPort *port);

/** Return the raw fd for read-side integration, or -1 for NULL. */
int serial_port_fd(const SerialPort *port);

/** Return the borrowed configured path string, or an empty string for NULL. */
const char *serial_port_path(const SerialPort *port);

/** Return the configured baud rate, or 0 for NULL. */
int serial_port_baud_rate(const SerialPort *port);

/**
 * Build and write one Virtual Drip packet under the TX mutex.
 *
 * The packet bytes are SYNC0, SYNC1, LEN, TYPE, PAYLOAD, CRC8. LEN counts the
 * complete packet body after the sync bytes, including LEN itself and CRC8.
 * The call drains the serial transmitter before returning so keyboard packets
 * are observable during pseudo-terminal tests.
 */
bool serial_port_send_packet(SerialPort *port, uint8_t type, const uint8_t *payload, uint8_t length);

/**
 * Write raw bytes under the TX mutex.
 *
 * Used for proxy->Z80 terminal input and readiness. Bytes are not wrapped in
 * Virtual Drip framing and no CRC is appended.
 */
bool serial_port_send_raw(SerialPort *port, const uint8_t *bytes, size_t length);

#endif
