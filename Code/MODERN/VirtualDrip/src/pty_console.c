#define _GNU_SOURCE

#include "pty_console.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

#define PTY_CONSOLE_RX_CHUNK 16u
#define PTY_WRITE_TIMEOUT_MS 100

struct PtyConsole {
    int master_fd;
    char *slave_path;
    SerialPort *serial_port;
    pthread_t thread;
    bool started;
    bool log_packets;
    PtyConsoleShouldStop should_stop;
    void *should_stop_userdata;
    pthread_mutex_t state_mutex;
    bool storage_active;
};

static bool pty_console_should_stop(PtyConsole *console)
{
    return console->should_stop != NULL && console->should_stop(console->should_stop_userdata);
}

static bool pty_console_configure_raw(int fd)
{
    struct termios options;
    if (tcgetattr(fd, &options) != 0) {
        perror("pty tcgetattr");
        return false;
    }

    cfmakeraw(&options);
    options.c_iflag &= ~(IXON | IXOFF | IXANY);
    options.c_oflag &= ~OPOST;
    options.c_lflag &= ~(ECHO | ICANON | ISIG | IEXTEN);
    options.c_cc[VMIN] = 0;
    options.c_cc[VTIME] = 1;

    if (tcsetattr(fd, TCSANOW, &options) != 0) {
        perror("pty tcsetattr");
        return false;
    }

    return true;
}

