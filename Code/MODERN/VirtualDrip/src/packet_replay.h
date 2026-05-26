#ifndef PACKET_REPLAY_H
#define PACKET_REPLAY_H

/**
 * @file packet_replay.h
 * Deterministic file replay for Virtual Drip packet streams.
 *
 * Replay files contain the same bytes that may be sent over serial. This module
 * feeds those bytes through the shared streaming parser, so file replay and
 * serial input stay aligned on framing, CRC validation, and malformed packet
 * behavior. Timing is not simulated here; FRAME_MARK pacing is layered by tools
 * such as tools/serial_replay.py.
 */

#include "protocol.h"

/**
 * Replay a binary packet file.
 *
 * path is borrowed for the duration of the call. handler is invoked for each
 * complete CRC-valid packet. Returns 0 on clean replay, 1 when CRC-invalid
 * packets were skipped, and -1 for file I/O or truncated-packet errors.
 */
int packet_replay_file(const char *path, PacketHandler handler, void *userdata);

#endif
