/* bdos.h -- operating system services.
 *
 * Standard CP/M and ZSDOS calls come from z88dk: <stdio.h> for files and
 * <cpm.h> for bdos(), struct fcb and friends.  This header adds the ZSDOS clock
 * and file stamps, and the Zephyr BDOS extensions (functions 200-217).
 */
#ifndef ZEPHYR_BDOS_H
#define ZEPHYR_BDOS_H

#include <zephyr/zephyr.h>
#include <cpm.h>

/* ---- ZSDOS clock and stamps ------------------------------------------- */

/* DateStamper layout: every field is BCD. */
typedef struct {
    uint8_t year, month, day, hour, minute, second;
} zep_datetime_t;

uint8_t zep_get_time(zep_datetime_t *t);                      /* ZSDOS 98 */
uint8_t zep_set_time(const zep_datetime_t *t);                /* ZSDOS 99 */

/* 15 bytes: create, last access, modify; five BCD bytes each (YY MM DD HH MM).
 * The file must be on a drive with DateStamper stamps. */
uint8_t zep_get_stamp(struct fcb *f, uint8_t stamp[15]);      /* ZSDOS 102 */
uint8_t zep_set_stamp(struct fcb *f, const uint8_t stamp[15]); /* ZSDOS 103 */

/* ---- Zephyr extensions ------------------------------------------------ */

typedef struct {
    uint8_t  version;          /* 1 */
    uint8_t  ioc_level;        /* IO Controller transport level */
    uint16_t ioc_diag;         /* address of the IOC link failure record */
    uint16_t sercon_flags;     /* address of the serial console flags byte */
    uint16_t bios_table;       /* CP/M BIOS jump table */
    uint16_t ext_table;        /* Zephyr extension table */
} zep_sysinfo_t;

/* BDOS 203.  NULL when the running BIOS is not a Zephyr BIOS. */
const zep_sysinfo_t *zep_sysinfo(void);

/* BDOS 210-217 register block, in the facade's order. */
typedef struct { uint8_t a, c, b, e, d, l, h; } zep_regs_t;
uint8_t zep_bdos_ext(uint8_t fn, zep_regs_t *r);

/* IO Controller.  32-byte mailboxes; status is the transport result. */
uint8_t zep_ioc_call(const uint8_t *tx, uint8_t *rx);         /* BDOS 214 */
uint8_t zep_ioc_bulk_read(uint8_t *dst, uint16_t n);          /* BDOS 216 */
uint8_t zep_ioc_bulk_write(const uint8_t *src, uint16_t n);   /* BDOS 217 */

#endif
