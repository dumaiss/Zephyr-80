#ifndef TUSB_CONFIG_H
#define TUSB_CONFIG_H

/* TinyUSB host-only configuration for the external MAX3421E.
 *
 * The first supported topology is deliberately narrow:
 *
 *   MAX3421E root port -> one hub -> up to two HID devices/interfaces
 *
 * There is no RTOS and no USB mass-storage class.  SD storage continues to
 * use the IOC's existing native SPI driver and transport paths. */
#define CFG_TUSB_MCU                       OPT_MCU_NONE
#define CFG_TUSB_OS                        OPT_OS_NONE
#define CFG_TUSB_DEBUG                     0

#define CFG_TUH_ENABLED                    1
#define CFG_TUH_MAX3421                    1
/* Non-hub devices.  TinyUSB sizes its device table as CFG_TUH_DEVICE_MAX +
 * CFG_TUH_HUB, so 1 would leave exactly one slot for everything downstream of
 * the FE1.1S -- a keyboard and nothing else, ever. */
#define CFG_TUH_DEVICE_MAX                 2
#define CFG_TUH_HUB                        1
#define CFG_TUH_HID                        2

#define CFG_TUH_ENUMERATION_BUFSIZE        128
#define CFG_TUH_HUB_BUFSIZE                12
#define CFG_TUH_HID_EPIN_BUFSIZE           8
#define CFG_TUH_HID_EPOUT_BUFSIZE          8
/* TinyUSB's own default is (8 + 4 * (CFG_TUH_DEVICE_MAX - 1)) = 12 here, and
 * slot [0] is reserved for address 0.  The previous value of 5 left only four
 * usable slots for a hub (control + interrupt-IN) plus anything downstream,
 * and hcd_edpt_open() fails silently when the table is full -- which surfaces
 * much later as an endpoint that simply is not there. */
#define CFG_TUH_MAX3421_ENDPOINT_TOTAL     12

#define CFG_TUH_CDC                        0
#define CFG_TUH_MSC                        0
#define CFG_TUH_MIDI                       0
#define CFG_TUH_VENDOR                     0

#define CFG_TUH_LOG_LEVEL                  0
#define CFG_TUH_API_EDPT_XFER              0

#endif /* TUSB_CONFIG_H */
