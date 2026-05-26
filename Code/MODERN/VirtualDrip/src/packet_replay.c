#include "packet_replay.h"

#include "packet_parser.h"

#include <stdio.h>

/*
 * File replay exists for tests and bring-up, but it intentionally follows the
 * same parser path as serial input. That means packet files are real protocol
 * streams, not a separate fixture format.
 */

int packet_replay_file(const char *path, PacketHandler handler, void *userdata)
{
    FILE *file = fopen(path, "rb");
    if (file == NULL) {
        perror(path);
        return -1;
    }

    PacketParser parser;
    packet_parser_init(&parser, handler, userdata);

    for (;;) {
        int value = fgetc(file);
        if (value == EOF) {
            break;
        }
        packet_parser_feed(&parser, (uint8_t)value);
    }

    if (ferror(file)) {
        perror(path);
        fclose(file);
        return -1;
    }

    fclose(file);

    if (packet_parser_has_partial_packet(&parser)) {
        fprintf(stderr, "Truncated packet at end of %s\n", path);
        return -1;
    }

    return packet_parser_crc_errors(&parser) == 0 ? 0 : 1;
}
