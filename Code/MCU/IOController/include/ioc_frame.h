#ifndef IOC_FRAME_H
#define IOC_FRAME_H

#include <stdint.h>
#include <stdbool.h>

/* BIOS-facing command mailboxes remain fixed at 32 bytes.  They are no longer
 * the wire format: both SIO lanes use the common variable-length packet below,
 * and the transport maps between that packet and this compatibility mailbox.
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

/* Common packet used on BOTH command and bulk lanes:
 *
 *   A5 5A LEN_LO LEN_HI TYPE SEQ STATUS DATA... CRC_HI CRC_LO
 *
 * LEN counts TYPE + SEQ + STATUS + DATA.  STATUS is the first protocol
 * payload byte in both directions; requests send zero.  CRC-16-CCITT uses
 * polynomial 1021h, initial value 0000h, MSB-first processing, no final XOR,
 * and covers LEN_LO through the final DATA byte (not A5 5A).
 *
 * Keeping STATUS in every packet gives the existing mailbox a lossless mapping:
 * bytes 0/1/2 are TYPE/SEQ/STATUS, byte 3 is the derived DATA length, and bytes
 * 4.. are DATA.  Bytes 30/31 are ordinary compatibility-mailbox reserve now;
 * the transport CRC exists only on the wire. */
#define IOC_PACKET_SYNC0           0xA5u
#define IOC_PACKET_SYNC1           0x5Au
#define IOC_PACKET_FIXED_LEN       3u
#define IOC_PACKET_CRC_BYTES       2u
#define IOC_COMMAND_MAX_DATA       (IOC_FRAME_SIZE - IOC_OFF_PAYLOAD - 2u)
#define IOC_COMMAND_MAX_WIRE       (2u + 2u + IOC_PACKET_FIXED_LEN + \
                                    IOC_COMMAND_MAX_DATA + IOC_PACKET_CRC_BYTES)

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
 * separates "the host never transmitted" from "the de-shift is wrong": it
 * should contain A5 5A followed by LEN/TYPE/SEQ/STATUS/DATA at some bit phase. */
#define IOC_OFF_DONE_RAW         (IOC_OFF_PAYLOAD + 2u + IOC_DONE_PEEK_BYTES)
#define IOC_DONE_RAW_BYTES       8u
/* Bulk External-Sync discriminator, valid for either transfer direction.
 *
 * DECISION is the state sampled by the most recent MCU->Z80 Bulk send:
 *   bit 0  bulk_synced was set before the send
 *   bit 1  /SYNCA LAT was idle-high before the send
 *   bit 2  the establishing setup/sync-byte path ran
 *   bit 3  /SYNCA LAT was asserted-low after that path
 *
 * LIVE is sampled while building this reply:
 *   bit 0  bulk_synced is currently set
 *   bit 1  /SYNCA LAT is currently asserted-low
 *
 * Together they distinguish a skipped edge (decision 01h), a normal attempted
 * edge (0Eh), and a flag/line disagreement without a logic analyser. */
#define IOC_OFF_DONE_BULK_SYNC_DECISION \
    (IOC_OFF_DONE_RAW + IOC_DONE_RAW_BYTES)
#define IOC_OFF_DONE_BULK_SYNC_LIVE     \
    (IOC_OFF_DONE_BULK_SYNC_DECISION + 1u)
#define IOC_DONE_PAYLOAD_LEN     (4u + IOC_DONE_PEEK_BYTES + IOC_DONE_RAW_BYTES)

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
#define CMD_HID_STATUS       0x0D
#define CMD_HID_INPUT        0x0E

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
#define RSP_HID_STATUS       0x8D
#define RSP_HID_INPUT        0x8E

/* HID_INPUT is a nonblocking terminal-input dequeue.  The request payload is
 * one byte: the maximum number of bytes wanted (0 is a status-only query).
 * Replies carry the number still queued, the saturating count of dropped key
 * sequences, then up to 24 translated terminal bytes. */
