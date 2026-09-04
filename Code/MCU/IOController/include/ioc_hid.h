#ifndef IOC_HID_H
#define IOC_HID_H

#include <stdint.h>

typedef enum {
    HID_HOST_NOT_STARTED = 0,
    HID_HOST_CONTROLLER_READY,
    HID_HOST_SPI_ERROR,
    HID_HOST_BAD_REVISION,
    HID_HOST_INIT_FAILED
} HidHostStatus;

/* Initialise the MAX3421E and the dormant TinyUSB host core.
 *
 * This routine may block briefly while the MAX3421E oscillator starts.  The
 * wait is bounded in the XC8 port, so an absent or failed controller cannot
 * wedge the IOC boot path.  USB interrupt dispatch and enumeration are not
 * enabled by this bring-up phase. */
void hid_host_init(void);

/* Debugger-visible controller bring-up result. */
HidHostStatus hid_host_status(void);
uint8_t       hid_host_revision(void);
/* Raw /USB_INT pin level: zero means the active-low interrupt is asserted. */
uint8_t       hid_host_interrupt_level(void);

/* Result of one pass of hid_host_probe(), reported per SPI clock rate.
 *
 * revision_*  the REVISION register as last read at that rate.  0x01, 0x12 or
 *             0x13 is a live part; 0x00 or 0xFF is an undriven MISO.
 * matches_*   how many of the 64 reads in that burst produced the winning
 *             revision code.  This is the link-quality number: 64 is a clean
 *             bus, 0 means nothing legal came back at all, and anything in
 *             between is a marginal connection you can watch improve as you
 *             rework it.  revision_* alone cannot tell those apart.
 * gpout_*     GPOUT write/read-back link test at that rate.  0x00 is a clean
 *             pass.  HID_GPOUT_XFER_ERROR means the PIC's own SPI module never
 *             completed a byte, so nothing was learned about the far end.
 *             Otherwise the high nibble counts how many of the eight patterns
 *             failed and the low nibble masks the GPOUT bits that ever came
 *             back wrong.  The mask saturates to 0x0F after one glitch, so on
 *             a marginal link it is the pattern count that carries the grade.
 *
 * int_drive   command-path test that does not use MISO at all.  Bit 0 is the
 *             /USB_INT pin with PINCTL.POSINT clear (expect 1), bit 1 is the
 *             same pin with POSINT set (expect 0), so 0x01 is a pass and 0x03
 *             is "stuck high".  A pass proves the controller is powered and is
 *             receiving SPI writes, which narrows a silent MISO to U2.15 and
 *             its stub alone.
 *
 * A revision that reads correctly while the loopback fails at 4 MHz but passes
 * at 125 kHz points at U3, the CD74HC4050 buffering SCK/MOSI/CS, rather than
 * at the MAX3421E. */
/* Same value as IOC_HID_GPOUT_XFER_ERROR in ioc_frame.h, which carries it on
 * the wire.  The two headers are deliberately independent: this one describes
 * the controller, that one describes the frame. */
#define HID_GPOUT_XFER_ERROR 0xFFu

typedef struct {
    uint8_t revision_125khz;
    uint8_t revision_1mhz;
    uint8_t revision_4mhz;
    uint8_t gpout_125khz;
    uint8_t gpout_1mhz;
    uint8_t gpout_4mhz;
    uint8_t int_drive;
    uint8_t matches_125khz;
    uint8_t matches_1mhz;
    uint8_t matches_4mhz;
} HidHostProbe;

/* Reads per revision burst, and therefore the denominator of matches_*. */
#define HID_PROBE_READ_COUNT 64u

/* Live USB state, as opposed to the bring-up probes above.
 *
 * keyboard_addr is 0 when no keyboard is mounted; USB device address 0 is the
 * enumeration default address and never belongs to a configured device, so it
 * is unambiguous as a sentinel.  last_report is the boot protocol layout:
 * modifier, reserved, then six keycodes. */
typedef struct {
    uint8_t  device_count;
    uint8_t  keyboard_addr;
    uint16_t report_count;
    uint8_t  speed;             /* tusb_speed_t: 0 full, 1 low, 0xff unknown */
    uint8_t  last_report[8];
} HidHostUsbState;

