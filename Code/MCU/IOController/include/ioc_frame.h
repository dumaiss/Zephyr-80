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

/* Frame integrity: CRC-16 over bytes 0..29, stored little-endian at 30..31.
 *
 * Not decoration.  find_frame_start() walks candidate bit offsets and used to
 * dispatch on a header whose class, sequence, status and length all validated
 * -- which is four bytes of evidence, and a wrong bit alignment can supply them
 * by coincidence.  Two observed consequences:
 *
 *   - a CMD_SD_READ_BULK decoded as CMD_PING, replying RSP_PING and putting
 *     every later reply one transaction out of step;
 *   - a write landing on a sector nobody asked for, reporting success, because
 *     the LBA payload was never checked by anything.
 *
 * The second is silent destruction of unrelated data.  A frame is now dispatched
 * only if the CRC passes; the header check survives purely as a cheap pre-filter
 * so the search does not compute 128 CRCs per window.
 *
 * Same CRC-16-CCITT as the bulk lane, so sio_link_crc16_update() is shared. */
#define IOC_OFF_CRC_LO   30u
#define IOC_OFF_CRC_HI   31u
#define IOC_CRC_COVERED  30u

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
/* The LBA (or record number) the MCU actually DECODED from the request, echoed
 * back so the host can check it before any data moves.
 *
 * This began as a mitigation for a command lane with no CRC, where a false bit
 * lock could hand a handler a garbage LBA and land a write on a sector nobody
 * asked for -- silently, reporting success.  Observed at the time: the target
 * sector kept its previous contents while the write reported OK.
 *
 * The frame CRC above is now the real fix, and it is checked before dispatch.
 * The echo stays because it is nearly free and it checks a different thing: the
 * CRC proves the frame arrived intact, the echo proves the MCU and the host
 * agree on what the frame MEANT.  A decode bug on either side survives a
 * perfect CRC. */
#define IOC_OFF_READY_LBA        (IOC_OFF_PAYLOAD + 4u)
#define IOC_READY_PAYLOAD_LEN    8u

/* SD_READ_BULK request payload: 32-bit LBA, little-endian. */
#define IOC_OFF_LBA_0            (IOC_OFF_PAYLOAD + 0u)
#define IOC_SD_LBA_PAYLOAD_LEN   4u

/* SD_READ_REC / SD_WRITE_REC request payload: 32-bit CP/M record number, in the
 * same slot as the LBA so one decode path serves both.
 *
 * 8 MiB / 128 = 65536 records, so the volume needs only 16 bits today.  The
 * field is 32 anyway: it sits exactly at the 16-bit ceiling, and widening a
 * protocol field after the fact breaks every .com file already on the disk. */
#define IOC_OFF_RECORD_0         (IOC_OFF_PAYLOAD + 0u)
#define IOC_SD_RECORD_PAYLOAD_LEN 4u
#define IOC_SD_RECORD_BYTES      128u

/* XFER_STATUS REQUEST payload: which part of the raw capture window to return.
 *
 * Eight bytes of window is enough to see that a transfer went wrong and not
 * enough to say how.  A sync failure needs to be told apart three ways -- the
 * host never transmitted, the preamble is present but past the search, or the
 * preamble is corrupt -- and the first eight bytes look similar in all three.
 *
 * Byte 4 of the request is a window offset in bytes.  Zero, which every
 * existing caller sends because they zero the frame, means the same window as
 * before, so this is backward compatible. */
#define IOC_OFF_STATUS_RAW_OFF   (IOC_OFF_PAYLOAD + 0u)

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
/* Record-addressed access, served from the SD block cache.  These are what the
 * CP/M BIOS storage driver uses; the block-addressed commands above stay for
 * bring-up tools that need to bypass the cache. */
#define CMD_SD_READ_REC      0x08
#define CMD_SD_WRITE_REC     0x09
#define CMD_SD_FLUSH         0x0A
#define CMD_PROFILE          0x0B
#define CMD_LINK_SYNC        0x0C

/* Response class bytes (MCU → Z80) */
#define RSP_PING             0x81
#define RSP_SD_READ          0x83
#define RSP_BULK_TEST        0x84
#define RSP_SD_READ_BULK     0x85
#define RSP_XFER_STATUS      0x86
#define RSP_SD_WRITE_BULK    0x87
#define RSP_SD_READ_REC      0x88
#define RSP_SD_WRITE_REC     0x89
#define RSP_SD_FLUSH         0x8A
#define RSP_PROFILE          0x8B
#define RSP_LINK_SYNC        0x8C

/* Six 16-bit millisecond totals at bytes 4-15; see timebase.h for the slots. */
#define IOC_OFF_PROFILE_0        (IOC_OFF_PAYLOAD + 0u)
#define IOC_OFF_PROFILE_CALLS    (IOC_OFF_PAYLOAD + 12u)
#define IOC_OFF_PROFILE_ABORTS   (IOC_OFF_PAYLOAD + 14u)
/* SD CMD0 response trace, 8 bytes.  Carried by PROFILE because PING has no
 * spare bytes and this is a bring-up diagnostic, not a hot-path field.
 * See sd_card.h: all FFh = nothing driving DO; all 00h = DO stuck low; mixed
 * junk = the card IS talking and the fault is clocking or alignment; 01h
 * present = CMD0 actually succeeded and the failure is later. */
#define IOC_OFF_PROFILE_SDTRACE  (IOC_OFF_PAYLOAD + 16u)
#define IOC_PROFILE_PAYLOAD_LEN  24u