#define IOC_OFF_HID_INPUT_MAX       IOC_OFF_PAYLOAD
#define IOC_OFF_HID_INPUT_QUEUED    (IOC_OFF_PAYLOAD + 0u)
#define IOC_OFF_HID_INPUT_DROPPED   (IOC_OFF_PAYLOAD + 1u)
#define IOC_OFF_HID_INPUT_DATA      (IOC_OFF_PAYLOAD + 2u)
#define IOC_HID_INPUT_MAX_DATA      (IOC_COMMAND_MAX_DATA - 2u)
#define IOC_HID_INPUT_META_LEN      2u

/* HID_STATUS reply payload.  /USB_INT is reported as the raw pin level so a
 * low asserted interrupt remains visible even though this bring-up phase does
 * not dispatch it. */
#define IOC_OFF_HID_STATUS         (IOC_OFF_PAYLOAD + 0u)
#define IOC_OFF_HID_REVISION       (IOC_OFF_PAYLOAD + 1u)
#define IOC_OFF_HID_USB_INT        (IOC_OFF_PAYLOAD + 2u)
#define IOC_OFF_HID_REV_125KHZ     (IOC_OFF_PAYLOAD + 3u)
#define IOC_OFF_HID_REV_1MHZ       (IOC_OFF_PAYLOAD + 4u)
#define IOC_OFF_HID_REV_4MHZ       (IOC_OFF_PAYLOAD + 5u)
/* GPOUT write/read-back link test, one result per rate.  00h passes; FFh means
 * the PIC's SPI module never completed a byte; otherwise a mask of the GPOUT
 * bits that read back wrong.  See ioc_hid.h for how to read the pattern. */
#define IOC_OFF_HID_GPOUT_125KHZ   (IOC_OFF_PAYLOAD + 6u)
#define IOC_OFF_HID_GPOUT_1MHZ     (IOC_OFF_PAYLOAD + 7u)
#define IOC_OFF_HID_GPOUT_4MHZ     (IOC_OFF_PAYLOAD + 8u)
#define IOC_HID_GPOUT_XFER_ERROR   0xFFu
/* Blind command-path test on the /USB_INT pin, which needs no MISO.  Bit 0 is
 * the pin with PINCTL.POSINT clear (expect 1), bit 1 with POSINT set (expect
 * 0).  01h passes; 03h is stuck high, meaning nothing reaches the part. */
#define IOC_OFF_HID_INT_DRIVE      (IOC_OFF_PAYLOAD + 9u)
#define IOC_HID_INT_DRIVE_PASS     0x01u
/* Link quality: how many of the 64 reads in each revision burst produced the
 * winning revision code.  40h is a clean bus, 00h is nothing legal at all, and
 * anything between is a marginal connection.  The revision byte alone cannot
 * distinguish a good bus from a lucky sample. */
#define IOC_OFF_HID_MATCH_125KHZ   (IOC_OFF_PAYLOAD + 10u)
#define IOC_OFF_HID_MATCH_1MHZ     (IOC_OFF_PAYLOAD + 11u)
#define IOC_OFF_HID_MATCH_4MHZ     (IOC_OFF_PAYLOAD + 12u)
#define IOC_HID_PROBE_READS        64u
/* Live USB state.  DEV_COUNT is devices currently mounted; KBD_ADDR is 0 when
 * no keyboard is present.  REPORTS is a 16-bit little-endian count of boot
 * reports received since mount, and LAST is that report: modifier, reserved,
 * then six keycodes. */
#define IOC_OFF_HID_DEV_COUNT      (IOC_OFF_PAYLOAD + 13u)
#define IOC_OFF_HID_KBD_ADDR       (IOC_OFF_PAYLOAD + 14u)
#define IOC_OFF_HID_REPORTS_LO     (IOC_OFF_PAYLOAD + 15u)
#define IOC_OFF_HID_REPORTS_HI     (IOC_OFF_PAYLOAD + 16u)
#define IOC_OFF_HID_LAST_REPORT    (IOC_OFF_PAYLOAD + 17u)
#define IOC_HID_LAST_REPORT_LEN    8u
/* Device speed, which on this board predicts whether the device can work at
 * all: there is an FE1.1S hub in front of every port and the MAX3421E driver
 * has no PRE-packet support, so low-speed devices behind it are unreachable.
 * 00h full, 01h low, FFh unknown. */
