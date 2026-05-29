#define _DEFAULT_SOURCE

#include "serial_port.h"

#include "protocol.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>
#include <poll.h>

/*
 * This module owns all POSIX serial details. The rest of the proxy deals in a
 * SerialPort handle and packet bytes; raw termios setup, write completion, and
 * transmit locking stay here.
 */

struct SerialPort {
    /* Owned nonblocking POSIX fd opened read/write. */
    int fd;
    /* Owned copy of the path, used for diagnostics. */
    char *path;
    /* Configured baud rate accepted by baud_to_speed(). */
    int baud_rate;
    /* Protects encoded packet writes against concurrent keyboard callbacks. */
    pthread_mutex_t tx_mutex;
};

static speed_t baud_to_speed(int baud_rate)
{
    switch (baud_rate) {
    case 9600:
        return B9600;
    case 19200:
        return B19200;
    case 38400:
        return B38400;
    case 57600:
        return B57600;
    case 115200:
        return B115200;
    case 230400:
        return B230400;
    default:
        return 0;
    }
}

static bool configure_serial_port(int fd, int baud_rate)
{
    speed_t speed = baud_to_speed(baud_rate);
    if (speed == 0) {
        fprintf(stderr, "Unsupported baud rate %d\n", baud_rate);
        return false;
    }

    struct termios options;
    if (tcgetattr(fd, &options) != 0) {
        perror("tcgetattr");
        return false;
    }

    cfsetispeed(&options, speed);
    cfsetospeed(&options, speed);

    /* Raw 8N1: no echo, line editing, software flow control, or CR/LF mapping. */
    options.c_cflag |= (CLOCAL | CREAD);
    options.c_cflag &= ~CSIZE;
    options.c_cflag |= CS8;
    options.c_cflag &= ~PARENB;
    options.c_cflag &= ~CSTOPB;

    options.c_cflag |= CRTSCTS;

    options.c_iflag &= ~(IXON | IXOFF | IXANY | IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL);
    options.c_lflag &= ~(ECHO | ECHONL | ICANON | ISIG | IEXTEN);
    options.c_oflag &= ~OPOST;
    options.c_cc[VMIN] = 0;
    options.c_cc[VTIME] = 1;

    if (tcsetattr(fd, TCSANOW, &options) != 0) {
        perror("tcsetattr");
        return false;
    }

    tcflush(fd, TCIOFLUSH);
    return true;
}

static bool wait_serial_writable(int fd, int timeout_ms)
{
    struct pollfd pfd;
    pfd.fd = fd;
    pfd.events = POLLOUT;
    pfd.revents = 0;

    for (;;) {
        int rc = poll(&pfd, 1, timeout_ms);
        if (rc > 0) {
            if (pfd.revents & POLLOUT) {
                return true;
            }
            if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) {
                return false;
            }
            continue;
        }

        if (rc == 0) {
            fprintf(stderr, "serial write timeout waiting for CTS/writable\n");
            return false;
        }

        if (errno == EINTR) {
            continue;
        }

        perror("poll");
        return false;
    }
}

static bool write_all(int fd, const void *buffer, size_t length)
{
    const uint8_t *cursor = (const uint8_t *)buffer;

    while (length > 0) {
        ssize_t written = write(fd, cursor, length);

        if (written > 0) {
            cursor += written;
            length -= (size_t)written;
            continue;
        }

        if (written == 0) {
            if (!wait_serial_writable(fd, 1000)) {
                return false;
            }
            continue;
        }

        if (errno == EINTR) {
            continue;
        }

        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            if (!wait_serial_writable(fd, 1000)) {
                return false;
            }
            continue;
        }

        perror("write");
        return false;
    }

    return true;
}

SerialPort *serial_port_open(const char *path, int baud_rate)
{
    int fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd < 0) {
        perror(path);
        return NULL;
    }

    if (!configure_serial_port(fd, baud_rate)) {
        close(fd);
        return NULL;
    }

    SerialPort *port = calloc(1, sizeof(*port));
    if (port == NULL) {
        fprintf(stderr, "Failed to allocate serial port\n");
        close(fd);
        return NULL;
    }

    port->path = strdup(path);
    if (port->path == NULL) {
        fprintf(stderr, "Failed to allocate serial path\n");
        close(fd);
        free(port);
        return NULL;
    }

    port->fd = fd;
    port->baud_rate = baud_rate;
    pthread_mutex_init(&port->tx_mutex, NULL);
    return port;
}

void serial_port_close(SerialPort *port)
{
    if (port == NULL) {
        return;
    }

    if (port->fd >= 0) {
        close(port->fd);
        port->fd = -1;
    }
    pthread_mutex_destroy(&port->tx_mutex);
    free(port->path);
    free(port);
}

int serial_port_fd(const SerialPort *port)
{
    return port == NULL ? -1 : port->fd;
}

const char *serial_port_path(const SerialPort *port)
{
    return port == NULL ? "" : port->path;
}

int serial_port_baud_rate(const SerialPort *port)
{
    return port == NULL ? 0 : port->baud_rate;
}

bool serial_port_send_packet(SerialPort *port, uint8_t type, const uint8_t *payload, uint8_t length)
{
    if (port == NULL || port->fd < 0) {
        return false;
    }
    if (length > MAX_PACKET_PAYLOAD) {
        fprintf(stderr, "Packet payload too large: %u bytes\n", length);
        return false;
    }

    Packet packet;
    packet.length = length;
    packet.type = type;
    if (length > 0 && payload != NULL) {
        memcpy(packet.payload, payload, length);
    }
    packet.crc = packet_crc8(&packet);
    uint8_t wire_length = packet_wire_length(&packet);

    uint8_t bytes[PACKET_SYNC_SIZE + 255];
    bytes[0] = PACKET_SYNC0;
    bytes[1] = PACKET_SYNC1;
    bytes[2] = wire_length;
    bytes[3] = packet.type;
    if (length > 0 && payload != NULL) {
        memcpy(&bytes[4], packet.payload, length);
    }
    bytes[4 + length] = packet.crc;
    size_t byte_count = (size_t)wire_length + PACKET_SYNC_SIZE;

    /*
     * Keyboard events can be sent from the VNC event path while the serial
     * reader thread is running, so keep each encoded packet contiguous.
     */
    pthread_mutex_lock(&port->tx_mutex);
    bool sent = write_all(port->fd, bytes, byte_count);
    pthread_mutex_unlock(&port->tx_mutex);

    return sent;
}
