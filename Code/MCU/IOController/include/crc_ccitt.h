#ifndef CRC_CCITT_H
#define CRC_CCITT_H

#include <stdint.h>

/* Legacy CRC-CCITT / CRC-16 helper.
 *
 * Not used by the current SIO External Sync bring-up path.  It remains in the
 * tree only as a retained helper from the earlier SDLC experiment.
 *
 * Earlier SDLC-experiment parameters:
 *   Polynomial  : 0x1021
 *   Initial val : 0xFFFF
 *   Bit order   : LSB-first (SDLC convention; each byte is shifted bit 0 first)
 *   Final XOR   : 0xFFFF   (complement of computed remainder)
 *   FCS order   : low byte transmitted first, high byte second
 *
 * Earlier SDLC-experiment transmitter:
 *   crc = CRC_CCITT_INIT
 *   for each data byte: crc = crc_ccitt_update(crc, byte)
 *   fcs = crc ^ CRC_CCITT_XOR_OUT          (complement)
 *   transmit fcs & 0xFF first, then fcs >> 8
 *
 * Earlier SDLC-experiment receiver validation:
 *   Compute CRC over the 32 data bytes received between SDLC flags.
 *   Apply CRC_CCITT_XOR_OUT.
 *   Compare with the two FCS bytes (low byte first).
 *
 * TODO: delete or quarantine this helper once the External Sync bring-up no
 * longer needs any reference to the earlier SDLC experiment.
 */
#define CRC_CCITT_INIT     0xFFFFu
#define CRC_CCITT_XOR_OUT  0xFFFFu

/* Update CRC with one byte (legacy SDLC bit order). */
uint16_t crc_ccitt_update(uint16_t crc, uint8_t byte);

#endif /* CRC_CCITT_H */
