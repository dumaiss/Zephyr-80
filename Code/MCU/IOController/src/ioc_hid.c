#include <xc.h>
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#include "tusb.h"
#include "host/usbh_pvt.h"
#include "host/hcd.h"

#include "config.h"
#include "spi1_bus.h"
#include "timebase.h"
#include "ioc_hid.h"
#include "controller_latch.h"

/* Live USB state, owned by the TinyUSB callbacks below and read out by
 * CMD_HID_STATUS.  Updated only from hid_host_task(), which the main loop runs
 * in its idle branch, so no interrupt discipline is needed here. */
static uint8_t  usb_device_count;
static uint8_t  usb_mount_count;
static uint8_t  usb_unmount_count;
static uint8_t  usb_last_device_addr = 0xffu;
static uint16_t usb_last_device_vid  = 0xffffu;
static uint16_t usb_last_device_pid  = 0xffffu;
static uint8_t  keyboard_addr;      /* 0 = no keyboard mounted */
static uint8_t  keyboard_instance;
static uint8_t  keyboard_speed;     /* tusb_speed_t, 0xff when unknown */

/* Logitech F310 support is intentionally tied to its DirectInput USB identity
 * and fixed 8-byte report.  In XInput mode the device has a different PID and
 * is not exposed as this HID interface. */
#define F310_VID                    0x046du
#define F310_DIRECTINPUT_PID        0xc216u
#define GAMEPAD_POLL_MS             10u
#define GAMEPAD_SLOT_NONE           0xffu
static uint8_t  gamepad_addr[CONTROLLER_LATCH_PORTS];
static uint8_t  gamepad_instance[CONTROLLER_LATCH_PORTS];
static bool     gamepad_report_pending[CONTROLLER_LATCH_PORTS];
static uint32_t gamepad_next_poll_ms[CONTROLLER_LATCH_PORTS];
static uint8_t  gamepad_first_arm[CONTROLLER_LATCH_PORTS];
static uint16_t gamepad_reports[CONTROLLER_LATCH_PORTS];
static uint8_t  gamepad_last_len[CONTROLLER_LATCH_PORTS];
/* What tuh_hid_mount_cb() was actually handed, recorded before any filtering. */
static uint8_t  hid_mount_calls;
static uint8_t  hid_mount_daddr = 0xffu;
static uint8_t  hid_mount_inst  = 0xffu;
static uint8_t  hid_mount_proto = 0xffu;
static uint8_t  hid_arm_ok      = 0xffu;
/* Passed by pointer into tuh_vid_pid_get().  These must not be automatic
 * locals: XC8's non-reentrant overlay has corrupted caller locals across
 * nested TinyUSB calls elsewhere in this port. */
static uint16_t hid_mount_vid = 0xffffu;
static uint16_t hid_mount_pid = 0xffffu;
static uint16_t keyboard_reports;
static uint8_t  keyboard_last[8];
static uint16_t usb_task_calls;      /* proves the main loop reaches us */
static uint16_t usb_int_dispatches;  /* times /USB_INT was found asserted */

/* Terminal input is deliberately owned by the HID module.  Storage and the
 * transport only see an opaque byte stream.  Escape sequences are admitted as
 * a unit so a nearly-full queue can never expose half of a VT100 key. */
#define HID_INPUT_QUEUE_SIZE 128u
static uint8_t input_queue[HID_INPUT_QUEUE_SIZE];
static uint8_t input_head;
static uint8_t input_tail;
static uint8_t input_count;
static uint8_t input_drop_count;
/* Total bytes pushed into and pulled out of the input queue.  Comparing these
 * against the moment a key is pressed says whether the delay is before the
 * queue (decode) or after it (poll/host). */
static uint8_t input_put_total;
static uint8_t input_get_total;
static uint8_t caps_lock;
static uint8_t num_lock;

/* Keyboard LEDs.  The boot-protocol output report is a single byte, and it is
 * written with a SET_REPORT control transfer -- so this buffer MUST be static:
 * the transfer is asynchronous and TinyUSB still references it after
 * tuh_hid_set_report() returns.  A local here would be a use-after-return that
 * happens to work whenever the stack is not reused quickly enough. */
#define HID_LED_NUM_LOCK   0x01u
#define HID_LED_CAPS_LOCK  0x02u
static uint8_t led_report;
static bool    led_dirty;

/* Auto-repeat.  Boot keyboards report on state change only -- nothing at all
 * arrives while a key is simply held -- so the repeat has to be synthesised
 * from the task against a millisecond clock. */
#define REPEAT_DELAY_MS   500u
#define REPEAT_PERIOD_MS   60u
static uint8_t  repeat_key;   /* 0 = nothing repeating */
static uint8_t  repeat_mod;
static uint32_t repeat_due_ms;

/* hid_host_task() scratch.  Deliberately static: these live across calls into
 * translate_key() and its nested helpers, which is exactly the shape XC8's
 * static-auto overlay corrupts.  See docs/max3421-bring-up-debug.md. */
static uint32_t task_now_ms;

static uint8_t gamepad_slot_for(uint8_t dev_addr, uint8_t instance)
{
    uint8_t slot;

    for (slot = 0u; slot < CONTROLLER_LATCH_PORTS; slot++) {
        if (gamepad_addr[slot] == dev_addr &&
            gamepad_instance[slot] == instance)
            return slot;
    }
    return GAMEPAD_SLOT_NONE;
}

static void gamepad_unmount(uint8_t dev_addr, uint8_t instance,
                            bool match_instance)
{
    uint8_t slot;

    for (slot = 0u; slot < CONTROLLER_LATCH_PORTS; slot++) {
        if (gamepad_addr[slot] == dev_addr &&
            (!match_instance || gamepad_instance[slot] == instance)) {
            gamepad_addr[slot]           = 0u;
            gamepad_instance[slot]       = 0u;
            gamepad_report_pending[slot] = false;
            gamepad_next_poll_ms[slot]   = 0uL;
            gamepad_first_arm[slot]      = 0xffu;
            controller_latch_release(slot);
        }
    }
}

static void led_refresh(void)
{
    uint8_t want = 0u;

    if (num_lock != 0u)
        want |= HID_LED_NUM_LOCK;
    if (caps_lock != 0u)
        want |= HID_LED_CAPS_LOCK;

    if (want != led_report) {
        led_report = want;
        led_dirty  = true;
    }
}

/* TinyUSB's US boot-keyboard table is const, so XC8 places it in program
 * space.  It covers printable keys plus CR, ESC, BS and TAB; navigation and
 * function keys are translated explicitly below. */
static const uint8_t keycode_ascii[128][2] = { HID_KEYCODE_TO_ASCII };

static void input_drop(void)
{
    if (input_drop_count != 0xffu)
        input_drop_count++;
}

static bool input_reserve(uint8_t len)
{
    if ((uint8_t)(HID_INPUT_QUEUE_SIZE - input_count) < len) {
        input_drop();
        return false;
    }
    return true;
}

static void input_put_unchecked(uint8_t value)
{
    input_queue[input_head] = value;
    input_head = (uint8_t)((input_head + 1u) & (HID_INPUT_QUEUE_SIZE - 1u));
    input_count++;
    if (input_put_total != 0xffu)
        input_put_total++;
}

static void input_put_byte(uint8_t value)
{
    if (input_reserve(1u))
        input_put_unchecked(value);
}

static bool key_was_down(uint8_t keycode)
{
    uint8_t i;

    for (i = 2u; i < 8u; i++) {
        if (keyboard_last[i] == keycode)
            return true;
    }
    return false;
}

static void input_put_escape(uint8_t introducer, uint8_t final)
{
    if (!input_reserve(3u))
        return;
    input_put_unchecked(0x1bu);
    input_put_unchecked(introducer);
    input_put_unchecked(final);
}

static void input_put_csi_number(uint8_t tens, uint8_t ones)
{
    uint8_t len = (tens != 0u) ? 5u : 4u;

    if (!input_reserve(len))
        return;
    input_put_unchecked(0x1bu);
    input_put_unchecked('[');
    if (tens != 0u) {
        input_put_unchecked((uint8_t)('0' + tens));
    }
    input_put_unchecked((uint8_t)('0' + ones));
    input_put_unchecked('~');
}

