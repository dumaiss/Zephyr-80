#ifndef SERIAL_PORT_H
#define SERIAL_PORT_H

/**
 * @file serial_port.h
 * POSIX serial port ownership and transmit helpers.
 *
 * Virtual Drip opens serial devices read/write: VDP, storage, and optional PTY
 * console packets are framed, while the default built-in console path still
 * sends VNC keyboard input back to Zephyr as raw terminal bytes. The
 * implementation configures raw mode with hardware RTS/CTS flow control and
 * protects writes with a mutex because multiple transmit paths may share the
 * serial fd while the reader thread is active.
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
 * With CRTSCTS enabled, the kernel gates physical transmission on peer CTS.
 * The userspace call returns after bytes are accepted into the serial driver.
 */
bool serial_port_send_packet(SerialPort *port, uint8_t type, const uint8_t *payload, uint8_t length);

/**
 * Build and write one Virtual Drip packet with a delay between bytes.
 *
 * Used for large proxy->Z80 storage replies when the Z80 side must parse each
 * byte synchronously without an intermediate RX ring. Display/control packets
 * keep using serial_port_send_packet().
 */
bool serial_port_send_packet_paced(
    SerialPort *port,
    uint8_t type,
    const uint8_t *payload,
    uint8_t length,
    unsigned inter_byte_delay_us);

/**
 * Wait until pending host-to-Z80 bytes have left the serial driver.
 *
 * This is intentionally not part of normal packet/keyboard sends; it is used
 * after storage replies so console input cannot be released while the Z80
 * storage parser may still own the RX sink.
 */
bool serial_port_wait_output_drained(SerialPort *port, int timeout_ms);

/**
 * Write raw bytes under the TX mutex.
 *
 * Used for the default proxy->Z80 terminal input and readiness path. Bytes are
 * not wrapped in Virtual Drip framing and no CRC is appended. PTY console mode
 * uses serial_port_send_packet() with TERMINAL_RX instead.
 */
bool serial_port_send_raw(SerialPort *port, const uint8_t *bytes, size_t length);

#endif
