#ifndef IOC_FRAME_H
#define IOC_FRAME_H

#include <stdint.h>
#include <stdbool.h>

/* All IO Controller command frames are fixed at 32 bytes.
 *
 * Layout:
 *   byte 0      class / command / response type
 *   byte 1      sequence number
 *   byte 2      status / flags
 *   byte 3      payload length (consumer-defined)
 *   bytes 4-19  payload (up to 16 bytes)
 *   bytes 20-31 reserved / command-specific
 */
#define IOC_FRAME_SIZE  32

/* Byte offsets within a frame */
#define IOC_OFF_CLASS    0
#define IOC_OFF_SEQ      1
#define IOC_OFF_STATUS   2
#define IOC_OFF_LEN      3
#define IOC_OFF_PAYLOAD  4

/* READY reply payload, for any command that hands off to the bulk lane.
 * Status is already frame byte 2, so the payload carries the rest:
 *
 *   byte 4  transfer id   (0 means "no transfer")
 *   byte 5  direction     (BULK_DIR_*)
 *   byte 6  length low
 *   byte 7  length high
 */
#define IOC_OFF_READY_XFER_ID    (IOC_OFF_PAYLOAD + 0u)
#define IOC_OFF_READY_DIRECTION  (IOC_OFF_PAYLOAD + 1u)
#define IOC_OFF_READY_LEN_LO     (IOC_OFF_PAYLOAD + 2u)
#define IOC_OFF_READY_LEN_HI     (IOC_OFF_PAYLOAD + 3u)
/* The LBA the MCU actually DECODED from the request, echoed back so the host
 * can check it before any data moves.
 *
 * The command frame has no CRC: find_frame_start() dispatches on a header whose
 * class, sequence, status and length all validate, and the payload is not
 * checked by anything.  A false lock at a wrong bit offset therefore hands a
 * handler a garbage LBA, and a write lands 512 bytes on a sector nobody asked
 * for -- silently, reporting success.  Observed: the target sector kept its
 * previous contents while the write reported OK.
 *
 * Echoing the decoded LBA lets the host abort before the bulk phase, so a
 * mis-framed command costs a failed transfer instead of a destroyed sector.
 *
 * This is a MITIGATION, not the fix.  The fix is a CRC over the whole command
 * frame, validated before dispatch.  Until that exists, nothing else stops a
 * plausible-looking header from running a handler with corrupt arguments. */
#define IOC_OFF_READY_LBA        (IOC_OFF_PAYLOAD + 4u)
#define IOC_READY_PAYLOAD_LEN    8u

/* SD_READ_BULK request payload: 32-bit LBA, little-endian. */
#define IOC_OFF_LBA_0            (IOC_OFF_PAYLOAD + 0u)
#define IOC_SD_LBA_PAYLOAD_LEN   4u

/* XFER_STATUS reply payload: the DONE record. */
#define IOC_OFF_DONE_XFER_ID     (IOC_OFF_PAYLOAD + 0u)
#define IOC_OFF_DONE_STATUS      (IOC_OFF_PAYLOAD + 1u)
/* Bring-up diagnostic: the DONE reply also carries the first few bytes of the
 * transfer buffer, so a write can be checked against what the MCU actually
 * received rather than against what the card reads back afterwards.  That
 * separates "the host never sent it", "the de-shift produced garbage" and "the
 * card write went wrong", which are otherwise indistinguishable. */
#define IOC_OFF_DONE_PEEK        (IOC_OFF_PAYLOAD + 2u)
#define IOC_DONE_PEEK_BYTES      8u
/* Raw capture window, before de-shifting.  With the de-shifted peek above this
 * separates "the host never transmitted" from "the de-shift is wrong": the raw
 * bytes should begin 7E 81 followed by the payload at some bit offset. */
#define IOC_OFF_DONE_RAW         (IOC_OFF_PAYLOAD + 2u + IOC_DONE_PEEK_BYTES)
#define IOC_DONE_RAW_BYTES       8u
#define IOC_DONE_PAYLOAD_LEN     (2u + IOC_DONE_PEEK_BYTES + IOC_DONE_RAW_BYTES)

/* SD_READ returns this many bytes of the block in the payload area. */
#define IOC_SD_READ_BYTES  16

/* Command class bytes (Z80 → MCU) */
#define CMD_PING             0x01
#define CMD_RESET            0x02
#define CMD_SD_READ          0x03
#define CMD_BULK_TEST        0x04
#define CMD_SD_READ_BULK     0x05
#define CMD_XFER_STATUS      0x06
#define CMD_SD_WRITE_BULK    0x07

/* Response class bytes (MCU → Z80) */
#define RSP_PING             0x81
#define RSP_SD_READ          0x83
#define RSP_BULK_TEST        0x84
#define RSP_SD_READ_BULK     0x85
#define RSP_XFER_STATUS      0x86
#define RSP_SD_WRITE_BULK    0x87
#define RSP_UNKNOWN_COMMAND  0xFE

/* Status bytes */
#define IOC_STATUS_OK            0x00
#define IOC_STATUS_ERROR         0x01
#define IOC_STATUS_UNKNOWN_CMD   0x02

/* SD_READ failures.  These map one-to-one onto SdStatus so a host-side dump of
 * the status byte says which stage of the card bring-up gave up. */
#define IOC_STATUS_SD_NO_RESPONSE 0x10
#define IOC_STATUS_SD_UNUSABLE    0x11
#define IOC_STATUS_SD_NOT_READY   0x12
#define IOC_STATUS_SD_READ_FAIL   0x13
#define IOC_STATUS_SD_BUS         0x14
#define IOC_STATUS_SD_NO_CARD     0x15
#define IOC_STATUS_SD_NO_TOKEN    0x16
#define IOC_STATUS_SD_CRC         0x17
#define IOC_STATUS_SD_WRITE_FAIL  0x18
#define IOC_STATUS_SD_WRITE_REJ   0x19
#define IOC_STATUS_SD_WRITE_BUSY  0x1A

/* Bulk lane failure, reported by DONE. */
#define IOC_STATUS_BULK_FAIL      0x20
#define IOC_STATUS_BULK_NO_HOST   0x21
/* Window was clocked but the alignment preamble never appeared: the host did
 * not transmit, or started outside the search range.  Host-side, not link. */
#define IOC_STATUS_BULK_NO_SYNC   0x22
/* Payload arrived and was de-shifted, but its CRC-16 did not match.  The bulk
 * lane carries no other integrity check, so without this a corrupted block is
 * committed to the card looking exactly like a good one. */
#define IOC_STATUS_BULK_CRC       0x23

typedef struct {
    uint8_t bytes[IOC_FRAME_SIZE];
} IocFrame;

#endif /* IOC_FRAME_H */