#define IOC_OFF_HID_KBD_SPEED      (IOC_OFF_PAYLOAD + 25u)
#define IOC_HID_SPEED_FULL         0x00u
#define IOC_HID_SPEED_LOW          0x01u
#define IOC_HID_STATUS_PAYLOAD_LEN 26u

/* CMD_HID_STATUS request selects a reply page, like CMD_PROFILE does.  Page 0
 * is the bring-up snapshot above; page 1 is raw controller/stack state, for
 * separating "nothing ever connected" from "connected but never enumerated". */
#define IOC_OFF_HID_REQ_PAGE       IOC_OFF_PAYLOAD
#define IOC_HID_PAGE_STATUS        0x00u
#define IOC_HID_PAGE_USB           0x01u
#define IOC_HID_PAGE_XFER          0x02u
#define IOC_HID_PAGE_HUB           0x03u
#define IOC_HID_PAGE_ENUM          0x04u
#define IOC_HID_PAGE_HIDCFG        0x05u

#define IOC_OFF_HIDDBG_PAGE        (IOC_OFF_PAYLOAD + 0u)
#define IOC_OFF_HIDDBG_TASK_LO     (IOC_OFF_PAYLOAD + 1u)
#define IOC_OFF_HIDDBG_TASK_HI     (IOC_OFF_PAYLOAD + 2u)
#define IOC_OFF_HIDDBG_INTS_LO     (IOC_OFF_PAYLOAD + 3u)
#define IOC_OFF_HIDDBG_INTS_HI     (IOC_OFF_PAYLOAD + 4u)
#define IOC_OFF_HIDDBG_DEVICES     (IOC_OFF_PAYLOAD + 5u)
#define IOC_OFF_HIDDBG_INT_LEVEL   (IOC_OFF_PAYLOAD + 6u)
#define IOC_OFF_HIDDBG_CONNECTED   (IOC_OFF_PAYLOAD + 7u)
#define IOC_OFF_HIDDBG_SPEED       (IOC_OFF_PAYLOAD + 8u)
#define IOC_OFF_HIDDBG_HIRQ        (IOC_OFF_PAYLOAD + 9u)
#define IOC_OFF_HIDDBG_MODE        (IOC_OFF_PAYLOAD + 10u)
#define IOC_OFF_HIDDBG_HRSL        (IOC_OFF_PAYLOAD + 11u)
#define IOC_OFF_HIDDBG_USBIRQ      (IOC_OFF_PAYLOAD + 12u)
#define IOC_OFF_HIDDBG_MOUNTED     (IOC_OFF_PAYLOAD + 13u)
#define IOC_OFF_HIDDBG_EV_ATTACH   (IOC_OFF_PAYLOAD + 14u)
#define IOC_OFF_HIDDBG_EV_REMOVE   (IOC_OFF_PAYLOAD + 15u)
#define IOC_OFF_HIDDBG_DEV_DESC    (IOC_OFF_PAYLOAD + 16u)
#define IOC_OFF_HIDDBG_CFG_DESC    (IOC_OFF_PAYLOAD + 17u)
#define IOC_OFF_HIDDBG_ENUM_STATE  (IOC_OFF_PAYLOAD + 18u)
#define IOC_OFF_HIDDBG_ENUM_FAILS  (IOC_OFF_PAYLOAD + 19u)
#define IOC_OFF_HIDDBG_CTRL_REJ    (IOC_OFF_PAYLOAD + 20u)
#define IOC_OFF_HIDDBG_HXFRDN      (IOC_OFF_PAYLOAD + 21u)
#define IOC_OFF_HIDDBG_XFERDONE    (IOC_OFF_PAYLOAD + 22u)
#define IOC_OFF_HIDDBG_EPNULL      (IOC_OFF_PAYLOAD + 23u)
#define IOC_OFF_HIDDBG_LASTHRSL    (IOC_OFF_PAYLOAD + 24u)
#define IOC_OFF_HIDDBG_SETUP_XFER  (IOC_OFF_PAYLOAD + 25u)
/* At the transport's ceiling: IOC_COMMAND_MAX_DATA is 26. */
#define IOC_HID_USB_PAYLOAD_LEN    26u

