/* zep_bank.c -- banks 1-6 through MOVE/XMOVE, and calls into banked code. */
#include <zephyr/bank.h>
#include <zephyr/bdos.h>
#include "zep_internal.h"

#define ZB_MOVE    210
#define ZB_XMOVE   211

#define BANKED_END 0xe000UL

/* The standard startup code runs the whole program in bank 0. */
static uint8_t home_bank = 0;

uint8_t zep_bank_current(void)
{
    return home_bank;
}

static uint8_t range_ok(uint8_t bank, uint16_t addr, uint16_t n)
{
    if (bank > ZEP_BANK_LAST)
        return 0;
    if (bank == 0)
        return (uint32_t)addr + n <= 0x10000UL;
    return (uint32_t)addr + n <= BANKED_END;
}

uint8_t zep_bank_copy(uint8_t dst_bank, uint16_t dst,
                      uint8_t src_bank, uint16_t src, uint16_t n)
{
    zep_regs_t r;

    if (n == 0)
        return ZEP_OK;
    if (!range_ok(dst_bank, dst, n) || !range_ok(src_bank, src, n))
        return ZEP_EINVAL;

    r.a = r.e = r.d = r.l = r.h = 0;
    r.c = src_bank;
    r.b = dst_bank;
    if (zep_bdos_ext(ZB_XMOVE, &r) != 0)
        return ZEP_EINVAL;

    r.a = 0;
    r.c = (uint8_t)n;
    r.b = (uint8_t)(n >> 8);
    r.e = (uint8_t)src;
    r.d = (uint8_t)(src >> 8);
    r.l = (uint8_t)dst;
    r.h = (uint8_t)(dst >> 8);
    (void)zep_bdos_ext(ZB_MOVE, &r);
    return ZEP_OK;
}

uint8_t zep_bank_read(uint8_t bank, uint16_t addr, void *buf, uint16_t n)
{
    return zep_bank_copy(home_bank, (uint16_t)buf, bank, addr, n);
}

uint8_t zep_bank_write(uint8_t bank, uint16_t addr, const void *buf, uint16_t n)
{
    return zep_bank_copy(bank, addr, home_bank, (uint16_t)buf, n);
}

uint8_t zep_bank_fill(uint8_t bank, uint16_t addr, uint8_t value, uint16_t n)
{
    uint8_t block[64];
    uint16_t chunk;
    uint8_t i, r;

    if (!range_ok(bank, addr, n))
        return ZEP_EINVAL;
    for (i = 0; i < sizeof(block); i++)
        block[i] = value;
    while (n) {
        chunk = n > sizeof(block) ? sizeof(block) : n;
        r = zep_bank_write(bank, addr, block, chunk);
        if (r != ZEP_OK)
            return r;
        addr += chunk;
        n -= chunk;
    }
    return ZEP_OK;
}

uint8_t zep_bank_prepare(uint8_t bank)
{
    if (bank < ZEP_BANK_FIRST || bank > ZEP_BANK_LAST)
        return ZEP_EINVAL;
    return zep_bank_copy(bank, 0x0000, home_bank, 0x0000, 0x0100);
}

uint16_t zep_bank_call(uint8_t bank, uint16_t entry, uint16_t hl)
{
    if (bank > ZEP_BANK_LAST)
        return 0xffff;
    zep__stubs_install();
    *(uint8_t *)ZEP__BC_BANK = bank;
    *(uint8_t *)ZEP__BC_HOME = home_bank;
    *(uint16_t *)ZEP__BC_ENTRY = entry;
    *(uint16_t *)ZEP__BC_ARG = hl;
    *(uint16_t *)ZEP__BC_FACADE = *(uint16_t *)0x0006;
    return zep__call_saved(ZEP__STUB_BANK_CALL);
}