static void translate_key(uint8_t keycode, uint8_t modifier)
{
    bool shift = (modifier & (KEYBOARD_MODIFIER_LEFTSHIFT |
                              KEYBOARD_MODIFIER_RIGHTSHIFT)) != 0u;
    bool ctrl = (modifier & (KEYBOARD_MODIFIER_LEFTCTRL |
                             KEYBOARD_MODIFIER_RIGHTCTRL)) != 0u;
    uint8_t value;

    if (keycode == HID_KEY_CAPS_LOCK) {
        caps_lock ^= 1u;
        led_refresh();
        return;
    }

    if (keycode == HID_KEY_NUM_LOCK) {
        num_lock ^= 1u;
        led_refresh();
        return;
    }

    if (ctrl) {
        if (keycode >= HID_KEY_A && keycode <= HID_KEY_Z) {
            input_put_byte((uint8_t)(keycode - HID_KEY_A + 1u));
            return;
        }
        if (keycode == HID_KEY_BRACKET_LEFT)  { input_put_byte(0x1bu); return; }
        if (keycode == HID_KEY_BACKSLASH)     { input_put_byte(0x1cu); return; }
        if (keycode == HID_KEY_BRACKET_RIGHT) { input_put_byte(0x1du); return; }
        if (keycode == HID_KEY_6)             { input_put_byte(0x1eu); return; }
        if (keycode == HID_KEY_MINUS)         { input_put_byte(0x1fu); return; }
        if (keycode == HID_KEY_2 || keycode == HID_KEY_SPACE) {
            input_put_byte(0x00u);
            return;
        }
    }

    /* NumLock off puts the keypad on its navigation layer.  This has to be
     * decided before the ASCII table below, which has entries for the keypad
     * digits and would otherwise answer first.  The keypad was unconditionally
     * numeric until the LED existed; with a light on the key, ignoring the
     * state would make the light a lie. */
    if (num_lock == 0u) {
        switch (keycode) {
        case HID_KEY_KEYPAD_7: input_put_escape('[', 'H');   return;
        case HID_KEY_KEYPAD_8: input_put_escape('[', 'A');   return;
        case HID_KEY_KEYPAD_9: input_put_csi_number(0u, 5u); return;
        case HID_KEY_KEYPAD_4: input_put_escape('[', 'D');   return;
        case HID_KEY_KEYPAD_6: input_put_escape('[', 'C');   return;
        case HID_KEY_KEYPAD_1: input_put_escape('[', 'F');   return;
        case HID_KEY_KEYPAD_2: input_put_escape('[', 'B');   return;
        case HID_KEY_KEYPAD_3: input_put_csi_number(0u, 6u); return;
        case HID_KEY_KEYPAD_0: input_put_csi_number(0u, 2u); return;
        case HID_KEY_KEYPAD_DECIMAL: input_put_csi_number(0u, 3u); return;
        default: break;
        }
    }

    if (keycode < 128u) {
        bool upper = shift;
        if (keycode >= HID_KEY_A && keycode <= HID_KEY_Z)
            upper = (bool)(shift ^ (caps_lock != 0u));
        value = keycode_ascii[keycode][upper ? 1u : 0u];
        if (value != 0u) {
            input_put_byte(value);
            return;
        }
    }

    switch (keycode) {
    case HID_KEY_ARROW_UP:    input_put_escape('[', 'A'); return;
    case HID_KEY_ARROW_DOWN:  input_put_escape('[', 'B'); return;
    case HID_KEY_ARROW_RIGHT: input_put_escape('[', 'C'); return;
    case HID_KEY_ARROW_LEFT:  input_put_escape('[', 'D'); return;
    case HID_KEY_HOME:        input_put_escape('[', 'H'); return;
    case HID_KEY_END:         input_put_escape('[', 'F'); return;
    case HID_KEY_INSERT:      input_put_csi_number(0u, 2u); return;
    case HID_KEY_DELETE:      input_put_csi_number(0u, 3u); return;
    case HID_KEY_PAGE_UP:     input_put_csi_number(0u, 5u); return;
    case HID_KEY_PAGE_DOWN:   input_put_csi_number(0u, 6u); return;
    case HID_KEY_F1: input_put_escape('O', 'P'); return;
    case HID_KEY_F2: input_put_escape('O', 'Q'); return;
    case HID_KEY_F3: input_put_escape('O', 'R'); return;
    case HID_KEY_F4: input_put_escape('O', 'S'); return;
    case HID_KEY_F5:  input_put_csi_number(1u, 5u); return;
    case HID_KEY_F6:  input_put_csi_number(1u, 7u); return;
    case HID_KEY_F7:  input_put_csi_number(1u, 8u); return;
    case HID_KEY_F8:  input_put_csi_number(1u, 9u); return;
    case HID_KEY_F9:  input_put_csi_number(2u, 0u); return;
    case HID_KEY_F10: input_put_csi_number(2u, 1u); return;
    case HID_KEY_F11: input_put_csi_number(2u, 3u); return;
    case HID_KEY_F12: input_put_csi_number(2u, 4u); return;
    case HID_KEY_KEYPAD_DIVIDE:   input_put_byte('/'); return;
    case HID_KEY_KEYPAD_MULTIPLY: input_put_byte('*'); return;
    case HID_KEY_KEYPAD_SUBTRACT: input_put_byte('-'); return;
    case HID_KEY_KEYPAD_ADD:      input_put_byte('+'); return;
    case HID_KEY_KEYPAD_ENTER:    input_put_byte('\r'); return;
    case HID_KEY_KEYPAD_1: input_put_byte('1'); return;
    case HID_KEY_KEYPAD_2: input_put_byte('2'); return;
    case HID_KEY_KEYPAD_3: input_put_byte('3'); return;
    case HID_KEY_KEYPAD_4: input_put_byte('4'); return;
    case HID_KEY_KEYPAD_5: input_put_byte('5'); return;
    case HID_KEY_KEYPAD_6: input_put_byte('6'); return;
    case HID_KEY_KEYPAD_7: input_put_byte('7'); return;
    case HID_KEY_KEYPAD_8: input_put_byte('8'); return;
    case HID_KEY_KEYPAD_9: input_put_byte('9'); return;
    case HID_KEY_KEYPAD_0: input_put_byte('0'); return;
    case HID_KEY_KEYPAD_DECIMAL: input_put_byte('.'); return;
    default: return;
    }
}

uint8_t hid_input_get(void)
{
    uint8_t value;

    if (input_count == 0u)
        return 0u;
    value = input_queue[input_tail];
    input_tail = (uint8_t)((input_tail + 1u) & (HID_INPUT_QUEUE_SIZE - 1u));
    input_count--;
    if (input_get_total != 0xffu)
        input_get_total++;
    return value;
}

uint8_t hid_input_queued(void)
{
    return input_count;
}

uint8_t hid_input_dropped(void)
{
    return input_drop_count;
}

/* Enumeration milestone counters.
 *
 * "Nothing is mounted" says only that the sequence did not finish, not where it
 * stopped, and the sequence is long: attach event -> debounce -> bus reset ->
 * GET_DESCRIPTOR(device) -> reset -> SET_ADDRESS -> GET_DESCRIPTOR(config) ->
 * SET_CONFIG -> driver open.  These four counters bracket it, so a single run
 * says which link broke instead of which one held.
 *
 * Saturating at 0xFF: the interesting distinction is zero versus non-zero, and
 * a wrapped counter that reads 00 would be a lie in exactly the wrong place. */
static uint8_t ev_attach;
static uint8_t ev_remove;
static uint8_t enum_dev_desc;
static uint8_t enum_cfg_desc;
static uint8_t ev_xfer;      /* XFER_COMPLETE events queued, capped at 15 */

static void bump(uint8_t *counter)
{
    if (*counter != 0xffu)
        (*counter)++;
}


static HidHostStatus controller_status;
static uint8_t       controller_revision;
static bool          spi_failed;
static uint16_t      last_timebase_tick;
static uint32_t      usb_time_ms;

/* MAX3421E supports SPI clocks up to 26 MHz.  Four MHz is already proven on
 * this physical bus by the SD soak test and matches TinyUSB's own conservative
 * MAX3421E example setting. */
#define HID_SPI_BAUD             SPI1_BAUD_4MHZ
#define HID_PROBE_READS          64u

/* Command byte: Reg[7:3] | 0[2] | DIR[1] | ACKSTAT[0].  DIR = 1 is a write. */
#define MAX3421_REVISION_READ    0x90u   /* R18 << 3, DIR = 0 */
#define MAX3421_PINCTL_WRITE     0x8Au   /* R17 << 3, DIR = 1 */
#define MAX3421_PINCTL_FDUPSPI   0x10u
#define MAX3421_PINCTL_INTLEVEL  0x08u

/* PINCTL as the running system wants it.
 *
 * INTLEVEL matters more than it looks.  Cleared -- TinyUSB's default -- /USB_INT
 * is an edge output that emits a pulse as short as 10.6 us.  This firmware has
 * no interrupt handler; the main loop polls, and it can be busy inside a bulk
 * transfer or an SD write for milliseconds at a time, so it would miss those
 * pulses outright and USB would simply stall.
 *
 * Set, INT becomes an open-drain LEVEL output that stays asserted until the
 * last pending IRQ flag is cleared -- which a poll cannot miss however late it
 * arrives.  The datasheet requires an external pull-up for this mode and the
 * board has one: R7, 10k to 3V3 on the mezzanine.  The hardware was wired for
 * level mode; only the default was wrong. */
#define MAX3421_PINCTL_RUN       (MAX3421_PINCTL_FDUPSPI | MAX3421_PINCTL_INTLEVEL)
#define MAX3421_IOPINS1_READ     0xA0u   /* R20 << 3, DIR = 0 */
#define MAX3421_IOPINS1_WRITE    0xA2u   /* R20 << 3, DIR = 1 */
#define MAX3421_CPUCTL_WRITE     0x82u   /* R16 << 3, DIR = 1 */
#define MAX3421_USBIRQ_READ      0x68u   /* R13 << 3, DIR = 0 */
#define MAX3421_HIRQ_READ        0xC8u   /* R25 << 3, DIR = 0 */
#define MAX3421_MODE_READ        0xD8u   /* R27 << 3, DIR = 0 */
#define MAX3421_HRSL_READ        0xF8u   /* R31 << 3, DIR = 0 */
#define MAX3421_PINCTL_POSINT    0x04u
#define MAX3421_CPUCTL_IE        0x01u

#define MAX3421_REVISION_1       0x01u
#define MAX3421_REVISION_2       0x12u
#define MAX3421_REVISION_3       0x13u

