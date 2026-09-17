/* zep_bdos.c -- ZSDOS clock and stamps, Zephyr BDOS extensions. */
#include <cpm.h>
#include <zephyr/bdos.h>
#include "zep_internal.h"


#define DEFAULT_DMA 0x0080

uint8_t zep_get_time(zep_datetime_t *t)
{
    return (uint8_t)bdos(98, (int)t) == 0xff ? ZEP_EUNAVAILABLE : ZEP_OK;
}

uint8_t zep_set_time(const zep_datetime_t *t)
{
    return (uint8_t)bdos(99, (int)t) == 0xff ? ZEP_EUNAVAILABLE : ZEP_OK;
}

/* ZSDOS 102/103 move the 15 stamp bytes through the DMA. */
static uint8_t stamp_call(uint8_t fn, struct fcb *f, uint8_t *stamp)
{
    uint8_t r;
    bdos(26, (int)stamp);
    r = (uint8_t)bdos(fn, (int)f);
    bdos(26, DEFAULT_DMA);
    return r == 0xff ? ZEP_EIO : ZEP_OK;
}

uint8_t zep_get_stamp(struct fcb *f, uint8_t stamp[15])
{
    return stamp_call(102, f, stamp);
}

uint8_t zep_set_stamp(struct fcb *f, const uint8_t stamp[15])
{
    return stamp_call(103, f, (uint8_t *)stamp);
}

/* BDOS 203 answers in HL, and z88dk's bdos() and bdosh() both overwrite it with
 * the A result ("ld l,a"), so this one goes through our own helper, which leaves
 * HL alone.
 *
 * An unknown BDOS function returns whatever was already in HL, so check the
 * block before trusting it: version 1, and the sercon flags in the BIOS state
 * page. */
const zep_sysinfo_t *zep_sysinfo(void)
{
    zep__bdoscall_t call;
    const zep_sysinfo_t *s;

    call.c = 203;
    call.b = 0;
    call.de = 0;
    s = (const zep_sysinfo_t *)zep__bdos_bcde(&call);
    if (s->version != 1 || (s->sercon_flags >> 8) != 0xfe)
        return 0;
    return s;
}

uint8_t zep_bdos_ext(uint8_t fn, zep_regs_t *r)
{
    return (uint8_t)bdos(fn, (int)r);
}

uint8_t zep_ioc_call(const uint8_t *tx, uint8_t *rx)
{
    zep_regs_t r;
    r.a = r.c = r.b = 0;
    r.l = (uint8_t)(uint16_t)tx;
    r.h = (uint8_t)((uint16_t)tx >> 8);
    r.e = (uint8_t)(uint16_t)rx;
    r.d = (uint8_t)((uint16_t)rx >> 8);
    return zep_bdos_ext(214, &r);
}

static uint8_t bulk(uint8_t fn, uint16_t buf, uint16_t n)
{
    zep_regs_t r;
    r.a = r.c = r.b = 0;
    r.l = (uint8_t)buf;
    r.h = (uint8_t)(buf >> 8);
    r.e = (uint8_t)n;
    r.d = (uint8_t)(n >> 8);
    return zep_bdos_ext(fn, &r);
}

uint8_t zep_ioc_bulk_read(uint8_t *dst, uint16_t n)
{
    return bulk(216, (uint16_t)dst, n);
}

uint8_t zep_ioc_bulk_write(const uint8_t *src, uint16_t n)
{
    return bulk(217, (uint16_t)src, n);
}