/* Page 2: the state handle_xfer_done() branched on.  Page 1 is full -- the
 * transport caps a reply at IOC_COMMAND_MAX_DATA -- so this is a second page
 * rather than evidence deleted to make room. */
#define IOC_OFF_HIDX_PAGE          (IOC_OFF_PAYLOAD + 0u)
#define IOC_OFF_HIDX_HXFR          (IOC_OFF_PAYLOAD + 1u)
#define IOC_OFF_HIDX_EPDIR         (IOC_OFF_PAYLOAD + 2u)
#define IOC_OFF_HIDX_PERADDR       (IOC_OFF_PAYLOAD + 3u)
#define IOC_OFF_HIDX_EPNUM         (IOC_OFF_PAYLOAD + 4u)
#define IOC_OFF_HIDX_PKTSIZE       (IOC_OFF_PAYLOAD + 5u)
#define IOC_OFF_HIDX_TOTAL_LO      (IOC_OFF_PAYLOAD + 6u)
#define IOC_OFF_HIDX_TOTAL_HI      (IOC_OFF_PAYLOAD + 7u)
#define IOC_OFF_HIDX_XFERRED_LO    (IOC_OFF_PAYLOAD + 8u)
#define IOC_OFF_HIDX_XFERRED_HI    (IOC_OFF_PAYLOAD + 9u)
#define IOC_OFF_HIDX_EPSTATE       (IOC_OFF_PAYLOAD + 10u)
#define IOC_OFF_HIDX_XACTLEN       (IOC_OFF_PAYLOAD + 11u)
/* 1 = completed (OUT/SETUP), 2 = took xact_out, 3 = re-issued HXFR (IN),
 * 4 = completed (IN), 0 = the branch was never reached. */
#define IOC_OFF_HIDX_BRANCH        (IOC_OFF_PAYLOAD + 12u)
#define IOC_OFF_HIDX_HUB_OPEN_EP   (IOC_OFF_PAYLOAD + 13u)
#define IOC_OFF_HIDX_HUB_PRE_EP    (IOC_OFF_PAYLOAD + 14u)
#define IOC_OFF_HIDX_HUB_AFTER_OPEN (IOC_OFF_PAYLOAD + 15u)
#define IOC_OFF_HIDX_SUBMIT_ADDR   (IOC_OFF_PAYLOAD + 16u)
#define IOC_OFF_HIDX_SUBMIT_EP     (IOC_OFF_PAYLOAD + 17u)
#define IOC_OFF_HIDX_SETUP         (IOC_OFF_PAYLOAD + 18u)
#define IOC_HID_XFER_PAYLOAD_LEN   26u

/* Page 3: page byte followed by the 25-byte hub lifecycle trace. */
#define IOC_OFF_HIDH_PAGE          (IOC_OFF_PAYLOAD + 0u)
#define IOC_OFF_HIDH_TRACE         (IOC_OFF_PAYLOAD + 1u)
#define IOC_HID_HUB_TRACE_LEN      25u
#define IOC_HID_HUB_PAYLOAD_LEN    26u

/* Page 4: downstream enumeration entry.  RET is FFh if the behind-hub branch
 * of enum_new_device() was never reached, FEh if it was reached but hub_port
 * was zero, 00h if hub_port_get_status() refused, 01h if it accepted. */
#define IOC_OFF_HIDE_PAGE          (IOC_OFF_PAYLOAD + 0u)
#define IOC_OFF_HIDE_CALLS         (IOC_OFF_PAYLOAD + 1u)
#define IOC_OFF_HIDE_HUB_ADDR      (IOC_OFF_PAYLOAD + 2u)
#define IOC_OFF_HIDE_HUB_PORT      (IOC_OFF_PAYLOAD + 3u)
#define IOC_OFF_HIDE_RET           (IOC_OFF_PAYLOAD + 4u)
/* ENUMERATING is the live _usbh_data.enumerating_daddr.  FFh means idle and
 * ready for a new attach; anything else means the attach path defers and
 * re-queues, which presents as an unbounded attach count. */