/* Perform visible bring-up probes at each supported test rate.
 *
 * Each revision burst repeats the two-byte transaction 64 times so /CS, SCK
 * and MOSI are easy to trigger on with a basic oscilloscope; the loopback then
 * walks a pattern through GPOUT3-0 and reads it back.  GPX is a no-connect on
 * this board, so this is the only liveness evidence available.
 *
 * Read-only with respect to USB: does not alter the stored boot result, does
 * not acknowledge /USB_INT and does not advance TinyUSB state. */
void hid_host_probe(HidHostProbe *probe);

/* Raw controller and stack state for CMD_HID_STATUS page 1.
 *
 * port_connected is the driver's own MODE.SOFKAENAB, set by its CONDET handler
 * and by nothing else, so it answers "did the root port ever see a device"
 * independently of whether enumeration then succeeded.  mode, hirq, hrsl and
 * usbirq are read straight off the part. */
typedef struct {
    uint16_t task_calls;
    uint16_t int_dispatches;
    uint8_t  device_count;
    uint8_t  int_level;
    uint8_t  port_connected;
    uint8_t  port_speed;
    uint8_t  hirq;
    uint8_t  mode;
    uint8_t  hrsl;
    uint8_t  usbirq;
    /* Bit n set = device address n+1 is enumerated.  With CFG_TUH_DEVICE_MAX 2
     * the hub is address 3, so bit 2 is the hub itself -- which device_count
     * can never show, because tuh_mount_cb() is not called for hubs. */
    uint8_t  mounted_map;
    /* Enumeration milestones, saturating at 0xFF.  attach = the connect event
     * reached the stack; dev_desc = GET_DESCRIPTOR(device) returned;
     * cfg_desc = the configuration descriptor returned.  The first of these
     * that reads zero is where the sequence stopped. */
    uint8_t  ev_attach;
    uint8_t  ev_remove;
    uint8_t  enum_dev_desc;
    uint8_t  enum_cfg_desc;
    /* Last state process_enumeration() was entered with; FFh = never entered.
     * 5 = ADDR0_DEVICE_DESC, 6 = SET_ADDR, 7 = GET_DEVICE_DESC,
     * 16 = GET_9BYTE_CONFIG_DESC, 18 = SET_CONFIG, 19 = CONFIG_DRIVER. */
    uint8_t  enum_state;
    uint8_t  enum_fails;    /* entries with XFER_RESULT_FAILED */
    /* Control transfers refused because no completion callback was supplied.
     * Non-zero means an enumeration step is using the blocking API, which this
     * port cannot provide, and is failing silently. */
    uint8_t  ctrl_rejects;
    /* Host controller layer.  hxfrdn = transfer-done interrupts seen;
     * xferdone = handle_xfer_done() entered; epnull = it bailed because
     * find_opened_ep() returned NULL, which silently strands the transfer;
     * last_hrsl = the HRSL it saw, whose low nibble is the result code. */
    uint8_t  hxfrdn;
    uint8_t  xferdone;
    uint8_t  epnull;
    uint8_t  last_hrsl;
    /* Packed: high nibble = hcd_setup_send() calls (control transfers started),
     * low nibble = HCD_EVENT_XFER_COMPLETE events queued to the host stack.
     * Packed because only one payload byte remains. */
    uint8_t  setups_xfers;
} HidHostDebug;

void hid_host_debug(HidHostDebug *dbg);

/* The endpoint state handle_xfer_done() decided on, and the branch it took.
 * Reading that code says a SETUP must complete; on this board it does not, so
 * the values it actually worked from have to be observed. */
typedef struct {
    uint8_t  hxfr;
    uint8_t  ep_dir;
    uint8_t  peraddr;
    uint8_t  ep_num;
    uint8_t  packet_size;
    uint16_t total_len;
    uint16_t xferred_len;
    uint8_t  ep_state;
    uint8_t  xact_len;
    uint8_t  branch;
    uint8_t  hub_open_ep;
    uint8_t  hub_status_ep_before;
    uint8_t  hub_state_after_open;
    uint8_t  submit_daddr;
    uint8_t  submit_ep;
    uint8_t  setup[8];
} HidHostXfer;

void hid_host_xfer_debug(HidHostXfer *x);

/* Entry to the behind-hub enumeration branch.  See IOC_OFF_HIDE_RET for the
 * meaning of `ret`. */
