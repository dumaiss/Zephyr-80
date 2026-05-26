#define _DEFAULT_SOURCE

#include "serial_reader.h"

#include "packet_parser.h"

#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

/*
 * Serial input is just another byte source for PacketParser. This thread owns
 * blocking/polling behavior for the fd; decoded packet policy stays with the
 * callback supplied by main.
 */

struct SerialReader {
    pthread_t thread;
    SerialReaderConfig config;
    bool started;
};

static bool reader_should_stop(const SerialReader *reader)
{
    if (reader->config.should_stop == NULL) {
        return false;
    }

    return reader->config.should_stop(reader->config.should_stop_userdata);
}

static void *serial_reader_thread(void *context)
{
    SerialReader *reader = (SerialReader *)context;
    int fd = serial_port_fd(reader->config.port);

    if (fd < 0) {
        return NULL;
    }

    PacketParser parser;
    packet_parser_init(&parser, reader->config.handler, reader->config.handler_userdata);
    printf("Serial packet input listening on %s at %d baud\n",
        serial_port_path(reader->config.port),
        serial_port_baud_rate(reader->config.port));

    while (!reader_should_stop(reader)) {
        uint8_t buffer[256];
        ssize_t bytes_read = read(fd, buffer, sizeof(buffer));
        if (bytes_read > 0) {
            /* Packet callbacks run on this thread. */
            for (ssize_t index = 0; index < bytes_read; ++index) {
                packet_parser_feed(&parser, buffer[index]);
            }
            continue;
        }
        if (bytes_read < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
            perror("serial read");
            break;
        }
        usleep(10000);
    }

    printf("Serial packet input stopped after %zu packet%s",
        packet_parser_packet_count(&parser),
        packet_parser_packet_count(&parser) == 1 ? "" : "s");
    if (packet_parser_crc_errors(&parser) > 0) {
        printf(" (%zu CRC error%s)",
            packet_parser_crc_errors(&parser),
            packet_parser_crc_errors(&parser) == 1 ? "" : "s");
    }
    printf("\n");

    return NULL;
}

SerialReader *serial_reader_start(const SerialReaderConfig *config)
{
    SerialReader *reader = calloc(1, sizeof(*reader));
    if (reader == NULL) {
        fprintf(stderr, "Failed to allocate serial reader\n");
        return NULL;
    }

    reader->config = *config;
    if (pthread_create(&reader->thread, NULL, serial_reader_thread, reader) != 0) {
        perror("pthread_create");
        free(reader);
        return NULL;
    }

    reader->started = true;
    return reader;
}

void serial_reader_join(SerialReader *reader)
{
    if (reader == NULL) {
        return;
    }

    if (reader->started) {
        pthread_join(reader->thread, NULL);
        reader->started = false;
    }
    free(reader);
}