#define IOC_OFF_HIDE_ENUMERATING   (IOC_OFF_PAYLOAD + 5u)
#define IOC_OFF_HIDE_DEFERS        (IOC_OFF_PAYLOAD + 6u)
#define IOC_OFF_HIDE_COMPLETES     (IOC_OFF_PAYLOAD + 7u)
#define IOC_OFF_HIDE_ATT_ADDR      (IOC_OFF_PAYLOAD + 8u)
#define IOC_OFF_HIDE_ATT_PORT      (IOC_OFF_PAYLOAD + 9u)
/* Host-controller stall state.  BUSY is _hcd_data.busy_lock; EPSTATE and
 * EPPKT are the hub's interrupt-IN endpoint (addr 3, ep 1, IN).  State 03h is
 * EP_STATE_ATTEMPT_1 -- armed but never started, and the FRAME retry ignores
 * it because that test is strictly greater than ATTEMPT_1. */
#define IOC_OFF_HIDE_BUSY          (IOC_OFF_PAYLOAD + 10u)
#define IOC_OFF_HIDE_EPSTATE       (IOC_OFF_PAYLOAD + 11u)
#define IOC_OFF_HIDE_EPPKT         (IOC_OFF_PAYLOAD + 12u)
/* Hub class-driver dispatch.  CBCALLS is hub_xfer_cb() entries -- zero means
 * the completed status transfer never reached the hub driver at all.  ARMCALLS
 * is hub_edpt_status_xfer() calls.  CHANGE is the last status-change byte. */
#define IOC_OFF_HIDE_HUBCB         (IOC_OFF_PAYLOAD + 13u)
#define IOC_OFF_HIDE_HUBARM        (IOC_OFF_PAYLOAD + 14u)
#define IOC_OFF_HIDE_HUBCHANGE     (IOC_OFF_PAYLOAD + 15u)
/* Endpoint table: allocation failures, slots in use, slots total. */
#define IOC_OFF_HIDE_EPFAIL        (IOC_OFF_PAYLOAD + 16u)
#define IOC_OFF_HIDE_EPUSED        (IOC_OFF_PAYLOAD + 17u)
#define IOC_OFF_HIDE_EPTOTAL       (IOC_OFF_PAYLOAD + 18u)
/* Endpoint-to-driver binding.  EP2DRV is dev(3)->ep2drv[1][IN]: FFh means the
 * endpoint was never bound to a class driver, so its completions are dropped.
 * FEh means no such device. */
#define IOC_OFF_HIDE_EP2DRV        (IOC_OFF_PAYLOAD + 19u)
#define IOC_OFF_HIDE_BINDCALLS     (IOC_OFF_PAYLOAD + 20u)
#define IOC_OFF_HIDE_BINDDRVID     (IOC_OFF_PAYLOAD + 21u)
#define IOC_OFF_HIDE_BINDLEN_LO    (IOC_OFF_PAYLOAD + 22u)
#define IOC_OFF_HIDE_BINDLEN_HI    (IOC_OFF_PAYLOAD + 23u)
/* Set when desc_itf did not survive a nested driver->open() call. */
#define IOC_OFF_HIDE_ITFCLOB       (IOC_OFF_PAYLOAD + 24u)
/* ep2drv[1][OUT].  If the bind wrote here instead of [IN], tu_edpt_dir()
 * returned the wrong direction and the map is written to the wrong slot. */
#define IOC_OFF_HIDE_EP2DRVOUT     (IOC_OFF_PAYLOAD + 25u)
#define IOC_HID_ENUM_PAYLOAD_LEN   26u

/* Page 5: the HID class driver's set-config chain.  STATE is the last value
 * process_set_config() was entered with: 0 SET_IDLE, 1 SET_PROTOCOL,
 * 2 GET_REPORT_DESC, 3 COMPLETE, FFh never entered.  ITFNUM and BREQ are read
 * through xfer->setup, a pointer to a caller local -- garbage there sends
 * requests to a nonexistent interface, which a device answers with STALL. */