/* GPOUT3-0 occupy the low nibble of IOPINS1; GPIN3-0 occupy the high one. */
#define HID_GPOUT_MASK           0x0Fu

/* Write/read-back patterns for the link test.
 *
 * A walking one on its own cannot separate a bit that is stuck low from a bit
 * that is never driven at all, and it cannot see a bridge between two lines
 * that are always written to opposite states.  00 and 0F pin both stuck-at
 * faults, and 05/0A cross every adjacent pair in both directions. */
static const uint8_t hid_gpout_patterns[] = {
    0x00u, 0x01u, 0x02u, 0x04u, 0x08u, 0x05u, 0x0Au, 0x0Fu
};

/* THE FIRST ACCESS MUST BE THIS WRITE.  NOTHING CAN BE READ BEFORE IT.
 *
 * The MAX3421E powers up in HALF-DUPLEX SPI mode (PINCTL.FDUPSPI = 0 is the
 * power-on default).  In half-duplex it tri-states MISO entirely and drives
 * read data back out of its own MOSI pin, which the datasheet's Figure 11
 * note 3 warns the master must stop driving to avoid contention.
 *
 * This board cannot do that.  SPI_MOSI reaches U2 through U3, a CD74HC4050
 * running at 3V3 that buffers PIC -> MAX3421E only (it is there to translate
 * the PIC's 5 V levels down; SPI_MISO comes straight back unbuffered).  So a
 * half-duplex read has nowhere to go: the PIC samples an undriven MISO while
 * the MAX3421E's output stage fights the 4050's on the MOSI stub.  Every read
 * returns garbage and every read is a driver fight.
 *
 * A WRITE, however, works identically in both modes -- the master drives MOSI
 * for the whole cycle and the MAX3421E never turns its driver on.  So the one
 * blind write below is the bootstrap, and only after it can anything be read.
 * TinyUSB's hcd_init() orders itself the same way for the same reason: it
 * writes PINCTL first and reads REVISION second.
 *
 * FDUPSPI survives a chip reset: RES and CHIPRES clear every register except
 * PINCTL (R17), USBCTL (R15) and the SPI logic.  Only a power cycle puts the
 * part back into half-duplex.  hcd_init()'s CHIPRES is therefore safe. */
static bool reg_write_at(uint8_t baud, uint8_t command, uint8_t value)
{
    uint8_t discard;
    bool    ok;

    spi1_bus_configure(baud, SPI1_MSB_FIRST);
    spi1_bus_select(SPI1_DEVICE_USB);

    ok = spi1_bus_transfer(command, &discard) &&
         spi1_bus_transfer(value, &discard);

    spi1_bus_select(SPI1_DEVICE_NONE);

    if (!ok)
        spi_failed = true;

    return ok;
}

static bool reg_read_at(uint8_t baud, uint8_t command, uint8_t *value)
{
    uint8_t discard;
    bool    ok;

    spi1_bus_configure(baud, SPI1_MSB_FIRST);
    spi1_bus_select(SPI1_DEVICE_USB);

    ok = spi1_bus_transfer(command, &discard) &&
         spi1_bus_transfer(0u, value);

    spi1_bus_select(SPI1_DEVICE_NONE);

    if (!ok) {
        spi_failed = true;
        *value = 0u;
    }

    return ok;
}

static bool select_full_duplex(uint8_t baud)
{
    return reg_write_at(baud, MAX3421_PINCTL_WRITE, MAX3421_PINCTL_FDUPSPI);
}

static uint8_t read_revision_at(uint8_t baud)
{
    uint8_t revision;

    (void)reg_read_at(baud, MAX3421_REVISION_READ, &revision);
    return revision;
}

/* Write/read-back link test on the four unconnected GPOUT pins.
 *
 * This is the substitute for the liveness probe this board does not have: GPX
 * would have carried OPERATE, but U2.17 is a no-connect, so there is no pin to
 * put a meter on.  Reading REVISION proves a little; a register whose value we
 * chose proves considerably more, because a constant can be matched by a bus
 * that is stuck in exactly the wrong way and a walking pattern cannot.
 *
 * Run per rate on purpose.  The failure this is really looking for is U3, the
 * CD74HC4050 in front of SCK/MOSI/CS: propagation delay there is fixed, so a
 * marginal part passes at 125 kHz and fails at 4 MHz.  A single-rate test
 * would report that board as healthy.
 *
 * All eight GPOUT pins are unconnected on this design, so driving them has no
 * effect outside the part, and TinyUSB never touches IOPINS1 or IOPINS2.
 *
 * Returns 0 for a clean pass, HID_GPOUT_XFER_ERROR if the SPI module itself
 * did not complete a transfer, otherwise a mask of the GPOUT bits that
 * mismatched on at least one pattern. */
/* Can the controller hear us at all?  A test that needs no MISO.
 *
 * Every observation so far comes back through MISO, and MISO is silent -- which
 * is equally consistent with "the part never receives a command" and with "the
 * part is fine but cannot answer".  Those need separating, and the board gives
 * us exactly one other pin to do it with: INT, U2.18, an *output* of the
 * MAX3421E, pulled up 10k to 3V3 and landing on PIC RA0.
 *
 * Writes need no MISO whatsoever, so the part can be commanded completely
 * blind.  With INTLEVEL = 0 the datasheet makes INT "an edge active push-pull
 * output", and Figure 12 gives its *inactive* level as high for negative edge
 * (POSINT = 0) and low for positive edge (POSINT = 1).  So POSINT selects a DC
 * level that the part actively drives, with no dependence on the oscillator, on
 * USB traffic, or on any interrupt actually being pending.
 *
 * The asymmetry that makes this trustworthy: RA0's only pull is 10k to 3V3, so
 * a LOW on that net cannot be produced by anything except U2 driving it.  A low
 * is therefore positive proof; a stuck high is the negative result.
 *
 * Returns bit 0 = RA0 with POSINT clear (expect 1), bit 1 = RA0 with POSINT set
 * (expect 0), so 0x01 is a pass.  0x03 is stuck high -- nothing is reaching the
 * part.  HID_GPOUT_XFER_ERROR if the PIC's own SPI module gave up. */
#define HID_INT_TEST_USB_ACTIVE 0xFEu

#if IOC_DIAGNOSTIC_BUILD
/* Active MAX3421E probes and the HIDSTATUS detail-page accessors.
 *
 * The probes write controller registers and change SPI speed, so they can
 * never be part of a passive status: reading the health of the link must not
 * be able to change it.  The accessors exist only to format detail pages 1-5,
 * which are themselves diagnostic-build only. */
static uint8_t int_drive_test(uint8_t baud)
{
    uint8_t result = 0u;

    /* Only meaningful while the controller is otherwise idle.  Once USB is
     * live, FRAMEIRQ alone asserts INT every millisecond, so the pin no longer
     * reflects POSINT and this test reports a confident-looking nonsense value
     * -- it read "02 inverted" the first time a hub attached.  A diagnostic
     * that lies once the system starts working is worse than one that declines
     * to answer. */
    if (controller_status == HID_HOST_CONTROLLER_READY &&
        hcd_port_connect_status(0u))
        return HID_INT_TEST_USB_ACTIVE;

    if (!select_full_duplex(baud) ||
        !reg_write_at(baud, MAX3421_CPUCTL_WRITE, MAX3421_CPUCTL_IE))
        return HID_GPOUT_XFER_ERROR;

    /* POSINT = 0: negative-edge mode, so the idle level is driven high. */
    __delay_us(50);
    result |= (uint8_t)(USB_INT_PORT ? 1u : 0u);

    /* POSINT = 1: positive-edge mode, so the idle level is driven low. */
    if (!reg_write_at(baud, MAX3421_PINCTL_WRITE,
                      MAX3421_PINCTL_FDUPSPI | MAX3421_PINCTL_POSINT))
        return HID_GPOUT_XFER_ERROR;

    __delay_us(50);
    result |= (uint8_t)(USB_INT_PORT ? 2u : 0u);

    /* Put the pin back to inactive-high, and restore the interrupt enable to
     * whatever this phase expects rather than unconditionally clearing it.
     *
     * Leaving IE clear would mean that merely *running HIDSTAT* silently
     * disarms /USB_INT once the enumeration phase starts dispatching it -- a
     * diagnostic that breaks the thing it exists to observe, and one that would
     * present as "enumeration stops working after you look at it".
     *
     * These two values are exactly what hcd_init() leaves behind when the host
     * is up: PINCTL = _tuh_cfg.pinctl | FDUPSPI and CPUCTL = _tuh_cfg.cpuctl |
     * IE, both with the configured halves at their default zero. */
    (void)reg_write_at(baud, MAX3421_PINCTL_WRITE,
                       (controller_status == HID_HOST_CONTROLLER_READY)
                           ? MAX3421_PINCTL_RUN : MAX3421_PINCTL_FDUPSPI);
    (void)reg_write_at(baud, MAX3421_CPUCTL_WRITE,
                       (controller_status == HID_HOST_CONTROLLER_READY)
                           ? MAX3421_CPUCTL_IE : 0u);

    /* Briefly leaving level mode above cannot lose an interrupt: clearing
     * INTLEVEL does not clear the IRQ flags, so restoring it re-asserts INT if
     * anything was still pending. */

    return result;
}

