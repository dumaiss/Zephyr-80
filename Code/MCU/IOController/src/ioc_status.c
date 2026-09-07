#include "ioc_frame.h"

/* SdStatus to wire status.
 *
 * Lives here rather than beside a handler because three layers need it now:
 * the record handlers, the volume layer, and the shared folder.  A driver enum
 * has no business knowing frame layouts, and a handler has no business owning
 * a mapping two other modules depend on.
 *
 * One-to-one on purpose.  A host-side dump of the status byte says which stage
 * of the card bring-up gave up, and collapsing any of these into a generic
 * error is what turns a ten-minute diagnosis into an afternoon. */
uint8_t ioc_status_from_sd(SdStatus st)
{
    switch (st) {
    case SD_OK:                 return IOC_STATUS_OK;
    case SD_ERR_NO_CARD:        return IOC_STATUS_SD_NO_CARD;
    case SD_ERR_NO_RESPONSE:    return IOC_STATUS_SD_NO_RESPONSE;
    case SD_ERR_UNUSABLE:       return IOC_STATUS_SD_UNUSABLE;
    case SD_ERR_NOT_READY:      return IOC_STATUS_SD_NOT_READY;
    case SD_ERR_READ:           return IOC_STATUS_SD_READ_FAIL;
    case SD_ERR_NO_TOKEN:       return IOC_STATUS_SD_NO_TOKEN;
    case SD_ERR_CRC:            return IOC_STATUS_SD_CRC;
    case SD_ERR_BUS:            return IOC_STATUS_SD_BUS;
    case SD_ERR_WRITE:          return IOC_STATUS_SD_WRITE_FAIL;
    case SD_ERR_WRITE_REJECTED: return IOC_STATUS_SD_WRITE_REJ;
    case SD_ERR_WRITE_BUSY:     return IOC_STATUS_SD_WRITE_BUSY;
    default:                    return IOC_STATUS_ERROR;
    }
}
