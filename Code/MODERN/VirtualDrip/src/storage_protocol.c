#define _DEFAULT_SOURCE

#include "storage_protocol.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define STORAGE_STATUS_SUCCESS 0x00u
#define STORAGE_STATUS_ERROR 0x01u
#define STORAGE_DRIVE_A 0x00u
#define STORAGE_READ_REQUEST_LENGTH 6u
#define STORAGE_READ_REPLY_LENGTH (2u + STORAGE_RECORD_SIZE)
#define STORAGE_WRITE_REQUEST_LENGTH (6u + STORAGE_RECORD_SIZE)
#define STORAGE_WRITE_REPLY_LENGTH 2u
#define STORAGE_REPLY_INTER_BYTE_DELAY_US 100u
#define STORAGE_REPLY_DRAIN_TIMEOUT_MS 1000
#define STORAGE_REPLY_TURNAROUND_DELAY_US 5000u

bool storage_protocol_is_request_type(uint8_t type)
{
    return type == PACKET_STORAGE_READ_REQ || type == PACKET_STORAGE_WRITE_REQ;
}

static uint8_t storage_packet_seq(const Packet *packet)
{
    return packet->length >= 1 ? packet->payload[0] : 0;
}

static uint32_t storage_packet_lba(const Packet *packet)
{
    return (uint32_t)packet->payload[2]
        | ((uint32_t)packet->payload[3] << 8)
        | ((uint32_t)packet->payload[4] << 16)
        | ((uint32_t)packet->payload[5] << 24);
}

static bool storage_send_read_reply(SerialPort *serial_port, uint8_t seq, uint8_t status, const uint8_t *data)
{
    uint8_t reply[STORAGE_READ_REPLY_LENGTH];
    reply[0] = seq;
    reply[1] = status;
    if (data != NULL) {
        memcpy(&reply[2], data, STORAGE_RECORD_SIZE);
    } else {
        memset(&reply[2], 0, STORAGE_RECORD_SIZE);
    }

    bool sent = serial_port_send_packet_paced(
        serial_port,
        PACKET_STORAGE_READ_REPLY,
        reply,
        (uint8_t)sizeof(reply),
        STORAGE_REPLY_INTER_BYTE_DELAY_US);
    if (!sent) {
        fprintf(stderr, "Failed to send STORAGE_READ_REPLY seq=%u status=0x%02X\n", seq, status);
    }
    return sent;
}

static bool storage_send_write_reply(SerialPort *serial_port, uint8_t seq, uint8_t status)
{
    uint8_t reply[STORAGE_WRITE_REPLY_LENGTH];
    reply[0] = seq;
    reply[1] = status;

    bool sent = serial_port_send_packet_paced(
        serial_port,
        PACKET_STORAGE_WRITE_REPLY,
        reply,
        (uint8_t)sizeof(reply),
        STORAGE_REPLY_INTER_BYTE_DELAY_US);
    if (!sent) {
        fprintf(stderr, "Failed to send STORAGE_WRITE_REPLY seq=%u status=0x%02X\n", seq, status);
    }
    return sent;
}

static uint8_t storage_validate_address(const Packet *packet, uint32_t *lba_out)
{
    uint8_t drive = packet->payload[1];
    uint32_t lba = storage_packet_lba(packet);

    if (drive != STORAGE_DRIVE_A) {
        fprintf(stderr, "Storage request for unsupported drive %u\n", drive);
        return STORAGE_STATUS_ERROR;
    }
    if (lba >= STORAGE_LBA_COUNT) {
        fprintf(stderr, "Storage request for out-of-range LBA %u\n", (unsigned)lba);
        return STORAGE_STATUS_ERROR;
    }

    *lba_out = lba;
    return STORAGE_STATUS_SUCCESS;
}

static void storage_log_reply(
    const char *operation,
    uint8_t seq,
    int drive,
    uint32_t lba,
    uint8_t request_len,
    uint8_t status,
    bool sent)
{
    if (drive >= 0) {
        fprintf(stderr,
            "storage %s seq=%u drive=%d lba=%u len=%u -> status=0x%02X sent=%s\n",
            operation,
            seq,
            drive,
            (unsigned)lba,
            request_len,
            status,
            sent ? "ok" : "failed");
    } else {
        fprintf(stderr,
            "storage %s seq=%u drive=? lba=? len=%u -> status=0x%02X sent=%s\n",
            operation,
            seq,
            request_len,
            status,
            sent ? "ok" : "failed");
    }
}