static uint8_t gpout_loopback_at(uint8_t baud)
{
    uint8_t i;
    uint8_t fail = 0u;
    uint8_t bad  = 0u;
    uint8_t bad_patterns = 0u;

    /* Full duplex first.  In half duplex the read-back cannot return anything
     * whatever the wiring is like, and the test would blame the board for the
     * mode it was left in. */
    if (!select_full_duplex(baud))
        return HID_GPOUT_XFER_ERROR;

    for (i = 0u; i < (uint8_t)sizeof hid_gpout_patterns; i++) {
        uint8_t wrote = hid_gpout_patterns[i];
        uint8_t read_back;

        if (!reg_write_at(baud, MAX3421_IOPINS1_WRITE, wrote) ||
            !reg_read_at(baud, MAX3421_IOPINS1_READ, &read_back))
            return HID_GPOUT_XFER_ERROR;

        /* GPIN3-0 share this register and are unconnected here, so they float
         * and must be masked out before the comparison. */
        bad = (uint8_t)((read_back ^ wrote) & HID_GPOUT_MASK);
        if (bad != 0u)
            bad_patterns++;
        fail |= bad;
    }

    /* Pack how many of the eight patterns failed above which bits ever failed.
     * On a marginal link the OR of the bit masks saturates to 0x0F after a
     * single glitch and stops distinguishing "one bad byte in sixteen" from
     * "nothing works"; the pattern count keeps grading it. */
    fail = (uint8_t)((bad_patterns << 4) | fail);

    /* Park the outputs at zero so the register is left in a known state. */
    (void)reg_write_at(baud, MAX3421_IOPINS1_WRITE, 0u);

    return fail;
}
#endif /* IOC_DIAGNOSTIC_BUILD */

void hid_host_init(void)
{
    uint8_t slot;

    input_head               = 0u;
    input_tail               = 0u;
    input_count              = 0u;
    input_drop_count         = 0u;
    caps_lock                = 0u;
    num_lock                 = 1u;   /* keypad numeric at power-on, as before */
    led_report               = 0u;
    led_dirty                = false;
    repeat_key               = 0u;
    keyboard_speed           = 0xffu;
    controller_status        = HID_HOST_NOT_STARTED;
    controller_revision      = 0u;
    spi_failed               = false;
    last_timebase_tick       = timebase_ticks();
    usb_time_ms              = 0uL;
    usb_device_count         = 0u;
    usb_mount_count          = 0u;
    usb_unmount_count        = 0u;
    usb_last_device_addr     = 0xffu;
    usb_last_device_vid      = 0xffffu;
    usb_last_device_pid      = 0xffffu;
    hid_mount_calls          = 0u;
    hid_mount_daddr          = 0xffu;
    hid_mount_inst           = 0xffu;
    hid_mount_proto          = 0xffu;
    hid_arm_ok               = 0xffu;
    hid_mount_vid            = 0xffffu;
    hid_mount_pid            = 0xffffu;
    for (slot = 0u; slot < CONTROLLER_LATCH_PORTS; slot++) {
        gamepad_addr[slot]           = 0u;
        gamepad_instance[slot]       = 0u;
        gamepad_report_pending[slot] = false;
        gamepad_next_poll_ms[slot]   = 0uL;
        gamepad_first_arm[slot]      = 0xffu;
        gamepad_reports[slot]        = 0u;
        gamepad_last_len[slot]       = 0u;
    }

    /* Bootstrap out of half-duplex before the first read.  Without this the
     * revision probe below can only ever fail, and its failure would return
     * early from a check whose precondition is established by tuh_init() --
     * the very call the check gates.  That is a lock with no key. */
    if (!select_full_duplex(HID_SPI_BAUD)) {
        controller_status = HID_HOST_SPI_ERROR;
        return;
    }

    controller_revision = read_revision_at(HID_SPI_BAUD);
    if (spi_failed) {
        controller_status = HID_HOST_SPI_ERROR;
        return;
    }

    if (controller_revision != MAX3421_REVISION_1 &&
        controller_revision != MAX3421_REVISION_2 &&
        controller_revision != MAX3421_REVISION_3) {
        controller_status = HID_HOST_BAD_REVISION;
        return;
    }

    /* Ask for level-mode INT before the stack brings the controller up.
     * hcd_init() writes PINCTL once, from _tuh_cfg, and ORs FDUPSPI in itself
     * (the field's documentation says that bit is ignored here). */
    {
        tuh_configure_param_t cfg;

        cfg.max3421.max_nak = 1u;
        cfg.max3421.cpuctl  = 0u;
        cfg.max3421.pinctl  = MAX3421_PINCTL_INTLEVEL;

        if (!tuh_configure(0u, TUH_CFGID_MAX3421, &cfg)) {
            controller_status = HID_HOST_INIT_FAILED;
            return;
        }
    }

    if (!tuh_init(0u) || spi_failed) {
        controller_status = spi_failed ? HID_HOST_SPI_ERROR
                                       : HID_HOST_INIT_FAILED;
        return;
    }

    controller_status = HID_HOST_CONTROLLER_READY;
}

/* One pass of USB service.  Called only from the main loop's idle branch.
 *
 * Placement is the whole design here.  The loop owes the Z80 a prompt answer on
 * /SIO1B_INT, and enumeration is not quick -- descriptor fetches, hub port
 * resets and the settling delays the spec requires all live inside tuh_task().
 * Running it between a request and its reply would starve the SIO exactly the
 * way the bulk lane starves the console link, so it runs where sd_cache_tick()
 * runs: after the command service has completed, never inside it.
 *
 * tuh_task() itself does not block.  With CFG_TUSB_OS = OPT_OS_NONE the event
 * queue read is documented as always behaving as a zero timeout, so a pass with
 * nothing to do is cheap and returns immediately. */
void hid_host_task(void)
{
    if (controller_status != HID_HOST_CONTROLLER_READY)
        return;

    usb_task_calls++;

    /* Level-mode INT, so this is a state to sample rather than an edge to
     * catch, and a late poll still sees it. */
    if (USB_INT_PORT == USB_INT_ACTIVE) {
        usb_int_dispatches++;
        hcd_int_handler(0u, false);
    }

    tuh_task();

    /* The MAX3421E backend currently does not honour interrupt endpoint
     * bInterval (its scheduler carries an explicit TODO), so immediately
     * re-arming an F310 would poll it as fast as the main loop can run.  Pace
     * only gamepad requests here.  Timer2 advances the USB clock in 10 ms
     * quanta, making the requested 10 ms controller cadence exact at this
     * layer; a failed submit is retried on the next foreground pass. */
    task_now_ms = tusb_time_millis_api();
    {
        uint8_t slot;

        for (slot = 0u; slot < CONTROLLER_LATCH_PORTS; slot++) {
            if (gamepad_addr[slot] != 0u &&
                !gamepad_report_pending[slot] &&
                (int32_t)(task_now_ms - gamepad_next_poll_ms[slot]) >= 0) {
                if (tuh_hid_receive_report(gamepad_addr[slot],
                                           gamepad_instance[slot]))
                    gamepad_report_pending[slot] = true;
            }
        }
    }

    /* LEDs are written here rather than from translate_key(): SET_REPORT is a
     * control transfer, and issuing one from inside the report callback would
     * re-enter the control pipe in the middle of USB processing.  If the pipe
     * is busy the call fails and the flag simply stays set for the next pass. */
    if (led_dirty && keyboard_addr != 0u) {
        if (tuh_hid_set_report(keyboard_addr, keyboard_instance, 0u,
                               HID_REPORT_TYPE_OUTPUT, &led_report, 1u))
            led_dirty = false;
    }

    /* Auto-repeat.  Nothing arrives from the keyboard while a key is held, so
     * the repeat is generated here against the millisecond clock. */
    if (repeat_key != 0u && keyboard_addr != 0u) {
        task_now_ms = tusb_time_millis_api();
        if ((int32_t)(task_now_ms - repeat_due_ms) >= 0) {
            /* Never let repeat consume the queue.  A key held down with
             * nothing draining would otherwise spend the whole buffer and
             * start counting drops, losing real keystrokes behind it. */
            if (hid_input_queued() < (uint8_t)(HID_INPUT_QUEUE_SIZE / 2u))
                translate_key(repeat_key, repeat_mod);
            repeat_due_ms = task_now_ms + REPEAT_PERIOD_MS;
        }
    }
}

/* Raw controller and stack state, for telling "nothing was ever plugged in"
 * apart from "something connected but enumeration did not finish".
 *
 * device_count alone cannot separate those: it only advances on tuh_mount_cb,
 * which fires at the END of enumeration.  A hub that is seen but never
 * enumerated and a hub that is simply not powered both report zero. */
#if IOC_DIAGNOSTIC_BUILD
/* TinyUSB bring-up traces.  Declared here only so the HIDSTATUS detail pages
 * can format them; both are diagnostic-build only, so leaving these visible in
 * a normal build would be dead ABI pointing at storage nothing reads. */
