/* IRQTEST's private reservation. Warm boot leaves E000h-E3FFh intact.
 * E300h-E3FFh is the existing ZephyrC tick stub and its state.
 * Keep these offsets in step with irq_probe.asm. */
#ifndef IRQ_PROBE_H
#define IRQ_PROBE_H

#include <stdint.h>

#define IRQ_RECORD       ((volatile uint8_t *)0xe000)
#define IRQ_MODE         4       /* 0 = application, 1 = OS mapping */
#define IRQ_CHANNEL      5       /* physical CTC channel */
#define IRQ_CALLBACK     6       /* 0 = minimal counter, 1 = ZephyrC tick */
#define IRQ_STAGE        7       /* 0 setup, 1 running, 2 captured, 3 checked, 4 failed */
#define IRQ_PAIR         8       /* 16-bit completed pair count */
#define IRQ_OBSERVED     ((volatile uint16_t *)0xe010)
#define IRQ_MIN_CALLBACK 0xe080
#define IRQ_MIN_COUNT    ((volatile uint16_t *)0xe090)
#define IRQ_CODE         ((const uint8_t *)0xe100)
#define IRQ_GUARD        ((volatile uint8_t *)0xe2d0)
#define IRQ_GUARD_SIZE   46      /* E2D0h-E2FDh; E2FEh-E2FFh holds one push */
#define IRQ_TEST_SP      0xe300
#define IRQ_REG_COUNT    11

void zep_irq_probe_install(void);
void zep_irq_probe(uint8_t os_mode) __z88dk_fastcall;
extern const uint8_t zep_irq_probe_image[];
extern const uint16_t zep_irq_probe_size;

#endif
