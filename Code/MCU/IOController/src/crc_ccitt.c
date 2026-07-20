#include "crc_ccitt.h"

/* Legacy CRC-CCITT update.
 *
 * Not used by the current SIO External Sync bring-up path.
 *
 * In SDLC, each octet is transmitted bit 0 first.  The CRC engine in the Z80
 * SIO therefore feeds bit 0 of each byte into the polynomial first.  This
 * implementation mirrors that: the loop shifts out bit 0 of each byte before
 * XOR-ing with the CRC shift register.
 *
 * Polynomial 0x1021 reflected for LSB-first processing = 0x8408.
 * Using the reflected polynomial avoids explicit bit-reversal of each byte.
 *
 * Test vector (verify against Z80 SIO during hardware bring-up):
 *   CRC over no bytes (init only):  0xFFFF
 *   CRC over { 0x00 } with init 0xFFFF: 0xE1F0  (after XOR_OUT: 0x1E0F)
 *
 * TODO: delete or quarantine this helper after the External Sync bring-up.
 */
uint16_t crc_ccitt_update(uint16_t crc, uint8_t byte)
{
    uint8_t i;
    for (i = 0; i < 8; i++) {
        if ((crc ^ byte) & 0x0001u) {
            crc = (uint16_t)((crc >> 1) ^ 0x8408u);  /* reflected poly */
        } else {
            crc >>= 1;
        }
        byte >>= 1;
    }
    return crc;
}