static void storage_handle_read_request(
    const Packet *packet,
    SerialPort *serial_port,
    StorageBackend *storage_backend,
    bool log_storage)
{
    uint8_t seq = storage_packet_seq(packet);
    uint8_t data[STORAGE_RECORD_SIZE];
    uint32_t lba = 0;
    uint8_t status = STORAGE_STATUS_ERROR;
    int drive = -1;

    if (packet->length != STORAGE_READ_REQUEST_LENGTH) {
        fprintf(stderr, "Malformed STORAGE_READ_REQ length: %u\n", packet->length);
        bool sent = storage_send_read_reply(serial_port, seq, status, NULL);
        if (log_storage) {
            storage_log_reply("read", seq, drive, lba, packet->length, status, sent);
        }
        return;
    }

    drive = packet->payload[1];
    lba = storage_packet_lba(packet);
    status = storage_validate_address(packet, &lba);
    if (status == STORAGE_STATUS_SUCCESS) {
        if (storage_backend_read(storage_backend, lba, data)) {
            bool sent = storage_send_read_reply(serial_port, seq, STORAGE_STATUS_SUCCESS, data);
            if (log_storage) {
                storage_log_reply("read", seq, drive, lba, packet->length, STORAGE_STATUS_SUCCESS, sent);
            }
            return;
        }
        fprintf(stderr, "Storage read failed at LBA %u\n", (unsigned)lba);
    }

    bool sent = storage_send_read_reply(serial_port, seq, STORAGE_STATUS_ERROR, NULL);
    if (log_storage) {
        storage_log_reply("read", seq, drive, lba, packet->length, STORAGE_STATUS_ERROR, sent);
    }
}

static void storage_handle_write_request(
    const Packet *packet,
    SerialPort *serial_port,
    StorageBackend *storage_backend,
    bool log_storage)
{
    uint8_t seq = storage_packet_seq(packet);
    uint32_t lba = 0;
    uint8_t status = STORAGE_STATUS_ERROR;
    int drive = -1;

    if (packet->length != STORAGE_WRITE_REQUEST_LENGTH) {
        fprintf(stderr, "Malformed STORAGE_WRITE_REQ length: %u\n", packet->length);
        bool sent = storage_send_write_reply(serial_port, seq, status);
        if (log_storage) {
            storage_log_reply("write", seq, drive, lba, packet->length, status, sent);
        }
        return;
    }

    drive = packet->payload[1];
    lba = storage_packet_lba(packet);
    status = storage_validate_address(packet, &lba);
    if (status == STORAGE_STATUS_SUCCESS) {
        if (storage_backend_write(storage_backend, lba, &packet->payload[6])) {
            bool sent = storage_send_write_reply(serial_port, seq, STORAGE_STATUS_SUCCESS);
            if (log_storage) {
                storage_log_reply("write", seq, drive, lba, packet->length, STORAGE_STATUS_SUCCESS, sent);
            }
            return;
        }
        fprintf(stderr, "Storage write failed at LBA %u\n", (unsigned)lba);
    }

    bool sent = storage_send_write_reply(serial_port, seq, STORAGE_STATUS_ERROR);
    if (log_storage) {
        storage_log_reply("write", seq, drive, lba, packet->length, STORAGE_STATUS_ERROR, sent);
    }
}

static void storage_wait_for_reply_turnaround(SerialPort *serial_port)
{
    if (serial_port == NULL) {
        return;
    }

    if (!serial_port_wait_output_drained(serial_port, STORAGE_REPLY_DRAIN_TIMEOUT_MS)) {
        fprintf(stderr, "Storage reply output did not fully drain before console input was ungated\n");
    }

    /*
     * tc/TIOCOUTQ drainage proves the host driver is clear, not that the Z80 has
     * already run storage_end and restored the console RX sink. Keep the input
     * gate closed briefly so held keys cannot queue a TERMINAL_RX packet into
     * the tail of a storage transaction.
     */
    usleep(STORAGE_REPLY_TURNAROUND_DELAY_US);
}

bool storage_protocol_handle_packet(
    const Packet *packet,
    SerialPort *serial_port,
    KeyboardTransport *keyboard_transport,
    PtyConsole *pty_console,
    StorageBackend *storage_backend,
    bool log_storage)
{
    if (packet == NULL || !storage_protocol_is_request_type(packet->type)) {
        return false;
    }

    keyboard_transport_set_storage_active(keyboard_transport, true);
    pty_console_set_storage_active(pty_console, true);

    if (serial_port == NULL || storage_backend == NULL) {
        fprintf(stderr, "Storage request ignored: serial storage backend is not configured\n");
    } else if (packet->type == PACKET_STORAGE_READ_REQ) {
        storage_handle_read_request(packet, serial_port, storage_backend, log_storage);
    } else {
        storage_handle_write_request(packet, serial_port, storage_backend, log_storage);
    }

    storage_wait_for_reply_turnaround(serial_port);

    keyboard_transport_set_storage_active(keyboard_transport, false);
    pty_console_set_storage_active(pty_console, false);
    return true;
}