#define RSP_UNKNOWN_COMMAND  0xFE

/* Firmware capability level, returned by PING.
 *
 * Bump this whenever the frame protocol gains something a host can depend on.
 * It exists because "is the controller running the firmware I just built?" has
 * twice been answered wrongly by inference, and each time cost a debugging
 * round: once when an unflashed build replied RSP_UNKNOWN_COMMAND to a new
 * class, and once when a stale build silently ignored a new request field and
 * returned the same window slice six times.
 *
 *   1  base two-lane transport: PING, SD_READ, BULK_TEST, SD_READ_BULK,
 *      XFER_STATUS, SD_WRITE_BULK
 *   2  frame CRC and rolling sequence
 *   3  bulk-lane CRC in both directions
 *   4  record commands and the SD block cache: SD_READ_REC, SD_WRITE_REC,
 *      SD_FLUSH; XFER_STATUS honours a raw-window offset; the DONE peek
 *      follows the armed receive buffer
 *   5  bulk writes carry a sacrificial lead-in byte before the preamble, and
 *      the receive search widened to 128 bits to keep its late-start margin
 *   6  power handshake: /PWR_OFF driven idle from the first instructions of
 *      startup, /SHUTDOWN_RQ latched and debounced, and both reported by PING
 */
#define IOC_FW_LEVEL  15

/* PING reply: a snapshot of the power handshake pins.
 *
 * Diagnostic, and the cheapest way to answer the question that keeps coming up:
 * is the controller driving /PWR_OFF, and is the PMU asking for anything? Both
 * ends of that handshake are invisible from the host otherwise, and guessing
 * between "the controller is not running" and "something on the card holds the
 * net low" has already cost several rounds.
 *
 *   bit 0  /PWR_OFF pin level      (PORTF6) 1 = keep power on
 *   bit 1  /PWR_OFF drive level    (LATF6)  what we are asking for
 *   bit 2  /PWR_OFF is an output   (TRIS=0) 1 = we own the pin
 *   bit 3  /SHUTDOWN_RQ pin level  (PORTF7) 0 = the PMU is asking
 *   bit 4  /SHUTDOWN_RQ edge latch (INT2IF) 1 = a falling edge was seen
 *   bit 5  /SHUTDOWN_RQ pull-up on (WPUF7)
 *
 * Bits 0 and 1 disagreeing is the interesting case: it means the pin is being
 * driven to one level and sitting at the other, which is a short or a pull
 * stronger than the driver rather than anything in firmware.
 */
#define IOC_OFF_PING_POWER  21u
#define IOC_PING_PWR_OFF_PIN    0x01u
#define IOC_PING_PWR_OFF_LAT    0x02u
#define IOC_PING_PWR_OFF_DRIVEN 0x04u
#define IOC_PING_SHUTDOWN_PIN   0x08u
#define IOC_PING_SHUTDOWN_LATCH 0x10u
#define IOC_PING_SHUTDOWN_WPU   0x20u
#define IOC_PING_LINK_SYNCED    0x40u

/* PING reply: the firmware level.  In the RESERVED area, not the payload --
 * PING echoes bytes 4..19 verbatim and that echo is what proves the round trip,
 * so it must not be overwritten. */
/* Service-loop counters, little-endian.
 *
 * These were in the PROFILE reply, which is a SECOND transaction issued right
 * after PING -- and on an intermittent link the second transaction is precisely
 * the one that fails, so the most useful counter was behind the least reliable
 * path.  They displace the SD retry/re-init counters, which have measured zero
 * on every run since they were added.
 *
 * calls  = every entry to service_command_request()
 * aborts = those that gave up before dispatching, i.e. the request did not
 *          decode.  The gap between them is requests thrown away. */
#define IOC_OFF_PING_CALLS_LO   22u
#define IOC_OFF_PING_CALLS_HI   23u
#define IOC_OFF_PING_ABORTS_LO  24u
#define IOC_OFF_PING_ABORTS_HI  25u

/* Bytes 26-29: temporary command-lane source-clock diagnostics.
 *
 * The PIC routes RB3/SCK back into Timer1 and counts rising edges at the PIC
 * pin, not calls to sio_link_exchange().  That includes any PPS/SPI transition
 * the source arithmetic cannot see.  It does not see a transition created
 * downstream by enabling or disabling a 74AHCT125 gate; matching RB3's idle
 * level to the gated clock's pull-up prevents those transitions.  A PING
 * handler runs after its request window but before its reply, so it reports:
 *
 *   RX edges  current request window, expected 36 * 8 = 288 (0120h)
 *   TX edges  preceding reply window, expected 34 * 8 = 272 (0110h)
 *
 * This temporarily displaces the record-read/cache-miss counters. */
#define IOC_OFF_PING_RX_EDGES_LO 26u
#define IOC_OFF_PING_RX_EDGES_HI 27u
#define IOC_OFF_PING_TX_EDGES_LO 28u
#define IOC_OFF_PING_TX_EDGES_HI 29u

/* Legacy names kept so older host tools still assemble; these offsets now
 * carry the edge counters documented above. */
#define IOC_OFF_PING_RECREAD_LO 26u
#define IOC_OFF_PING_RECREAD_HI 27u
#define IOC_OFF_PING_MISS_LO    28u
#define IOC_OFF_PING_MISS_HI    29u

#define IOC_OFF_PING_LEVEL  20u

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
