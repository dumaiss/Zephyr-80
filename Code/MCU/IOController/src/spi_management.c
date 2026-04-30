#include <xc.h>

#include "config.h"
#include "spi_management.h"

/*
 * SPI management owns the IO Controller side of the SD/USB SPI bus and the
 * SIO service-request handoff into the future SD and USB drivers.
 *
 * Startup path:
 * - spi_management_init() makes RA0/RA1 passive SIO sync inputs, RA2 the USB
 *   interrupt input, RA3/RA4 idle-high SPI chip selects, and RA5/RA6/RA7 the
 *   SPI1 MOSI/MISO/SCK pins through PPS.
 * - It initializes SPI1 as the master and arms interrupt-on-change for RF1 and
 *   RF2, the active-low SIO RTS service request inputs.
 *
 * Runtime path:
 * - The ISR is intentionally small. It clears the RF1/RF2 IOC flags and latches
 *   sd_service_requested or usb_service_requested when the corresponding RTS
 *   line is low.
 * - The main loop calls spi_management_service(). That non-ISR path is where the
 *   SIO channel will be read, the command packet will be built, and a message is
 *   posted to the SD or USB mailbox.
 * - SD/USB driver code can poll spi_management_mailbox_read() for work. The
 *   mailbox is single-entry today: a new command replaces an unread old one.
 *
 * Stubbed pieces:
 * - read_sio_command() currently emits an empty command-ready message.
 * - spi_management_transfer_byte() currently returns 0xFF until the real SPI1
 *   byte-transfer sequence and device drivers are added.
 */

#define PPS_RA5 0x05
#define PPS_RA6 0x06
#define PPS_RA7 0x07

#define PPS_SPI1_SCK 0x31
#define PPS_SPI1_SDO 0x32

typedef struct {
    volatile uint8_t pending;
    spi_management_mailbox_message_t message;
} spi_management_mailbox_t;

static volatile uint8_t sd_service_requested;
static volatile uint8_t usb_service_requested;
static spi_management_mailbox_t sd_mailbox;
static spi_management_mailbox_t usb_mailbox;

/*
 * Convert the public device selector into the private single-entry mailbox
 * that holds work for that device's future driver.
 */
static spi_management_mailbox_t *mailbox_for_device(spi_management_device_t device)
{
    if (device == SPI_MANAGEMENT_DEVICE_SD) {
        return &sd_mailbox;
    }

    if (device == SPI_MANAGEMENT_DEVICE_USB) {
        return &usb_mailbox;
    }

    return 0;
}

/*
 * Build one mailbox message from the SIO channel for the requested device.
 * The real implementation will drain the SIO bytes here; the ISR never does it.
 */
static uint8_t read_sio_command(
    spi_management_device_t device,
    spi_management_mailbox_message_t *message)
{
    /*
     * TODO: read the selected SIO channel and build the driver command packet.
     * The ISR only latches that service is needed; command parsing stays here.
     */
    message->type = SPI_MANAGEMENT_MESSAGE_SIO_COMMAND_READY;
    message->command = 0;
    message->length = 0;
    (void)device;
    return 1;
}

/*
 * Publish a command to the target device mailbox. This is intentionally
 * single-entry for now, so later driver code can define queue depth semantics.
 */
static void post_mailbox(
    spi_management_device_t device,
    const spi_management_mailbox_message_t *message)
{
    spi_management_mailbox_t *const mailbox = mailbox_for_device(device);

    if (mailbox != 0) {
        mailbox->message = *message;
        mailbox->pending = 1;
    }
}

/*
 * Main-loop worker for one latched SIO request. It parses the pending command
 * and turns it into a mailbox message for the matching SD or USB driver.
 */
static void service_sio_request(spi_management_device_t device)
{
    spi_management_mailbox_message_t message;

    if (read_sio_command(device, &message)) {
        post_mailbox(device, &message);
    }
}

/*
 * Release both physical SPI slaves. Call this before selecting a target and
 * after completing a transaction to avoid bus contention.
 */
void spi_management_deselect_all(void)
{
    SD_CS_LAT = SD_CS_IDLE;
    USB_CS_LAT = USB_CS_IDLE;
}

/*
 * Select exactly one SPI target. The SIO sync inputs on RA0/RA1 are not driven
 * here; only the real SPI chip-select lines RA3/RA4 are controlled.
 */
void spi_management_select(spi_management_device_t device)
{
    spi_management_deselect_all();

    if (device == SPI_MANAGEMENT_DEVICE_SD) {
        SD_CS_LAT = SD_CS_ASSERTED;
    } else if (device == SPI_MANAGEMENT_DEVICE_USB) {
        USB_CS_LAT = USB_CS_ASSERTED;
    }
}

/*
 * Report whether the SD-side SIO sync input is currently asserted. This is a
 * stub hook for later command framing and is not consumed yet.
 */
uint8_t spi_management_sd_sio_sync_asserted(void)
{
    return CS_SIO_SD_PORT == CS_SIO_SD_ASSERTED;
}

/*
 * Report whether the USB-side SIO sync input is currently asserted. This is a
 * stub hook for later command framing and is not consumed yet.
 */
uint8_t spi_management_usb_sio_sync_asserted(void)
{
    return CS_SIO_USB_PORT == CS_SIO_USB_ASSERTED;
}

