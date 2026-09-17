/* PCTRACE's private reservation, E000h-E2FFh.  E300h-E3FFh stays with the
 * ZephyrC tick stub.  Keep these addresses in step with pc_probe.asm.
 *
 * The region survives a warm boot, and survives whatever sends control back to
 * 0100h, which is the point: the ring is read on the next entry to main. */
#ifndef PC_PROBE_H
#define PC_PROBE_H

#include <stdint.h>

#define PC_MAGIC        ((volatile uint8_t *)0xe000)    /* "PCT1" */
#define PC_INDEX        ((volatile uint8_t *)0xe004)    /* next slot */
#define PC_WRAPPED      ((volatile uint8_t *)0xe005)
#define PC_COUNT        ((volatile uint32_t *)0xe006)   /* interrupts seen */
#define PC_MARK         ((volatile uint8_t *)0xe00a)    /* where main had got to */
#define PC_RUNS         ((volatile uint8_t *)0xe00b)    /* entries to main */
#define PC_CHANNEL      ((volatile uint8_t *)0xe00c)
#define PC_HEART        ((volatile uint8_t *)0xe00d)    /* foreground heartbeat */
#define PC_STALL        ((volatile uint16_t *)0xe00e)   /* interrupts since it moved */
#define PC_WATCHDOG     ((volatile uint16_t *)0xe010)   /* limit, 0 = off */
#define PC_FIRED        ((volatile uint8_t *)0xe012)    /* watchdog warm booted us */
#define PC_MINSP        ((volatile uint16_t *)0xe014)   /* lowest interrupted SP seen */
#define PC_CALLBACK     0xe100
#define PC_RING         ((volatile uint8_t *)0xe1c0)
#define PC_SLOTS        40
#define PC_ENTRY        6      /* PC, SP, latch, channel */

void zep_pc_probe_install(void);
extern const uint8_t zep_pc_probe_image[];
extern const uint16_t zep_pc_probe_size;

#endif
