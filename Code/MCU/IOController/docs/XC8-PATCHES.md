# TinyUSB XC8 patch set

Status: extracted, documented, and the seven correctness stores renamed off
the `usbh_xc8_*` prefix. No patch has been removed.

This is the audit the debug/test review asked for before any `usbh_xc8_*`
variable is deleted: a record of which changes to the vendored TinyUSB tree are
**correctness workarounds for the XC8 compiler** and which are bring-up
instrumentation that can go.

Losing a compiler workaround during a vendor refresh reintroduces intermittent
enumeration failures that are much harder to rediscover than to document. That
is the whole reason this file exists.

## Provenance — better than the review assumed

The review expected "scattered edits inside `third_party/tinyusb`". They are
not scattered. The patch set is already isolated:

| | |
|---|---|
| Vendored as | a git **submodule**, not a copy |
| Fork | `https://github.com/dumaiss/tinyusb.git` |
| Branch | `zephyr80-xc8-max3421` (pushed to the fork) |
| Upstream base | `hathach/tinyusb` tag **0.20.0** |
| The patch | **one commit**, `55b0d86f9` "Support XC8 PIC18 MAX3421E host with hub and HID" |
| Working tree | clean — no uncommitted local modifications |

So the complete patch set is recoverable at any time with:

```sh
git -C third_party/tinyusb diff 3af1bec1a 55b0d86f9
```

687 insertions across 8 files, 63 hunks. A refresh is a rebase of one commit
onto a newer tag, not a re-derivation.

## The naming trap — found, and fixed by renaming

**Seven symbols were named `usbh_xc8_*` but are live state, not telemetry.**

Each is written immediately before a nested call that XC8's static-auto overlay
would clobber, and read straight back into a real structure field afterwards.
They carried the same prefix as the 68 trace variables, so anything that removed
"the `usbh_xc8_*` family" would have deleted them too — and the failure is
silent enumeration breakage, not a build error.

They are now named **`xc8_saved_*`**. That is the actual fix: the prefix no
longer collides with the trace family, so the mistake is no longer available to
make. Everything still called `usbh_xc8_*` is telemetry.

| Symbol | File | Preserved across | Restored into |
|---|---|---|---|
| `xc8_saved_itf` | `host/usbh.c` | `driver->open()` | `desc_itf` (compared, then repaired) |
| `xc8_saved_hub_ep` | `host/hub.c` | `tuh_edpt_open()` | `p_hub->ep_in` |
| `xc8_saved_hub_daddr` | `host/hub.c` | `tuh_edpt_open()` | `dev_addr` |
| `xc8_saved_hid_itf` | `class/hid/hid_host.c` | nested endpoint open | `p_hid` |
| `xc8_saved_hid_ep_addr` | `class/hid/hid_host.c` | nested endpoint open | `p_hid->ep_in` |
| `xc8_saved_hid_ep_mps` | `class/hid/hid_host.c` | nested endpoint open | `p_hid->epin_size` / `epout_size`, incl. the boot-protocol fallback |
| `xc8_saved_hid_next_desc` | `class/hid/hid_host.c` | nested endpoint open | `p_desc` |

A useful discriminator, and the one used to build this table: **correctness
storage is read back inside TinyUSB; telemetry is only written there** and read
by the IOController's `HIDSTATUS` handler. Anything whose only reader is outside
the submodule is a trace.

`_xc8_queue_event` in `host/usbh.c` is the eighth piece of correctness storage
and is already named correctly — it copies an event into dedicated storage
before the nested FIFO call so the overlay cannot corrupt the live one.

The rename was applied across the submodule and `src/ioc_hid.c` with word
boundaries — necessary, because `usbh_xc8_hid_ep_mps` is correctness storage
while `usbh_xc8_hid_ep_mps_lo` and `_hi` beside it are traces. Both profiles
build byte-identical afterwards, as a pure rename should.

Note `xc8_saved_hub_ep` serves double duty: it is correctness storage *and* is
reported as a HIDSTATUS breadcrumb. That overlap is precisely what made the
family so easy to misread.