/* Debug taps inside the vendored TinyUSB, see host/usbh.c. */
extern uint8_t usbh_xc8_ctrl_rejects;
extern uint8_t usbh_xc8_enum_state;
extern uint8_t usbh_xc8_enum_fails;
extern uint8_t usbh_xc8_hxfrdn;
extern uint8_t usbh_xc8_xferdone;
extern uint8_t usbh_xc8_epnull;
extern uint8_t usbh_xc8_lasthrsl;
extern uint8_t usbh_xc8_setups;
extern uint8_t  usbh_xc8_d_hxfr;
extern uint8_t  usbh_xc8_d_epdir;
extern uint8_t  usbh_xc8_d_peraddr;
extern uint8_t  usbh_xc8_d_epnum;
extern uint8_t  usbh_xc8_d_pktsize;
extern uint16_t usbh_xc8_d_total;
extern uint16_t usbh_xc8_d_xferred;
extern uint8_t  usbh_xc8_d_epstate;
extern uint8_t  usbh_xc8_d_branch;
extern uint8_t  usbh_xc8_d_xactlen;
extern uint8_t xc8_saved_hub_ep;
extern uint8_t usbh_xc8_hub_status_ep_before;
extern uint8_t usbh_xc8_hub_state_after_open;
extern uint8_t usbh_xc8_submit_daddr;
extern uint8_t usbh_xc8_submit_ep;
extern uint8_t usbh_xc8_last_setup[8];
extern uint8_t usbh_xc8_hub_trace[HID_HOST_HUB_TRACE_LEN];

extern uint8_t usbh_xc8_hubenum_calls;
extern uint8_t usbh_xc8_hubenum_addr;
extern uint8_t usbh_xc8_hubenum_port;
extern uint8_t usbh_xc8_hubenum_ret;
extern uint8_t usbh_xc8_defer_count;
extern uint8_t usbh_xc8_enum_complete;
extern uint8_t usbh_xc8_att_hub_addr;
extern uint8_t usbh_xc8_att_hub_port;
extern uint8_t usbh_xc8_get_enumerating(void);
extern uint8_t usbh_xc8_hub_cb_calls;
extern uint8_t usbh_xc8_hub_arm_calls;
extern uint8_t usbh_xc8_hub_status_change;
extern uint8_t usbh_xc8_ep_alloc_fail;
extern uint8_t usbh_xc8_get_ep_used(void);
extern uint8_t usbh_xc8_get_ep_total(void);
extern uint8_t  usbh_xc8_bind_calls;
extern uint8_t  usbh_xc8_bind_drvid;
extern uint16_t usbh_xc8_bind_drvlen;
extern uint8_t  usbh_xc8_itf_clobbered;
extern uint8_t  usbh_xc8_get_ep2drv(uint8_t daddr, uint8_t epnum, uint8_t dir);
extern uint8_t usbh_xc8_get_busy_lock(void);
extern uint8_t usbh_xc8_get_ep_state(uint8_t daddr, uint8_t ep_num, uint8_t dir);
extern uint8_t usbh_xc8_get_ep_pktsize(uint8_t daddr, uint8_t ep_num, uint8_t dir);

extern uint8_t usbh_xc8_hid_open_calls;
extern uint8_t usbh_xc8_hid_setcfg_calls;
extern uint8_t usbh_xc8_hid_proc_calls;
extern uint8_t usbh_xc8_hid_state;
extern uint8_t usbh_xc8_hid_itfnum;
extern uint8_t usbh_xc8_hid_breq;
extern uint8_t usbh_xc8_hid_result;
extern uint8_t usbh_xc8_hid_mount_calls;
extern uint8_t usbh_xc8_mountcb_calls;
extern uint8_t xc8_saved_hid_ep_addr;
extern uint8_t usbh_xc8_hid_xfercb;
extern uint8_t usbh_xc8_hid_xfercb_ep;
extern uint8_t usbh_xc8_hid_xfercb_idx;
extern uint8_t usbh_xc8_kbd_submits;
extern uint8_t usbh_xc8_hid_epin_size;
extern uint8_t usbh_xc8_hid_ep_mps_lo;
extern uint8_t usbh_xc8_hid_ep_mps_hi;
extern uint8_t usbh_xc8_hid_epin_after;
extern uint8_t usbh_xc8_hid_ep_in_after;
extern uint8_t usbh_xc8_hid_clear_calls;
#endif /* IOC_DIAGNOSTIC_BUILD */
static uint8_t rpt_cb_calls;   /* unguarded count of tuh_hid_report_received_cb */
static uint8_t rpt_daddr = 0xffu;
static uint8_t rpt_inst  = 0xffu;
static uint8_t rpt_last_len = 0xffu;   /* len of the most recent completion */
static uint8_t rpt_zero_len;           /* completions that carried no data */

#if IOC_DIAGNOSTIC_BUILD
/* Active MAX3421E probes and the HIDSTATUS detail-page accessors.
 *
 * The probes write controller registers and change SPI speed, so they can
 * never be part of a passive status: reading the health of the link must not
 * be able to change it.  The accessors exist only to format detail pages 1-5,
 * which are themselves diagnostic-build only. */
void hid_host_cfg_debug(HidHostCfg *c)
{
    c->open_calls    = usbh_xc8_hid_open_calls;
    c->setcfg_calls  = usbh_xc8_hid_setcfg_calls;
    c->proc_calls    = usbh_xc8_hid_proc_calls;
    c->state         = usbh_xc8_hid_state;
    c->itf_num       = usbh_xc8_hid_itfnum;
    c->breq          = usbh_xc8_hid_breq;
    c->result        = usbh_xc8_hid_result;
    c->mount_calls   = usbh_xc8_hid_mount_calls;
    c->mountcb_calls = usbh_xc8_mountcb_calls;
    c->hid_mounts    = hid_mount_calls;
    c->hid_daddr     = hid_mount_daddr;
    c->hid_inst      = hid_mount_inst;
    c->hid_proto     = hid_mount_proto;
    c->hid_arm       = hid_arm_ok;

    /* The keyboard sits at address 1 with an interrupt-IN endpoint.  Its
     * ep2drv entry has never been checked -- only the hub's at address 3 -- and
     * an unbound endpoint there discards every report exactly the way the hub's
     * status completions were discarded before level 49. */
    c->kbd_ep_state = usbh_xc8_get_ep_state(1u, 1u, 1u);
    c->kbd_ep_pkt   = usbh_xc8_get_ep_pktsize(1u, 1u, 1u);
    c->kbd_ep2drv   = usbh_xc8_get_ep2drv(1u, 1u, 1u);
    c->busy_lock    = usbh_xc8_get_busy_lock();
    /* Actual retained hidh_interface_t field after hidh_open(), not the
     * descriptor-side capture.  The latter hid a damaged p_hid through level
     * 60 because the write and immediate readback used the same wrong object. */
    c->hid_ep_in     = usbh_xc8_hid_ep_in_after;
    c->kbd_submits   = usbh_xc8_kbd_submits;
    c->hid_xfercb    = usbh_xc8_hid_xfercb;
    c->hid_xfercb_ep = usbh_xc8_hid_xfercb_ep;
    c->rpt_cb_calls  = rpt_cb_calls;
    /* Raw wMaxPacketSize bytes as hidh_open() read them, so a bad read is
     * visible rather than inferred.  Expect 08 00 for a boot keyboard. */
    c->rpt_daddr     = input_put_total;   /* bytes pushed into the queue */
    c->hid_xfercb_ep = usbh_xc8_hid_epin_after;  /* epin_size right after the write */
    c->rpt_inst      = input_get_total;   /* bytes pulled out of the queue */
}

void hid_host_enum_debug(HidHostEnum *e)
{
    e->calls    = usbh_xc8_hubenum_calls;
    e->hub_addr = usbh_xc8_hubenum_addr;
    e->hub_port = usbh_xc8_hubenum_port;
    e->ret          = usbh_xc8_hubenum_ret;
    e->enumerating  = usbh_xc8_get_enumerating();
    e->defers       = usbh_xc8_defer_count;
    e->completes    = usbh_xc8_enum_complete;
    e->att_hub_addr = usbh_xc8_att_hub_addr;
    e->att_hub_port = usbh_xc8_att_hub_port;

    /* The hub sits at address 3 (CFG_TUH_DEVICE_MAX + 1) and its status change
     * endpoint is interrupt-IN 1. */
    e->busy_lock  = usbh_xc8_get_busy_lock();
    e->ep_state   = usbh_xc8_get_ep_state(3u, 1u, 1u);
    e->ep_pktsize = usbh_xc8_get_ep_pktsize(3u, 1u, 1u);

    e->hub_cb_calls  = usbh_xc8_hub_cb_calls;
    e->hub_arm_calls = usbh_xc8_hub_arm_calls;
    e->hub_change    = usbh_xc8_hub_status_change;
    e->ep_alloc_fail = usbh_xc8_ep_alloc_fail;
    e->ep_used       = usbh_xc8_get_ep_used();
    e->ep_total      = usbh_xc8_get_ep_total();
    e->ep2drv        = usbh_xc8_get_ep2drv(3u, 1u, 1u);
    e->bind_calls    = usbh_xc8_bind_calls;
    e->bind_drvid    = usbh_xc8_bind_drvid;
    e->bind_drvlen   = usbh_xc8_bind_drvlen;
    e->itf_clobbered = usbh_xc8_itf_clobbered;
    e->ep2drv_out    = usbh_xc8_get_ep2drv(3u, 1u, 0u);
}

