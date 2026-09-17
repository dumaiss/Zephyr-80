/* zep_internal.h -- shared by the library's own modules; not installed. */
#ifndef ZEP_INTERNAL_H
#define ZEP_INTERNAL_H

#include <stdint.h>
#include <zephyr/zephyr.h>

/* ---- Assembly helpers (src/zep_io.asm) ----
 * z88dk classic + SDCC uses sdcccall(0): stack arguments, caller pops,
 * uint8_t returned in L, uint16_t in HL. */

typedef struct { uint8_t c, b; uint16_t de; } zep__bdoscall_t;
uint16_t zep__bdos_bcde(zep__bdoscall_t *call) __z88dk_fastcall;  /* BDOS with B set */
uint16_t zep__call_saved(uint16_t address) __z88dk_fastcall;      /* call, keeping IX/IY */
uint8_t  zep__in(uint8_t port) __z88dk_fastcall;
void     zep__out2(uint16_t port_and_value) __z88dk_fastcall;     /* L = port, H = value */
void     zep__di(void);
void     zep__ei(void);
uint8_t  zep__iff(void);   /* 1 if maskable interrupts are enabled */
void     zep__otir(uint8_t port, const uint8_t *src, uint16_t n);
void     zep__inir(uint8_t port, uint8_t *dst, uint16_t n);
void     zep__outn(uint8_t port, uint8_t value, uint16_t n);

#define zep__out(port, value) zep__out2(((uint16_t)(uint8_t)(value) << 8) | (uint8_t)(port))

/* Serial polling with millisecond timeouts (src/zep_serial.asm). */
int      zep__sio_getc(uint8_t ctrl_port, uint16_t ms);
uint8_t  zep__sio_putc(uint8_t ctrl_port, uint8_t byte, uint16_t ms);

/* ---- Common-memory stubs (stubs/zep_stubs.asm, embedded as an image) ---- */

#define ZEP__STUB_BASE        0xE300
#define ZEP__STUB_TICK        0xE300     /* CTC callback; BIOS enters with C = channel */
#define ZEP__STUB_BANK_CALL   0xE303
#define ZEP__TICK_STATE       0xE3A0     /* 12 bytes per channel */
#define ZEP__BC_BANK          0xE3D0
#define ZEP__BC_HOME          0xE3D1
#define ZEP__BC_ENTRY         0xE3D2
#define ZEP__BC_ARG           0xE3D4
#define ZEP__BC_FACADE        0xE3D8

/* Tick state layout, per channel.  The callback writes everything except
 * `consumed`, which only the program writes: a lock-free queue, so reading a
 * tick never has to disable interrupts. */
#define ZEP__TS_RATE      0
#define ZEP__TS_ACC       1     /* 16-bit */
#define ZEP__TS_PRODUCED  3
#define ZEP__TS_CONSUMED  4
#define ZEP__TS_OVERFLOW  5     /* 16-bit */
#define ZEP__TS_COUNT     7     /* 32-bit */
#define ZEP__TS_SIZE      12

extern const uint8_t  zep__stub_image[];
extern const uint16_t zep__stub_image_len;
void zep__stubs_install(void);

/* ---- Ownership and cleanup (src/zep_core.c) ---- */

#define ZEP__MOD_SOUND   0
#define ZEP__MOD_TIMER   1
#define ZEP__MOD_SERIAL  2
#define ZEP__MOD_VDP     3
#define ZEP__MOD_COUNT   4
typedef void (*zep__cleanup_fn)(void);
void zep__on_exit(uint8_t module, zep__cleanup_fn fn);

#define ZEP__OWNER_NONE    0
#define ZEP__OWNER_TIMER   1
#define ZEP__OWNER_SERIAL  2
extern uint8_t zep__ctc_owner[4];

uint8_t zep__isr_register(uint8_t source, uint16_t entry);
uint8_t zep__isr_unregister(uint8_t source);

#endif