## Correctness changes by file

Hunks that change program behaviour under XC8 and must survive any refresh.

### `common/tusb_fifo.h`
XC8 accepts only integral types no wider than 8 bits as bit-field bases. The
packed `item_size : 15` / `overwritable : 1` struct is replaced with plain
`uint16_t` + `bool` fields.

### `common/tusb_compiler.h`
`TU_ATTR_*` attribute definitions extended to `__clang__` alongside `__GNUC__`.

### `tusb.c`
XC8 does not honour the weak attribute, so the default `tusb_time_delay_ms_api()`
is compiled out and the port supplies its own. This is also wanted on the
merits: the default is only as accurate as `millis()` is granular, and a coarse
tick lets a delay finish *early*, which breaks the reset-recovery wait that
enumeration depends on. Also a `tu_edpt_validate()` cast change.

### `host/usbh.c`
Event copied into `_xc8_queue_event` before the nested FIFO call. `desc_itf`
preserved across `driver->open()`. Unsupported callback-less blocking control
transfers refused cleanly rather than entering a path XC8 cannot implement
correctly — *the refusal stays even though its counter can go*.

### `host/hub.c`, `host/hub.h`
Endpoint address and device address preserved across `tuh_edpt_open()` before
the retained hub object is updated.

### `class/hid/hid_host.c`
HID object pointer, endpoint descriptor fields, next descriptor and
report-descriptor fields preserved across nested endpoint-open calls; the
open-coded binding path where nested inline helpers were miscompiled; the valid
boot-report packet-size fallback.

### `portable/analog/max3421/hcd_max3421.c`
Byte-offset descriptor decoding and XC8-compatible structure definitions that
avoid unsupported bit-field bases and miscompiled inline helpers.

## Hunk classification

Mechanical classification of the 63 hunks, by whether their non-comment lines
touch `usbh_xc8_*`:

| File | correctness | mixed | trace-only |
|---|---:|---:|---:|
| `class/hid/hid_host.c` | 1 | 13 | 0 |
| `common/tusb_compiler.h` | 1 | 0 | 0 |
| `common/tusb_fifo.h` | 1 | 0 | 0 |
| `host/hub.c` | 0 | 10 | 0 |
| `host/hub.h` | 3 | 0 | 0 |
| `host/usbh.c` | 8 | 9 | 0 |
| `portable/.../hcd_max3421.c` | 6 | 5 | 3 |
| `tusb.c` | 3 | 0 | 0 |
| **total** | **23** | **37** | **3** |

**37 hunks are mixed** — correctness and trace in the same block. This is why
the trace removal cannot be a mechanical filter on the prefix, and why the
review's warning was worded as "do not delete a guarded block merely because it
contains XC8 or currently shares storage with a trace variable."

## Rules for a vendor update

1. The refresh is a rebase of `55b0d86f9` onto the new tag on the
   `zephyr80-xc8-max3421` branch. Do not re-derive the patches.
2. Every conflict in a hunk listed under "Correctness changes by file" must be
   resolved in favour of keeping the workaround. A dropped hunk builds fine.
3. After a refresh, verify enumeration on real hardware: keyboard attach,
   hot unplug and replug, and attach through a hub. Those are the paths the
   overlay workarounds protect, and none of them are covered by a build.
4. Update this file in the same change.

## Safe to remove in the trace-removal step

Everything still in the `usbh_xc8_*` family — the seven correctness stores have
been renamed out of it, so the prefix now means "trace" without exception —
together with their write sites, the `HUB_TRACE_*` enum and `usbh_xc8_hub_trace[]`, the
`usbh_xc8_d_*` decision snapshot, the enumeration/bind/setup/endpoint-map
breadcrumbs, and the HID class breadcrumbs — provided the matching `HIDSTATUS`
pages, structs, protocol offsets and extern declarations go in the same change,
so no dead diagnostic ABI is left behind.