static int pty_console_open_master(char *slave_path, size_t slave_path_size)
{
    int master_fd = posix_openpt(O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (master_fd < 0) {
        perror("posix_openpt");
        return -1;
    }

    if (grantpt(master_fd) != 0) {
        perror("grantpt");
        close(master_fd);
        return -1;
    }

    if (unlockpt(master_fd) != 0) {
        perror("unlockpt");
        close(master_fd);
        return -1;
    }

    int pts_rc = ptsname_r(master_fd, slave_path, slave_path_size);
    if (pts_rc != 0) {
        errno = pts_rc;
        perror("ptsname_r");
        close(master_fd);
        return -1;
    }

    int slave_fd = open(slave_path, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (slave_fd < 0) {
        perror(slave_path);
        close(master_fd);
        return -1;
    }

    bool configured = pty_console_configure_raw(slave_fd);
    close(slave_fd);
    if (!configured) {
        close(master_fd);
        return -1;
    }

    return master_fd;
}

static bool pty_console_storage_active(PtyConsole *console)
{
    pthread_mutex_lock(&console->state_mutex);
    bool active = console->storage_active;
    pthread_mutex_unlock(&console->state_mutex);
    return active;
}

static bool pty_console_wait_send_allowed(PtyConsole *console)
{
    while (pty_console_storage_active(console)) {
        if (pty_console_should_stop(console)) {
            return false;
        }
        usleep(10000);
    }
    return true;
}

static bool pty_console_wait_writable(int fd)
{
    struct pollfd pfd;
    pfd.fd = fd;
    pfd.events = POLLOUT;
    pfd.revents = 0;

    for (;;) {
        int rc = poll(&pfd, 1, PTY_WRITE_TIMEOUT_MS);
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
            return false;
        }
        if (errno == EINTR) {
            continue;
        }
        perror("pty poll");
        return false;
    }
}

static bool pty_console_write_all(int fd, const uint8_t *bytes, size_t length)
{
    while (length > 0) {
        ssize_t written = write(fd, bytes, length);
        if (written > 0) {
            bytes += written;
            length -= (size_t)written;
            continue;
        }
        if (written == 0 || errno == EAGAIN || errno == EWOULDBLOCK) {
            if (!pty_console_wait_writable(fd)) {
                return false;
            }
            continue;
        }
        if (errno == EINTR) {
            continue;
        }
        if (errno != EIO) {
            perror("pty write");
        }
        return false;
    }

    return true;
}

static void *pty_console_reader_thread(void *context)
{
    PtyConsole *console = (PtyConsole *)context;

    while (!pty_console_should_stop(console)) {
        uint8_t buffer[PTY_CONSOLE_RX_CHUNK];
        ssize_t bytes_read = read(console->master_fd, buffer, sizeof(buffer));
        if (bytes_read > 0) {
            if (!pty_console_wait_send_allowed(console)) {
                break;
            }
            bool sent = serial_port_send_packet(
                console->serial_port,
                PACKET_TERMINAL_RX,
                buffer,
                (uint8_t)bytes_read);
            if (console->log_packets) {
                fprintf(stderr, "TERMINAL_RX len=%zd sent=%s\n", bytes_read, sent ? "ok" : "failed");
            }
            continue;
        }

        if (bytes_read < 0
            && errno != EAGAIN
            && errno != EWOULDBLOCK
            && errno != EINTR
            && errno != EIO) {
            perror("pty read");
            break;
        }

        usleep(10000);
    }

    return NULL;
}

PtyConsole *pty_console_create(
    SerialPort *serial_port,
    bool log_packets,
    PtyConsoleShouldStop should_stop,
    void *should_stop_userdata)
{
    if (serial_port == NULL) {
        fprintf(stderr, "PTY console requires an open serial port\n");
        return NULL;
    }

    char slave_path[128];
    int master_fd = pty_console_open_master(slave_path, sizeof(slave_path));
    if (master_fd < 0) {
        return NULL;
    }

    PtyConsole *console = calloc(1, sizeof(*console));
    if (console == NULL) {
        fprintf(stderr, "Failed to allocate PTY console\n");
        close(master_fd);
        return NULL;
    }

    console->slave_path = strdup(slave_path);
    if (console->slave_path == NULL) {
        fprintf(stderr, "Failed to allocate PTY slave path\n");
        close(master_fd);
        free(console);
        return NULL;
    }

    console->master_fd = master_fd;
    console->serial_port = serial_port;
    console->log_packets = log_packets;
    console->should_stop = should_stop;
    console->should_stop_userdata = should_stop_userdata;
    pthread_mutex_init(&console->state_mutex, NULL);
    return console;
}

bool pty_console_start(PtyConsole *console)
{
    if (console == NULL) {
        return false;
    }
    if (pthread_create(&console->thread, NULL, pty_console_reader_thread, console) != 0) {
        perror("pthread_create");
        return false;
    }
    console->started = true;
    return true;
}

void pty_console_destroy(PtyConsole *console)
{
    if (console == NULL) {
        return;
    }
    if (console->started) {
        pthread_join(console->thread, NULL);
        console->started = false;
    }
    if (console->master_fd >= 0) {
        close(console->master_fd);
        console->master_fd = -1;
    }
    pthread_mutex_destroy(&console->state_mutex);
    free(console->slave_path);
    free(console);
}

const char *pty_console_slave_path(const PtyConsole *console)
{
    return console == NULL ? "" : console->slave_path;
}

bool pty_console_handle_packet(PtyConsole *console, const Packet *packet)
{
    if (packet == NULL || packet->type != PACKET_TERMINAL_TX) {
        return false;
    }
    if (console == NULL) {
        fprintf(stderr, "TERMINAL_TX ignored: PTY console is not enabled\n");
        return true;
    }
    if (packet->length == 0) {
        return true;
    }

    bool written = pty_console_write_all(console->master_fd, packet->payload, packet->length);
    if (console->log_packets) {
        fprintf(stderr, "TERMINAL_TX len=%u written=%s\n", packet->length, written ? "ok" : "failed");
    }
    return true;
}

void pty_console_set_storage_active(PtyConsole *console, bool active)
{
    if (console == NULL) {
        return;
    }
    pthread_mutex_lock(&console->state_mutex);
    console->storage_active = active;
    pthread_mutex_unlock(&console->state_mutex);
}
