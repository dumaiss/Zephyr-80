#ifndef SPI_MANAGEMENT_H
#define SPI_MANAGEMENT_H

#include <stdint.h>

typedef enum {
    SPI_MANAGEMENT_DEVICE_NONE = 0,
    SPI_MANAGEMENT_DEVICE_SD,
    SPI_MANAGEMENT_DEVICE_USB,
} spi_management_device_t;

typedef enum {
    SPI_MANAGEMENT_MESSAGE_NONE = 0,
    SPI_MANAGEMENT_MESSAGE_SIO_COMMAND_READY,
} spi_management_message_type_t;

typedef struct {
    spi_management_message_type_t type;
    uint8_t command;
    uint8_t length;
    uint8_t payload[8];
} spi_management_mailbox_message_t;

void spi_management_init(void);
void spi_management_service(void);
void spi_management_select(spi_management_device_t device);
void spi_management_deselect_all(void);
uint8_t spi_management_sd_sio_sync_asserted(void);
uint8_t spi_management_usb_sio_sync_asserted(void);
uint8_t spi_management_usb_interrupt_asserted(void);
uint8_t spi_management_busy(void);
uint8_t spi_management_transfer_byte(uint8_t tx_byte);
uint8_t spi_management_mailbox_read(
    spi_management_device_t device,
    spi_management_mailbox_message_t *message);

#endif
