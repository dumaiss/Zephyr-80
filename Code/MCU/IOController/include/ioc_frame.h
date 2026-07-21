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

/* Command class bytes (Z80 → MCU) */
#define CMD_PING             0x01
#define CMD_RESET            0x02

/* Response class bytes (MCU → Z80) */
#define RSP_PING             0x81
#define RSP_UNKNOWN_COMMAND  0xFE

/* Status bytes */
#define IOC_STATUS_OK            0x00
#define IOC_STATUS_ERROR         0x01
#define IOC_STATUS_UNKNOWN_CMD   0x02

typedef struct {
    uint8_t bytes[IOC_FRAME_SIZE];
} IocFrame;

#endif /* IOC_FRAME_H */
