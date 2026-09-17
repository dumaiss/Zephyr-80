/* timer.h -- CTC tick service, raw CTC, and interrupt callbacks.
 * See DOC/API.md section 6.
 */
#ifndef ZEPHYR_TIMER_H
#define ZEPHYR_TIMER_H

#include <zephyr/zephyr.h>

/* A 180.0115 Hz base on the channel and a phase accumulator give rate_hz
 * logical ticks per second, 1-180.  60 Hz is exact (divide by three). */
uint8_t  zep_timer_start(uint8_t channel, uint8_t rate_hz);
uint8_t  zep_timer_stop(uint8_t channel);
uint8_t  zep_timer_take_tick(uint8_t channel);   /* 1 if a tick was consumed */
uint8_t  zep_timer_pending(uint8_t channel);     /* saturates at 255 */
uint16_t zep_timer_overflows(uint8_t channel);
uint32_t zep_timer_count(uint8_t channel);       /* base (180 Hz) interrupts since start */

/* Raw CTC.  A control word without D0 set (a vector write) is ignored: the
 * BIOS owns the vector byte.  The time constant is written when D2 is set.
 *
 * These take the channel number, as registration does.  The board wires the
 * channel-select bits to the address lines in reverse (A0/A1 against CS0/CS1),
 * so the ports are 40h, 42h, 41h, 43h; zep_ctc_port reports the real one. */
void     zep_ctc_write(uint8_t channel, uint8_t control, uint8_t time_constant);
uint8_t  zep_ctc_port(uint8_t channel);
uint8_t  zep_ctc_read(uint8_t channel);
void     zep_ctc_reset(uint8_t channel);

/* Common memory for callbacks, E000h-E2FFh. */
void    *zep_common_alloc(uint16_t n);                          /* NULL when full */
uint8_t  zep_common_install(void *dst, const void *code, uint16_t n);

#define ZEP_ISR_CTC0  0
#define ZEP_ISR_CTC1  1
#define ZEP_ISR_CTC2  2
#define ZEP_ISR_CTC3  3
#define ZEP_ISR_VDP   4        /* needs BIOS support that does not exist yet */
uint8_t  zep_isr_register(uint8_t source, void *entry);         /* BDOS 200 */
uint8_t  zep_isr_unregister(uint8_t source);                    /* BDOS 201 */

#endif