typedef struct {
    uint8_t calls;
    uint8_t hub_addr;
    uint8_t hub_port;
    uint8_t ret;
    uint8_t enumerating;   /* live gate; FFh = idle */
    uint8_t defers;
    uint8_t completes;
    uint8_t att_hub_addr;
    uint8_t att_hub_port;
    uint8_t busy_lock;     /* _hcd_data.busy_lock */
    uint8_t ep_state;      /* hub int-IN: 03h = ATTEMPT_1, i.e. armed, never run */
    uint8_t ep_pktsize;
    uint8_t hub_cb_calls;    /* hub_xfer_cb() entries; 0 = never dispatched */
    uint8_t hub_arm_calls;   /* hub_edpt_status_xfer() calls */
    uint8_t hub_change;      /* last status-change byte seen */
    uint8_t ep_alloc_fail;   /* hcd_edpt_open() found the table full */
    uint8_t ep_used;
    uint8_t ep_total;
    uint8_t  ep2drv;       /* dev(3)->ep2drv[1][IN]; FFh = never bound */
    uint8_t  bind_calls;
    uint8_t  bind_drvid;
    uint16_t bind_drvlen;
    uint8_t  itf_clobbered;  /* desc_itf did not survive driver->open() */
    uint8_t  ep2drv_out;     /* ep2drv[1][OUT]; bound here = wrong direction */
} HidHostEnum;

void hid_host_enum_debug(HidHostEnum *e);

/* The HID class driver's set-config chain, which runs after the interface is
 * bound and ends by invoking tuh_hid_mount_cb(). */
typedef struct {
    uint8_t open_calls;
    uint8_t setcfg_calls;
    uint8_t proc_calls;
    uint8_t state;
    uint8_t itf_num;
    uint8_t breq;
    uint8_t result;
    uint8_t mount_calls;
    uint8_t mountcb_calls;
    /* What tuh_hid_mount_cb() was handed, before any filtering, and whether
     * tuh_hid_receive_report() accepted the first arm.  proto: 0 none,
     * 1 keyboard, 2 mouse, FFh never called. */
    uint8_t hid_mounts;
    uint8_t hid_daddr;
    uint8_t hid_inst;
    uint8_t hid_proto;
    uint8_t hid_arm;
    /* The keyboard's own interrupt-IN endpoint at address 1.  ep2drv FFh means
     * its reports are discarded before reaching the HID driver. */
    uint8_t kbd_ep_state;
    uint8_t kbd_ep_pkt;
    uint8_t kbd_ep2drv;
    uint8_t busy_lock;
    uint8_t hid_ep_in;   /* endpoint address hidh_open() captured; 81h expected */
    /* Does the keyboard's transfer reach the controller, and its completion
     * reach the HID driver and this port? */
    uint8_t kbd_submits;    /* hcd_edpt_xfer() calls for address 1 */
    uint8_t hid_xfercb;     /* hidh_xfer_cb() entries */
    uint8_t hid_xfercb_ep;  /* the endpoint it was told about */
    uint8_t rpt_cb_calls;   /* tuh_hid_report_received_cb(), before any guard */
    uint8_t rpt_daddr;
    uint8_t rpt_inst;       /* now carries p_hid->epin_size, see ioc_hid.c */
} HidHostCfg;

void hid_host_cfg_debug(HidHostCfg *c);

/* Page-3 lifecycle trace for the retained TinyUSB hub object. */
#define HID_HOST_HUB_TRACE_LEN 25u
typedef struct {
    uint8_t bytes[HID_HOST_HUB_TRACE_LEN];
} HidHostHubTrace;

void hid_host_hub_debug(HidHostHubTrace *trace);

/* One pass of USB host service: dispatch /USB_INT if asserted, then run
 * tuh_task().  Returns promptly when there is nothing to do.
 *
 * MUST be called from the main loop's idle branch only, never between a host
 * request and its reply -- enumeration can occupy the controller for a long
 * time and the SIO link will not wait.  Does nothing until the controller has
 * reached HID_HOST_CONTROLLER_READY. */
void hid_host_task(void);

/* Snapshot of what is currently attached, for CMD_HID_STATUS. */
void hid_host_usb_state(HidHostUsbState *state);

/* Nonblocking terminal-input queue.  HID boot reports are translated to
 * ASCII/control bytes and VT100 key sequences before entering this queue.
 * These routines run only from the foreground command/USB loop and are not
 * ISR-safe. */
/* True once CTRL-ALT-ESC has been seen on the USB keyboard.  Latched in the
 * report callback and acted on by the main loop, which resets the machine. */
bool hid_reset_requested(void);

uint8_t hid_input_get(void);
uint8_t hid_input_queued(void);
uint8_t hid_input_dropped(void);

#endif /* IOC_HID_H */