void hid_host_xfer_debug(HidHostXfer *x)
{
    uint8_t i;

    x->hxfr        = usbh_xc8_d_hxfr;
    x->ep_dir      = usbh_xc8_d_epdir;
    x->peraddr     = usbh_xc8_d_peraddr;
    x->ep_num      = usbh_xc8_d_epnum;
    x->packet_size = usbh_xc8_d_pktsize;
    x->total_len   = usbh_xc8_d_total;
    x->xferred_len = usbh_xc8_d_xferred;
    x->ep_state    = usbh_xc8_d_epstate;
    x->xact_len    = usbh_xc8_d_xactlen;
    x->branch      = usbh_xc8_d_branch;
    x->hub_open_ep = xc8_saved_hub_ep;
    x->hub_status_ep_before = usbh_xc8_hub_status_ep_before;
    x->hub_state_after_open = usbh_xc8_hub_state_after_open;
    x->submit_daddr = usbh_xc8_submit_daddr;
    x->submit_ep    = usbh_xc8_submit_ep;
    for (i = 0u; i < 8u; ++i) {
        x->setup[i] = usbh_xc8_last_setup[i];
    }
}

void hid_host_hub_debug(HidHostHubTrace *trace)
{
    uint8_t i;

    for (i = 0u; i < HID_HOST_HUB_TRACE_LEN; ++i) {
        trace->bytes[i] = usbh_xc8_hub_trace[i];
    }
}

void hid_host_debug(HidHostDebug *dbg)
{
    bool saved_spi_failed = spi_failed;

    dbg->enum_state   = usbh_xc8_enum_state;
    dbg->enum_fails   = usbh_xc8_enum_fails;
    dbg->ctrl_rejects = usbh_xc8_ctrl_rejects;
    dbg->hxfrdn       = usbh_xc8_hxfrdn;
    dbg->xferdone     = usbh_xc8_xferdone;
    dbg->epnull       = usbh_xc8_epnull;
    dbg->last_hrsl    = usbh_xc8_lasthrsl;

    /* Two counters in one byte: only one payload slot is left (the transport
     * caps a reply at IOC_COMMAND_MAX_DATA = 26) and both of these are single
     * digits here.  High nibble = transfers started, low = completions
     * reported to the host stack. */
    dbg->setups_xfers = (uint8_t)((usbh_xc8_setups << 4) | (ev_xfer & 0x0fu));

    dbg->task_calls     = usb_task_calls;
    dbg->int_dispatches = usb_int_dispatches;
    dbg->device_count   = usb_device_count;
    dbg->int_level      = USB_INT_PORT ? 1u : 0u;

    if (controller_status != HID_HOST_CONTROLLER_READY) {
        dbg->port_connected = 0u;
        dbg->port_speed     = 0xffu;
        dbg->hirq  = 0u;
        dbg->mode  = 0u;
        dbg->hrsl  = 0u;
        dbg->usbirq = 0u;
        dbg->mounted_map = 0u;
        dbg->ev_attach = ev_attach;
        dbg->ev_remove = ev_remove;
        dbg->enum_dev_desc = enum_dev_desc;
        dbg->enum_cfg_desc = enum_cfg_desc;
        return;
    }

    /* hcd_port_connect_status() is the driver's own "is anything attached"
     * answer: it reports MODE.SOFKAENAB, which the CONDET handler sets when it
     * sees a connection and nothing else ever sets. */
    /* Which addresses the stack has actually enumerated.
     *
     * device_count cannot answer this: usbh.c only calls tuh_mount_cb() for
     * non-hub devices (see the is_hub_addr() branch at the end of its
     * enumeration), so a fully working hub leaves that counter at zero.  Hub
     * addresses start above CFG_TUH_DEVICE_MAX, so with DEVICE_MAX = 2 the hub
     * is address 3 and bit 2 of this map is the hub's own mount state. */
    {
        uint8_t daddr;

        dbg->mounted_map = 0u;
        for (daddr = 1u; daddr <= (CFG_TUH_DEVICE_MAX + CFG_TUH_HUB); daddr++) {
            if (tuh_mounted(daddr))
                dbg->mounted_map |= (uint8_t)(1u << (daddr - 1u));
        }
    }

    dbg->ev_attach     = ev_attach;
    dbg->ev_remove     = ev_remove;
    dbg->enum_dev_desc = enum_dev_desc;
    dbg->enum_cfg_desc = enum_cfg_desc;

    dbg->port_connected = hcd_port_connect_status(0u) ? 1u : 0u;
    dbg->port_speed     = (uint8_t)hcd_port_speed_get(0u);

    /* Read straight from the part.  These are all plain reads -- HIRQ is
     * write-one-to-clear, so sampling it disturbs nothing. */
    (void)reg_read_at(HID_SPI_BAUD, MAX3421_HIRQ_READ,   &dbg->hirq);
    (void)reg_read_at(HID_SPI_BAUD, MAX3421_MODE_READ,   &dbg->mode);
    (void)reg_read_at(HID_SPI_BAUD, MAX3421_HRSL_READ,   &dbg->hrsl);
    (void)reg_read_at(HID_SPI_BAUD, MAX3421_USBIRQ_READ, &dbg->usbirq);

    spi_failed = saved_spi_failed;
}
#endif /* IOC_DIAGNOSTIC_BUILD */

void hid_host_usb_state(HidHostUsbState *state)
{
    uint8_t i;

    state->device_count  = usb_device_count;
    state->keyboard_addr = keyboard_addr;
    state->report_count  = keyboard_reports;
    state->speed         = keyboard_speed;

    for (i = 0u; i < 8u; i++)
        state->last_report[i] = keyboard_last[i];
}

void hid_host_gamepad_state(HidHostGamepadState *state)
{
    uint8_t daddr;
    uint8_t slot;

    /* Do not infer enumeration from tuh_mount_cb().  On this XC8 build the
     * HID class callback and reports can be active even when that optional
     * generic callback was not dispatched.  Addresses through
     * CFG_TUH_DEVICE_MAX are TinyUSB's non-hub slots; hub addresses follow
     * them.  Read the configured-device table directly so this status page
     * describes the host's live state. */
    state->device_count      = 0u;
    state->last_device_addr  = 0xffu;
    state->last_device_vid   = 0xffffu;
    state->last_device_pid   = 0xffffu;
    for (daddr = 1u; daddr <= CFG_TUH_DEVICE_MAX; daddr++) {
        if (tuh_mounted(daddr)) {
            state->device_count++;
            state->last_device_addr = daddr;
        }
    }
    if (state->last_device_addr != 0xffu)
        (void)tuh_vid_pid_get(state->last_device_addr,
                              &state->last_device_vid,
                              &state->last_device_pid);

    state->mount_count       = usb_mount_count;
    state->unmount_count     = usb_unmount_count;
    state->hid_mount_count   = hid_mount_calls;
    state->last_hid_addr     = hid_mount_daddr;
    state->last_hid_protocol = hid_mount_proto;

    for (slot = 0u; slot < CONTROLLER_LATCH_PORTS; slot++) {
        state->gamepad_addr[slot]      = gamepad_addr[slot];
        state->gamepad_instance[slot]  = gamepad_instance[slot];
        state->gamepad_first_arm[slot] = gamepad_first_arm[slot];
        state->gamepad_reports[slot]   = gamepad_reports[slot];
        state->gamepad_last_len[slot]  = gamepad_last_len[slot];
        state->gamepad_latch[slot]     = controller_latch_value(slot);
    }
}

HidHostStatus hid_host_status(void)
{
    return controller_status;
}

uint8_t hid_host_revision(void)
{
    return controller_revision;
}

uint8_t hid_host_interrupt_level(void)
{
    return USB_INT_PORT ? 1u : 0u;
}

#if IOC_DIAGNOSTIC_BUILD
/* Active MAX3421E probes and the HIDSTATUS detail-page accessors.
 *
 * The probes write controller registers and change SPI speed, so they can
 * never be part of a passive status: reading the health of the link must not
 * be able to change it.  The accessors exist only to format detail pages 1-5,
 * which are themselves diagnostic-build only. */
/* Read REVISION HID_PROBE_READS times and report a majority verdict.
 *
 * Reporting the last of 64 reads, as this used to, throws away exactly the
 * information a marginal link has to give.  One sample cannot distinguish a
 * dead bus from a bus that is right 95% of the time, and both have now been
 * observed on this board within a minute of each other.
 *
 * So count instead: tally the three legal revision codes, return whichever won
 * and how many of the 64 reads produced it.  That turns "flaky" into a number
 * you can watch while reworking a joint -- 61/64 improving to 64/64 is
 * progress you can see, where a single sample is a coin toss.
 *
 * Majority also identifies the part correctly when noise happens to forge a
 * legal-looking code: 0x01 is both a valid revision and a plausible corruption
 * of 0x13, and only the counts tell them apart. */
static uint8_t probe_revision_burst(uint8_t baud, uint8_t *match_count)
{
    uint8_t i;
    uint8_t last = 0u;
    uint8_t n_rev1 = 0u, n_rev2 = 0u, n_rev3 = 0u;

    /* Re-assert full duplex at this rate before reading.  Harmless if the
     * controller is already configured -- the value written is the same one
     * hcd_init() writes, because _tuh_cfg.pinctl is left at 0 -- and it keeps
     * the probe usable on a part that has been power-cycled underneath us.
     * RES is strapped high on this board, so a power cycle of the mezzanine
     * 3V3 rail is the only thing that puts PINCTL back to half duplex. */
    if (!select_full_duplex(baud)) {
        *match_count = 0u;
        return 0u;
    }

    for (i = 0u; i < HID_PROBE_READS; i++) {
        last = read_revision_at(baud);

        if (last == MAX3421_REVISION_3)      n_rev3++;
        else if (last == MAX3421_REVISION_2) n_rev2++;
        else if (last == MAX3421_REVISION_1) n_rev1++;
    }

    if (n_rev3 != 0u && n_rev3 >= n_rev2 && n_rev3 >= n_rev1) {
        *match_count = n_rev3;
        return MAX3421_REVISION_3;
    }
    if (n_rev2 != 0u && n_rev2 >= n_rev1) {
        *match_count = n_rev2;
        return MAX3421_REVISION_2;
    }
    if (n_rev1 != 0u) {
        *match_count = n_rev1;
        return MAX3421_REVISION_1;
    }

    /* Nothing legal in 64 tries.  Hand back the last raw byte, which is the
     * only thing left that says anything about what the bus is doing. */
    *match_count = 0u;
    return last;
}

