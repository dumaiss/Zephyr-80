#ifndef ZEPHYR_SHELL_PARSER_H
#define ZEPHYR_SHELL_PARSER_H

#include <stdint.h>
#include "shell.h"

typedef enum {
    ZSH_PARSE_OK = 0,
    ZSH_PARSE_TOO_LONG,
    ZSH_PARSE_TOO_MANY_ARGS,
    ZSH_PARSE_UNTERMINATED_QUOTE
} zsh_parse_status_t;

zsh_parse_status_t zsh_parse_line(char *line, char *argv[ZSH_MAX_ARGS],
                                  uint8_t *argc);
const char *zsh_parse_status_text(zsh_parse_status_t status);

#endif