#define IOC_OFF_HIDC_PAGE          (IOC_OFF_PAYLOAD + 0u)
#define IOC_OFF_HIDC_OPEN          (IOC_OFF_PAYLOAD + 1u)
#define IOC_OFF_HIDC_SETCFG        (IOC_OFF_PAYLOAD + 2u)
#define IOC_OFF_HIDC_PROC          (IOC_OFF_PAYLOAD + 3u)
#define IOC_OFF_HIDC_STATE         (IOC_OFF_PAYLOAD + 4u)
#define IOC_OFF_HIDC_ITFNUM        (IOC_OFF_PAYLOAD + 5u)
#define IOC_OFF_HIDC_BREQ          (IOC_OFF_PAYLOAD + 6u)
#define IOC_OFF_HIDC_RESULT        (IOC_OFF_PAYLOAD + 7u)
#define IOC_OFF_HIDC_MOUNT         (IOC_OFF_PAYLOAD + 8u)
#define IOC_OFF_HIDC_MOUNTCB       (IOC_OFF_PAYLOAD + 9u)
#define IOC_OFF_HIDC_MOUNTS        (IOC_OFF_PAYLOAD + 10u)
#define IOC_OFF_HIDC_DADDR         (IOC_OFF_PAYLOAD + 11u)
#define IOC_OFF_HIDC_INST          (IOC_OFF_PAYLOAD + 12u)
#define IOC_OFF_HIDC_PROTO         (IOC_OFF_PAYLOAD + 13u)
#define IOC_OFF_HIDC_ARM           (IOC_OFF_PAYLOAD + 14u)
#define IOC_OFF_HIDC_KBDSTATE      (IOC_OFF_PAYLOAD + 15u)
#define IOC_OFF_HIDC_KBDPKT        (IOC_OFF_PAYLOAD + 16u)
#define IOC_OFF_HIDC_KBDEP2DRV     (IOC_OFF_PAYLOAD + 17u)
#define IOC_OFF_HIDC_BUSY          (IOC_OFF_PAYLOAD + 18u)
#define IOC_OFF_HIDC_EPIN          (IOC_OFF_PAYLOAD + 19u)
#define IOC_OFF_HIDC_KSUBMIT       (IOC_OFF_PAYLOAD + 20u)
#define IOC_OFF_HIDC_XFERCB        (IOC_OFF_PAYLOAD + 21u)
#define IOC_OFF_HIDC_XFERCBEP      (IOC_OFF_PAYLOAD + 22u)
#define IOC_OFF_HIDC_RPTCB         (IOC_OFF_PAYLOAD + 23u)
#define IOC_OFF_HIDC_RPTDADDR      (IOC_OFF_PAYLOAD + 24u)
#define IOC_OFF_HIDC_RPTINST       (IOC_OFF_PAYLOAD + 25u)
#define IOC_HID_HIDCFG_PAYLOAD_LEN 26u

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
/* A one-byte PROFILE request with this value asks for a clean measurement
 * interval.  The reset is deferred until the reply has completely left the
 * command lane, so the reset transaction is not counted in the new interval. */
