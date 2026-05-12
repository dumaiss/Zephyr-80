#ifndef SERIAL_READER_H
#define SERIAL_READER_H

/**
 * @file serial_reader.h
 * Serial receive thread that feeds the shared packet parser.
 *
 * The reader consumes raw bytes from SerialPort, emits complete packets through
 * the same PacketHandler contract used by file replay, and does not interpret
 * packet contents itself. The callback runs on the reader thread, so higher
 * layers must protect shared video/framebuffer state as needed.
 */

#include "protocol.h"
#include "serial_port.h"

#include <stdbool.h>

/** Return true when the serial reader should exit. */
typedef bool (*SerialReaderShouldStop)(void *userdata);

/** Borrowed configuration copied into the reader object at start. */
typedef struct {
    SerialPort *port;
    PacketHandler handler;
    void *handler_userdata;
    SerialReaderShouldStop should_stop;
    void *should_stop_userdata;
} SerialReaderConfig;

/** Opaque joinable serial reader thread handle. */
typedef struct SerialReader SerialReader;

/** Start a reader thread. Returns NULL on allocation or pthread failure. */
SerialReader *serial_reader_start(const SerialReaderConfig *config);

/** Join a started reader thread and free the reader object. */
void serial_reader_join(SerialReader *reader);

#endif
