#ifndef ZEPHYR_SHELL_H
#define ZEPHYR_SHELL_H

#include <stdint.h>

#define ZSH_LINE_SIZE 128
#define ZSH_MAX_ARGS 16
#define ZSH_PATH_SIZE 208
#define ZSH_IO_SIZE 512

int zsh_run(void);
void zsh_putc(uint8_t c);
void zsh_puts(const char *text);
void zsh_print_u8(uint8_t value);
void zsh_print_u32(uint32_t value);
void zsh_print_hex8(uint8_t value);
void zsh_error_status(const char *command, const char *path, uint8_t status);
const char *zsh_status_text(uint8_t status);

#endif