#define IOC_OFF_PROFILE_CONTROL  IOC_OFF_PAYLOAD
#define IOC_OFF_PROFILE_PAGE     (IOC_OFF_PAYLOAD + 1u)
#define IOC_PROFILE_RESET        0x01u
#define IOC_PROFILE_PAGE_SUMMARY 0x00u
#define IOC_PROFILE_PAGE_BULK_TX 0x01u
#define IOC_PROFILE_BULK_TX_LEN  8u

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
 *  18  common A5/5A LEN16 TYPE SEQ STATUS/DATA CRC16 packet envelope on both
 *      command and bulk lanes; persistent External Sync is unchanged
 *  19  first-transfer sync byte is disposable; a complete A5/5A packet always
 *      follows through SPI, so packet marking is independent of /SYNC timing
 *  20  PROFILE owns Timer3 instead of the command edge counter, and a one-byte
 *      IOC_PROFILE_RESET request starts a clean measurement interval
 *  21  PROFILE page 1 reports bulk-TX wait, preparation, data and teardown
 *      totals; the bulk payload loop streams CRC while SPI2 shifts each byte
 *  22  HID_STATUS reports the MAX3421E bring-up result, revision register and
 *      live /USB_INT pin level without servicing USB or starting enumeration
 *  23  HID_STATUS actively performs visible, read-only MAX3421E revision
 *      bursts at 125 kHz, 1 MHz and 4 MHz and reports all three results
 *  24  MAX3421E is taken out of its power-on half-duplex SPI mode before any
 *      register is read, without which nothing can be read back at all on this
 *      board; HID_STATUS adds a GPOUT write/read-back link test per rate
 *  25  HID_STATUS adds the /USB_INT drive test, which commands the controller
 *      blind and watches its own output pin, separating "cannot hear us" from
 *      "cannot answer us" without relying on MISO
 *  26  revision bursts report a majority verdict and a match count out of 64
 *      rather than the last sample, and the GPOUT result carries a failing-
 *      pattern count, so a marginal link can be graded instead of guessed at
 *  27  USB enumeration is live: /USB_INT is switched to level mode and polled
 *      from the main loop's idle branch, tuh_task() runs, and HID_STATUS
 *      reports mounted devices plus the latest boot keyboard report, and the
 *      mounted device's speed
 *  28  HID_STATUS takes a page selector; page 1 reports raw MAX3421E and stack
 *      state (port connect, MODE/HIRQ/HRSL/USBIRQ, task and dispatch counts)
 *  29  port supplies tusb_time_delay_ms_api() so enumeration delays cannot
 *      complete early on a coarse tick; HID_STATUS page 1 adds the enumerated
 *      address map, which unlike the device count can see the hub
 *  30  HID_STATUS page 1 adds enumeration milestone counters (attach event,
 *      device descriptor, configuration descriptor) to locate where the
 *      enumeration sequence stops
 *  31  HID_STATUS page 1 reports the last enumeration state, the failed-attempt
 *      count, and control transfers refused for lacking a completion callback
 *  32  HID_STATUS page 1 adds host-controller taps: HXFRDN count, xfer-done
 *      count, find_opened_ep() failures, and the last HRSL seen at completion
 *  33  HID_STATUS page 1 adds started-vs-reported transfer counts, packed into
 *      the last payload byte the transport allows
 *  34  HID_STATUS page 2 reports the endpoint state handle_xfer_done() branched
 *      on, and which branch it took
 *  35  XC8 stages TinyUSB events in dedicated storage before queueing, avoiding
 *      static-auto overlay corruption of completion events
 *  36  XC8 preserves the hub interrupt endpoint address across tuh_edpt_open(),
 *      avoiding a second static-auto overlay that changed endpoint 81h to 00h
 *  37  HID_STATUS page 2 traces the hub endpoint from descriptor parsing to
 *      HCD submission and reports the last control SETUP packet
 *  38  XC8 stores the hub interrupt endpoint from the initialized diagnostic
 *      capture and page 2 snapshots the hub state immediately after that store
 *  39  HID_STATUS page 3 traces the retained hub object through open, class
 *      configuration, hub descriptor completion and each port-power callback
 *  60  HID report arming floors an impossible zero packet length and counts
 *      every intentional HID-interface clear to distinguish state loss from
 *      an unobserved close/reinitialization
 *  61  XC8 preserves hidh_open()'s HID-object pointer across the nested
 *      endpoint-open call; HID_STATUS now reports the actual retained ep_in
 *      field rather than the descriptor-side capture
 *  62  boot-keyboard press transitions are translated to terminal bytes and
 *      queued for the nonblocking HID_INPUT command
 *  66  XFER_STATUS reports the Bulk persistent-sync branch decision and live
 *      PIC flag and /SYNCA state for marker-loss diagnosis
 *  67  Z80-to-MCU Bulk releases /CTSA after packet/CRC acceptance; the
 *      command READY gate, not the transport admission line, covers a slow
 *      SD commit
 *  68  SD trace preserves final CMD0/CMD8/CMD55/ACMD41 responses and the
 *      ACMD41 iteration/baud/state snapshot when card initialisation fails
 */
#define IOC_FW_LEVEL  68

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

/* PING reply diagnostics.  PING echoes request DATA bytes 4..19, then appends
 * fields at 20..29 and declares the full 26-byte command DATA length. */
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
 *   TX edges  preceding steady-state full PING reply plus its trailer,
 *             expected 36 * 8 = 288 (0120h)
 *
 * The first establishing PING reply also has two setup clocks and one
 * disposable sync byte, so it measures 298 (012Ah).  A shorter preceding
 * response legitimately reports fewer.
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
