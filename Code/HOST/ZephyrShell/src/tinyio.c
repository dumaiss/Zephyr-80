#include <stdint.h>
#ifdef ZSH_HOST_TEST
#include <stdio.h>
#else
#include <cpm.h>
#endif
#include "shell.h"

#ifdef ZSH_HOST_TEST
static const uint8_t *zsh_test_input;
static uint8_t zsh_test_input_length;
static uint8_t zsh_test_input_position;
#else
static uint8_t zsh_after_cr;
#endif

static uint8_t console_read_pending(void)
{
#ifdef ZSH_HOST_TEST
    if (zsh_test_input_position >= zsh_test_input_length)
        return 0;
    return zsh_test_input[zsh_test_input_position++];
#else
    return (uint8_t)bdos(6, 0xff);
#endif
}

#ifdef ZSH_HOST_TEST
void zsh_test_console_input(const uint8_t *bytes, uint8_t length)
{
    zsh_test_input = bytes;
    zsh_test_input_length = length;
    zsh_test_input_position = 0;
}
#endif

uint8_t zsh_output_poll(void)
{
    uint8_t c = console_read_pending();

    if (c == 0x13) {
        do {
            c = console_read_pending();
        } while (!c);
    }
    return (uint8_t)(c == 0x03);
}

uint8_t zsh_output_page(void)
{
    uint8_t c;

    zsh_puts("--More--");
    do {
        do {
            c = console_read_pending();
        } while (!c);
    } while (c == 0x13);
    zsh_puts("\r        \r");
    return (uint8_t)(c == 0x03);
}

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