/*
 * Report the active-low interrupt from the USB subsystem. Future USB host code
 * can use this to prioritize MAX3421E service.
 */
uint8_t spi_management_usb_interrupt_asserted(void)
{
    return USB_INT_PORT == USB_INT_ASSERTED;
}

/*
 * Return whether SPI-owned work is still pending. Power management uses this
 * aggregate busy bit before allowing the PMU to remove power.
 */
uint8_t spi_management_busy(void)
{
    return sd_service_requested ||
        usb_service_requested ||
        sd_mailbox.pending ||
        usb_mailbox.pending;
}

/*
 * Transfer one byte on SPI1. It is a placeholder until the SD and USB drivers
 * define exact timing, status, and error handling.
 */
uint8_t spi_management_transfer_byte(uint8_t tx_byte)
{
    /*
     * TODO: replace this placeholder with the PIC18F57Q84 SPI1 byte-transfer
     * sequence once SD/MAX3421E drivers are added.
     */
    (void)tx_byte;
    return 0xFF;
}

/*
 * Consume one pending mailbox message for a device. Returns 1 when a message
 * was copied to the caller and clears that mailbox entry.
 */
uint8_t spi_management_mailbox_read(
    spi_management_device_t device,
    spi_management_mailbox_message_t *message)
{
    spi_management_mailbox_t *const mailbox = mailbox_for_device(device);

    if ((mailbox == 0) || !mailbox->pending) {
        return 0;
    }

    *message = mailbox->message;
    mailbox->pending = 0;
    return 1;
}

/*
 * Main-loop half of SIO servicing. It performs slow work that must not run
 * inside the ISR: reading SIO command bytes and posting mailbox messages.
 */
void spi_management_service(void)
{
    if (sd_service_requested) {
        sd_service_requested = 0;
        service_sio_request(SPI_MANAGEMENT_DEVICE_SD);
    }

    if (usb_service_requested) {
        usb_service_requested = 0;
        service_sio_request(SPI_MANAGEMENT_DEVICE_USB);
    }
}

/*
 * Configure all SPI-related pins, PPS routing, SPI1 master mode, mailbox state,
 * and RF1/RF2 interrupt-on-change inputs for SIO service requests.
 */
void spi_management_init(void)
{
    SPI1CON0 = 0x00;

    CS_SIO_SD_ANSEL = 0;
    CS_SIO_USB_ANSEL = 0;
    USB_INT_ANSEL = 0;
    USB_CS_ANSEL = 0;
    SD_CS_ANSEL = 0;
    SPI_MOSI_ANSEL = 0;
    SPI_MISO_ANSEL = 0;
    SPI_CLK_ANSEL = 0;
    SIO_USB_RTS_ANSEL = 0;
    SIO_SD_RTS_ANSEL = 0;

    spi_management_deselect_all();

    CS_SIO_SD_TRIS = 1;
    CS_SIO_USB_TRIS = 1;
    USB_INT_TRIS = 1;
    USB_CS_TRIS = 0;
    SD_CS_TRIS = 0;
    SPI_MOSI_TRIS = 0;
    SPI_MISO_TRIS = 1;
    SPI_CLK_TRIS = 0;
    SIO_USB_RTS_TRIS = 1;
    SIO_SD_RTS_TRIS = 1;

    PPSLOCK = 0x55;
    PPSLOCK = 0xAA;
    PPSLOCKbits.PPSLOCKED = 0;

    RA5PPS = PPS_SPI1_SDO;
    RA7PPS = PPS_SPI1_SCK;
    SPI1SCKPPS = PPS_RA7;
    SPI1SDIPPS = PPS_RA6;

    PPSLOCK = 0x55;
    PPSLOCK = 0xAA;
    PPSLOCKbits.PPSLOCKED = 1;

    SPI1CON1 = 0x10;
    SPI1CON2 = 0x03;
    SPI1CLK = 0x00;
    SPI1BAUD = 0x00;
    SPI1CON0 = 0x82;

    sd_service_requested = 0;
    usb_service_requested = 0;
    sd_mailbox.pending = 0;
    usb_mailbox.pending = 0;

    SIO_USB_RTS_IOCF = 0;
    SIO_SD_RTS_IOCF = 0;
    SIO_USB_RTS_IOCN = 1;
    SIO_SD_RTS_IOCN = 1;
    SIO_RTS_IOCIF = 0;
    SIO_RTS_IOCIE = 1;
    INTCON0bits.GIE = 1;
}

/*
 * Interrupt half of SIO servicing. It only clears IOC flags and latches which
 * SIO channel needs attention; spi_management_service() does the real work.
 */
void __interrupt() spi_management_isr(void)
{
    if (SIO_USB_RTS_IOCF) {
        SIO_USB_RTS_IOCF = 0;
        if (SIO_USB_RTS_PORT == SIO_USB_RTS_ASSERTED) {
            usb_service_requested = 1;
        }
    }

    if (SIO_SD_RTS_IOCF) {
        SIO_SD_RTS_IOCF = 0;
        if (SIO_SD_RTS_PORT == SIO_SD_RTS_ASSERTED) {
            sd_service_requested = 1;
        }
    }

    SIO_RTS_IOCIF = 0;
}