void hid_host_probe(HidHostProbe *probe)
{
    /* The header promises this call leaves the boot result alone.  The two
     * helpers below report their own failures through the values they return,
     * so the shared flag is restored rather than left carrying a fault that
     * belongs to a diagnostic rather than to start-up. */
    bool saved_spi_failed = spi_failed;

    probe->revision_125khz = probe_revision_burst(SPI1_BAUD_125KHZ,
                                                  &probe->matches_125khz);
    probe->gpout_125khz    = gpout_loopback_at(SPI1_BAUD_125KHZ);

    probe->revision_1mhz   = probe_revision_burst(SPI1_BAUD_1MHZ,
                                                 &probe->matches_1mhz);
    probe->gpout_1mhz      = gpout_loopback_at(SPI1_BAUD_1MHZ);

    probe->revision_4mhz   = probe_revision_burst(SPI1_BAUD_4MHZ,
                                                 &probe->matches_4mhz);
    probe->gpout_4mhz      = gpout_loopback_at(SPI1_BAUD_4MHZ);

    /* Run at the slowest rate: this one is asking whether the part hears us at
     * all, so it should not be able to fail for a timing reason. */
    probe->int_drive       = int_drive_test(SPI1_BAUD_125KHZ);

    spi_failed = saved_spi_failed;
}
#endif /* IOC_DIAGNOSTIC_BUILD */

void tuh_event_hook_cb(uint8_t rhport, uint32_t eventid, bool in_isr)
{
    (void)rhport;
    (void)in_isr;

    if (eventid == (uint32_t)HCD_EVENT_DEVICE_ATTACH)
        bump(&ev_attach);
    else if (eventid == (uint32_t)HCD_EVENT_DEVICE_REMOVE)
        bump(&ev_remove);
    else if (eventid == (uint32_t)HCD_EVENT_XFER_COMPLETE && ev_xfer < 0x0fu)
        ev_xfer++;
}

void tuh_enum_descriptor_device_cb(uint8_t daddr,
                                   const tusb_desc_device_t *desc_device)
{
    (void)daddr;
    (void)desc_device;
    bump(&enum_dev_desc);
}

bool tuh_enum_descriptor_configuration_cb(uint8_t daddr, uint8_t cfg_index,
                                          const tusb_desc_configuration_t *desc_config)
{
    (void)daddr;
    (void)cfg_index;
    (void)desc_config;
    bump(&enum_cfg_desc);
    return true;
}

/* TinyUSB MAX3421E platform callbacks.  Chip select always goes through the
 * central SPI1 selector, which deasserts the SD card and controller latch
 * before selecting USB. */
void tuh_max3421_spi_cs_api(uint8_t rhport, bool active)
{
    (void)rhport;

    if (active) {
        spi1_bus_configure(HID_SPI_BAUD, SPI1_MSB_FIRST);
        spi1_bus_select(SPI1_DEVICE_USB);
    } else {
        spi1_bus_select(SPI1_DEVICE_NONE);
    }
}

bool tuh_max3421_spi_xfer_api(uint8_t rhport, uint8_t const *tx_buf,
                              uint8_t *rx_buf, size_t xfer_bytes)
{
    size_t i;

    (void)rhport;

    for (i = 0u; i < xfer_bytes; i++) {
        uint8_t received;
        uint8_t outgoing = (tx_buf != NULL) ? tx_buf[i] : 0u;

        if (!spi1_bus_transfer(outgoing, &received)) {
            spi_failed = true;
            return false;
        }

        if (rx_buf != NULL)
            rx_buf[i] = received;
    }

    return true;
}

void tuh_max3421_int_api(uint8_t rhport, bool enabled)
{
    (void)rhport;
    (void)enabled;
}

/* Supply the delay directly instead of letting TinyUSB derive it from millis().
 *
 * The default implementation in tusb.c busy-waits as
 *
 *     t0 = millis(); while (millis() - t0 < ms) {}
 *
 * which is only as good as the clock's granularity.  Ours ticks every 10 ms, so
 * t0 is always a tick boundary and a requested 10 ms can elapse on the very
 * next tick -- possibly 100 us later.  USB requires 10 ms of reset recovery
 * before a device will answer, so honouring that as ~0 ms means addressing a
 * device that is not listening yet, which comes back as HRSL_TIMEOUT and looks
 * exactly like absent hardware.
 *
 * Round up to whole ticks and add one more, so the wait can only ever be too
 * long (by under 20 ms) and never too short.  Enumeration delays are not on any
 * hot path; being generous costs nothing and being short costs enumeration.
 *
 * NOTE: this blocks.  ENUM_DEBOUNCING_DELAY_MS is 150 ms, so a tuh_task() pass
 * that is enumerating can hold the main loop for that long.  That is survivable
 * only because /SIO1B_INT is a level the Z80 holds until acknowledged, so a
 * request arriving inside the window is delayed rather than lost -- the same
 * property the SD cache flush relies on. */
void tusb_time_delay_ms_api(uint32_t ms)
{
    uint16_t start  = timebase_ticks();
    uint16_t needed = (uint16_t)((ms + (uint32_t)TIMEBASE_TICK_MS - 1u) /
                                 (uint32_t)TIMEBASE_TICK_MS) + 1u;

    while ((uint16_t)(timebase_ticks() - start) < needed)
        timebase_poll();
}

uint32_t tusb_time_millis_api(void)
{
    uint16_t now;

    /* TinyUSB's later enumeration delays call this function in a tight loop.
     * Poll through the timebase's single flag-owning routine so time continues
     * to advance inside those delays without enabling interrupts. */
    timebase_poll();
    now = timebase_ticks();
    usb_time_ms += (uint32_t)(uint16_t)(now - last_timebase_tick) *
                   (uint32_t)TIMEBASE_TICK_MS;
    last_timebase_tick = now;
    return usb_time_ms;
}

/* XC8 does not implement TinyUSB's weak override model reliably, so the port
 * supplies explicit no-op callbacks until the enumeration/report phases add
 * behavior. */
usbh_class_driver_t const *usbh_app_driver_get_cb(uint8_t *driver_count)
{
    *driver_count = 0u;
    return NULL;
}

void tuh_mount_cb(uint8_t dev_addr)
{
    if (usb_device_count != 0xffu)
        usb_device_count++;
    if (usb_mount_count != 0xffu)
        usb_mount_count++;

    usb_last_device_addr = dev_addr;
    usb_last_device_vid  = 0xffffu;
    usb_last_device_pid  = 0xffffu;
    (void)tuh_vid_pid_get(dev_addr, &usb_last_device_vid,
                          &usb_last_device_pid);
}

void tuh_umount_cb(uint8_t dev_addr)
{
    if (usb_device_count != 0u)
        usb_device_count--;
    if (usb_unmount_count != 0xffu)
        usb_unmount_count++;

    gamepad_unmount(dev_addr, 0u, false);

    if (dev_addr == keyboard_addr) {
        keyboard_addr    = 0u;
        keyboard_reports = 0u;
        keyboard_speed   = 0xffu;
        repeat_key       = 0u;
        led_dirty        = false;
    }
}

