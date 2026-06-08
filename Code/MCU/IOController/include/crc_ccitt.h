#ifndef CRC_CCITT_H
#define CRC_CCITT_H

#include <stdint.h>

/* CRC-CCITT / CRC-16 as used by the Z80 SIO in SDLC mode.
 *
 * Parameters (must match Z80 SIO hardware exactly — verify with PING):
 *   Polynomial  : 0x1021
 *   Initial val : 0xFFFF
 *   Bit order   : LSB-first (SDLC convention; each byte is shifted bit 0 first)
 *   Final XOR   : 0xFFFF   (complement of computed remainder)
 *   FCS order   : low byte transmitted first, high byte second
 *
 * Transmitter:
 *   crc = CRC_CCITT_INIT
 *   for each data byte: crc = crc_ccitt_update(crc, byte)
 *   fcs = crc ^ CRC_CCITT_XOR_OUT          (complement)
 *   transmit fcs & 0xFF first, then fcs >> 8
 *
 * Receiver validation:
 *   Compute CRC over the 32 data bytes received between flags.
 *   Apply CRC_CCITT_XOR_OUT.
 *   Compare with the two FCS bytes (low byte first).
 *
 * TODO: verify polynomial, bit order, and FCS byte order against the Z80 SIO
 * hardware during Phase 1 bring-up.  Isolate any adjustments to this header.
 */
#define CRC_CCITT_INIT     0xFFFFu
#define CRC_CCITT_XOR_OUT  0xFFFFu

/* Update CRC with one byte (bits fed LSB-first to match SDLC bit order). */
uint16_t crc_ccitt_update(uint16_t crc, uint8_t byte);

#endif /* CRC_CCITT_H */
