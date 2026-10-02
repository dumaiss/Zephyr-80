#include <stdint.h>
#ifdef ZSH_HOST_TEST
#include <stdio.h>
#else
#include <cpm.h>
#endif
#include "shell.h"

#ifndef ZSH_HOST_TEST
static uint8_t zsh_after_cr;
#endif

void zsh_putc(uint8_t c)
{
#ifdef ZSH_HOST_TEST
    putchar(c);
#else
    if (c == '\n' && !zsh_after_cr)
        (void)bdos(6, '\r');
    (void)bdos(6, c);
    zsh_after_cr = (uint8_t)(c == '\r');
#endif
}

void zsh_puts(const char *text)
{
    while (*text)
        zsh_putc((uint8_t)*text++);
}

void zsh_print_u32(uint32_t value)
{
    char digits[10];
    uint8_t n = 0;
    if (!value) {
        zsh_putc('0');
        return;
    }
    while (value) {
        digits[n++] = (char)('0' + value % 10);
        value /= 10;
    }
    while (n)
        zsh_putc((uint8_t)digits[--n]);
}

void zsh_print_u8(uint8_t value)
{
    zsh_print_u32(value);
}

void zsh_print_hex8(uint8_t value)
{
    static const char hex[] = "0123456789ABCDEF";
    zsh_putc((uint8_t)hex[value >> 4]);
    zsh_putc((uint8_t)hex[value & 15]);
}