void tuh_hid_mount_cb(uint8_t dev_addr, uint8_t instance,
                      uint8_t const *report_desc, uint16_t desc_len)
{
    uint8_t i;
    uint8_t slot;

    (void)report_desc;
    (void)desc_len;

    if (hid_mount_calls != 0xffu)
        hid_mount_calls++;
    hid_mount_daddr = dev_addr;
    hid_mount_inst  = instance;
    hid_mount_proto = tuh_hid_interface_protocol(dev_addr, instance);
    hid_mount_vid   = 0xffffu;
    hid_mount_pid   = 0xffffu;

    /* Bind F310 DirectInput interfaces before the deliberately permissive
     * keyboard fallback below can mistake their 8-byte reports for boot-key
     * reports.  Mount order assigns controller 1, then controller 2. */
    if (tuh_vid_pid_get(dev_addr, &hid_mount_vid, &hid_mount_pid) &&
        hid_mount_vid == F310_VID &&
        hid_mount_pid == F310_DIRECTINPUT_PID) {
        slot = gamepad_slot_for(dev_addr, instance);
        if (slot == GAMEPAD_SLOT_NONE) {
            for (slot = 0u; slot < CONTROLLER_LATCH_PORTS; slot++) {
                if (gamepad_addr[slot] == 0u)
                    break;
            }
        }

        if (slot < CONTROLLER_LATCH_PORTS) {
            gamepad_addr[slot]           = dev_addr;
            gamepad_instance[slot]       = instance;
            gamepad_next_poll_ms[slot]   = 0uL;
            gamepad_report_pending[slot] =
                tuh_hid_receive_report(dev_addr, instance);
            hid_arm_ok = gamepad_report_pending[slot] ? 1u : 0u;
            gamepad_first_arm[slot] = hid_arm_ok;
            gamepad_reports[slot]   = 0u;
            gamepad_last_len[slot]  = 0u;
        }
        return;
    }

    /* Deliberately permissive.  bInterfaceProtocol is only meaningful when the
     * interface declares the boot subclass, and plenty of keyboards report 0
     * here while still being perfectly good boot-protocol keyboards -- so
     * filtering on it silently discards working hardware, which is exactly what
     * was observed.  TinyUSB has already put the interface into boot protocol
     * during set_config (_hidh_default_protocol is HID_PROTOCOL_BOOT), so the
     * reports arriving below are the fixed 8-byte layout regardless.
     *
     * The protocol byte is still recorded above, so what the device actually
     * claims stays visible rather than being assumed. */
    if (hid_mount_proto == HID_ITF_PROTOCOL_MOUSE)
        return;   /* a mouse's 8 bytes are not a keyboard report */

    keyboard_addr     = dev_addr;
    keyboard_instance = instance;
    keyboard_reports  = 0u;
    caps_lock         = 0u;
    num_lock          = 1u;
    repeat_key        = 0u;
    /* Push the LEDs unconditionally rather than via led_refresh(): a freshly
     * enumerated keyboard has all LEDs dark, so the state we want and the
     * state it is in agree numerically while disagreeing physically. */
    led_report        = HID_LED_NUM_LOCK;
    led_dirty         = true;
    for (i = 0u; i < 8u; i++)
        keyboard_last[i] = 0u;

    /* Record the speed, because on this board it predicts whether the device
     * can work at all.  There is an FE1.1S hub between the MAX3421E and every
     * port, and TinyUSB's MAX3421E driver has no PRE-packet support: MODE_HUBPRE
     * is declared in its register enum and never written anywhere in the tree,
     * and MODE_LOWSPEED is only ever set from ROOT port detection, never
     * switched per device.  A full-speed device behind the hub is fine; a
     * low-speed one cannot be reached without patching the driver to set both
     * bits per transfer.  Reporting the speed turns that from a silent failure
     * into a diagnosis. */
    keyboard_speed = (uint8_t)tuh_speed_get(dev_addr);

    /* Nothing arrives until the first request is posted, and every report
     * consumes the one before it, so this has to be re-armed on each delivery
     * as well.  Forgetting either half yields exactly one report, or none. */
    hid_arm_ok = tuh_hid_receive_report(dev_addr, instance) ? 1u : 0u;
}

void tuh_hid_umount_cb(uint8_t dev_addr, uint8_t instance)
{
    gamepad_unmount(dev_addr, instance, true);

    if (dev_addr == keyboard_addr && instance == keyboard_instance) {
        keyboard_addr    = 0u;
        keyboard_reports = 0u;
        keyboard_speed   = 0xffu;
        repeat_key       = 0u;
        led_dirty        = false;
    }
}

/* CTRL-ALT-ESC: reset the machine.
 *
 * The IOC drives the host reset lines, so it is the only part of the system
 * that can restart a wedged Z80 without reaching for the power switch.  This
 * gives that a keyboard shortcut.
 *
 * Either Ctrl and either Alt, matching how translate_key() already treats the
 * left/right pairs as equivalent.  Other modifiers are ignored rather than
 * forbidden: a stray Shift should not be the reason a deliberate reset does
 * nothing.  Escape is looked for anywhere in the keycode array because the
 * boot report lists concurrent keys in press order, not a fixed slot.
 *
 * The combination is checked against the raw report before translate_key()
 * runs, so the Escape never reaches the input queue.
 */
static volatile bool reset_combo_seen;

bool hid_reset_requested(void)
{
    return reset_combo_seen;
}

static bool keyboard_reset_combo(uint8_t const *report, uint8_t copy)
{
    uint8_t i;

    if ((report[0] & (KEYBOARD_MODIFIER_LEFTCTRL |
                      KEYBOARD_MODIFIER_RIGHTCTRL)) == 0u)
        return false;
    if ((report[0] & (KEYBOARD_MODIFIER_LEFTALT |
                      KEYBOARD_MODIFIER_RIGHTALT)) == 0u)
        return false;

    for (i = 2u; i < copy; i++) {
        if (report[i] == HID_KEY_ESCAPE)
            return true;
    }
    return false;
}

void tuh_hid_report_received_cb(uint8_t dev_addr, uint8_t instance,
                                uint8_t const *report, uint16_t len)
{
    uint8_t i;
    uint8_t pressed;
    uint8_t copy = (len < 8u) ? (uint8_t)len : 8u;
    uint8_t gamepad_slot = gamepad_slot_for(dev_addr, instance);

    /* Counted before the guard, so "the callback never ran" and "the callback
     * ran and the guard rejected it" cannot be confused. */
    if (rpt_cb_calls != 0xffu)
        rpt_cb_calls++;
    rpt_daddr = dev_addr;
    rpt_inst  = instance;
    rpt_last_len = (uint8_t)len;
    if (len == 0u && rpt_zero_len != 0xffu)
        rpt_zero_len++;

    if (gamepad_slot != GAMEPAD_SLOT_NONE) {
        gamepad_report_pending[gamepad_slot] = false;
        if (gamepad_reports[gamepad_slot] != 0xffffu)
            gamepad_reports[gamepad_slot]++;
        gamepad_last_len[gamepad_slot] =
            (len > 0xffu) ? 0xffu : (uint8_t)len;
        (void)controller_latch_f310_report(gamepad_slot, report, len);
        gamepad_next_poll_ms[gamepad_slot] =
            tusb_time_millis_api() + GAMEPAD_POLL_MS;
    } else if (dev_addr == keyboard_addr && instance == keyboard_instance) {
        /* Latched here, acted on by the main loop.
         *
         * Deliberately NOT a direct call to handler_reset() from inside a USB
         * host callback.  That would make handlers.c and ioc_hid.c call each
         * other -- handler_hid_input() already calls into this file -- and a
         * cycle changes how XC8 overlays statics across BOTH modules.  On this
         * project that class of change has silently corrupted unrelated code
         * before, and the compiler already reports the call graph as recursive
         * with the data stack at 100%.  A flag keeps the graph acyclic and
         * costs nothing.
         *
         * Latching also means the reset happens between commands rather than
         * mid-enumeration, which is where every other terminal action in this
         * firmware is taken. */
        if (keyboard_reset_combo(report, copy)) {
            reset_combo_seen = true;
            return;                     /* no Escape into the input queue */
        }

        /* Only newly pressed usages produce terminal input.  USB boot reports
         * repeat unchanged held keys; host-side repeat policy can be added
         * later without duplicating bytes at the poll interval today. */
        pressed = 0u;
        for (i = 2u; i < copy; i++) {
            uint8_t keycode = report[i];
            /* 01h-03h are the boot-protocol rollover/error usages. */
            if (keycode > 3u && !key_was_down(keycode)) {
                translate_key(keycode, report[0]);
                /* The lock keys toggle state; repeating them would flap it. */
                if (keycode != HID_KEY_CAPS_LOCK &&
                    keycode != HID_KEY_NUM_LOCK &&
                    keycode != HID_KEY_SCROLL_LOCK)
                    pressed = keycode;
            }
        }

        for (i = 0u; i < copy; i++)
            keyboard_last[i] = report[i];
        for (; i < 8u; i++)
            keyboard_last[i] = 0u;

        /* keyboard_last now holds the CURRENT report, so key_was_down() reads
         * here as "is still held".  A newly pressed key takes over the repeat
         * and restarts the initial delay; otherwise the existing one continues
         * only while it is still down.  Modifiers are re-sampled each report so
         * shifting mid-repeat changes what repeats. */
        if (pressed != 0u) {
            repeat_key    = pressed;
            repeat_mod    = report[0];
            repeat_due_ms = tusb_time_millis_api() + REPEAT_DELAY_MS;
        } else if (repeat_key != 0u && !key_was_down(repeat_key)) {
            repeat_key = 0u;
        } else if (repeat_key != 0u) {
            repeat_mod = report[0];
        }

        keyboard_reports++;
    }

    /* F310 reports are re-armed by hid_host_task() at the 10 ms deadline.
     * Everything else remains continuously armed as before; an ignored
     * interface that is not re-armed is never polled again and looks unplugged. */
    if (gamepad_slot == GAMEPAD_SLOT_NONE)
        (void)tuh_hid_receive_report(dev_addr, instance);
}

void tuh_hid_report_sent_cb(uint8_t dev_addr, uint8_t instance,
                            uint8_t const *report, uint16_t len)
{
    (void)dev_addr;
    (void)instance;
    (void)report;
    (void)len;
}

void tuh_hid_get_report_complete_cb(uint8_t dev_addr, uint8_t instance,
                                    uint8_t report_id, uint8_t report_type,
                                    uint16_t len)
{
    (void)dev_addr;
    (void)instance;
    (void)report_id;
    (void)report_type;
    (void)len;
}

void tuh_hid_set_report_complete_cb(uint8_t dev_addr, uint8_t instance,
                                    uint8_t report_id, uint8_t report_type,
                                    uint16_t len)
{
    (void)dev_addr;
    (void)instance;
    (void)report_id;
    (void)report_type;
    (void)len;
}

void tuh_hid_set_protocol_complete_cb(uint8_t dev_addr, uint8_t instance,
                                      uint8_t protocol)
{
    (void)dev_addr;
    (void)instance;
    (void)protocol;
}
