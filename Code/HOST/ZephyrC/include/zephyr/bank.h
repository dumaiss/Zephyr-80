/* bank.h -- SRAM banks 1-6 as data, and calls into code placed in a bank.
 * See DOC/API.md section 8.
 */
#ifndef ZEPHYR_BANK_H
#define ZEPHYR_BANK_H

#include <zephyr/zephyr.h>

#define ZEP_BANK_FIRST  1
#define ZEP_BANK_LAST   6

uint8_t  zep_bank_current(void);
/* Addresses in banks 1-6 must lie in 0000h-DFFFh; bank 0 may also name common
 * memory.  n = 0 is a no-op. */
uint8_t  zep_bank_copy(uint8_t dst_bank, uint16_t dst,
                       uint8_t src_bank, uint16_t src, uint16_t n);
uint8_t  zep_bank_read(uint8_t bank, uint16_t addr, void *buf, uint16_t n);
uint8_t  zep_bank_write(uint8_t bank, uint16_t addr, const void *buf, uint16_t n);
uint8_t  zep_bank_fill(uint8_t bank, uint16_t addr, uint8_t value, uint16_t n);
/* Copy page zero into a bank, so code running there can call BDOS. */
uint8_t  zep_bank_prepare(uint8_t bank);
/* Map the bank, call entry with HL = hl, map this program's bank back.
 * Returns the callee's HL; 0xFFFF if the bank is refused. */
uint16_t zep_bank_call(uint8_t bank, uint16_t entry, uint16_t hl);

#endif
