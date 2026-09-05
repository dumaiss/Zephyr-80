#!/bin/sh
# Fail the build if the TinyUSB XC8 patch set is missing or has drifted.
#
# The patches are one commit on a fork branch, not scattered edits, so their
# presence is checkable.  Losing one during a vendor refresh does not break the
# build -- it breaks enumeration, intermittently, on hardware.  Converting that
# into a build error is the whole point of this script.
#
# It deliberately checks the CORRECTNESS storage only.  Seven of those live
# under the same usbh_xc8_* prefix as 68 trace variables, so a cleanup aimed at
# "the usbh_xc8_ family" can take them out silently.  See docs/XC8-PATCHES.md.
set -eu

TUSB=${1:-third_party/tinyusb}

if [ ! -d "$TUSB/src" ]; then
    echo "check_xc8_patches: $TUSB not present (submodule not initialised?)" >&2
    exit 1
fi

fail=0
check() {
    # $1 = file, $2 = symbol/marker, $3 = what it protects
    if ! grep -q -- "$2" "$TUSB/$1" 2>/dev/null; then
        echo "  MISSING: $2" >&2
        echo "           in $1 -- $3" >&2
        fail=1
    fi
}

# Correctness storage: each written before a nested call XC8's static-auto
# overlay would clobber, and read straight back into live state after it.
check src/host/usbh.c          _xc8_queue_event        "event copied before the nested FIFO call"
check src/host/usbh.c          usbh_xc8_itf_save       "desc_itf preserved across driver->open()"
check src/host/hub.c           usbh_xc8_hub_open_ep    "hub endpoint address preserved across tuh_edpt_open()"
check src/host/hub.c           usbh_xc8_hub_open_daddr "hub device address preserved across tuh_edpt_open()"
check src/class/hid/hid_host.c usbh_xc8_hid_open_itf   "HID object pointer preserved across endpoint open"
check src/class/hid/hid_host.c usbh_xc8_hid_ep_addr    "HID endpoint address preserved across endpoint open"
check src/class/hid/hid_host.c usbh_xc8_hid_ep_mps     "HID packet size and boot-report fallback"
check src/class/hid/hid_host.c usbh_xc8_hid_next_desc  "next descriptor pointer preserved across endpoint open"

# Structural workarounds that are not variables.
check src/common/tusb_fifo.h   "defined(__XC8)"        "FIFO bit-fields replaced: XC8 rejects >8-bit bit-field bases"
check src/tusb.c               "defined(__XC8)"        "weak tusb_time_delay_ms_api compiled out; the port supplies it"

if [ "$fail" -ne 0 ]; then
    echo "check_xc8_patches: ERROR - XC8 correctness patches are missing." >&2
    echo "  A refresh that drops these still BUILDS; it fails on hardware," >&2
    echo "  intermittently, during enumeration.  See docs/XC8-PATCHES.md." >&2
    exit 1
fi

echo "check_xc8_patches: OK (10 correctness workarounds present)"
