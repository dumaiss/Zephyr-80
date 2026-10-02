#include <string.h>
#include "parser.h"

static uint8_t is_space(char c)
{
    return c == ' ' || c == '\t';
}

zsh_parse_status_t zsh_parse_line(char *line, char *argv[ZSH_MAX_ARGS],
                                  uint8_t *argc)
{
    char *src;
    char *dst;
    char quote;
    uint8_t count = 0;

    if (!line || !argv || !argc)
        return ZSH_PARSE_TOO_LONG;
    if (strlen(line) >= ZSH_LINE_SIZE)
        return ZSH_PARSE_TOO_LONG;

    src = line;
    dst = line;
    while (*src) {
        while (is_space(*src))
            ++src;
        if (!*src)
            break;
        if (count == ZSH_MAX_ARGS)
            return ZSH_PARSE_TOO_MANY_ARGS;
        argv[count++] = dst;
        quote = 0;
        while (*src) {
            if (quote) {
                if (*src == quote) {
                    quote = 0;
                    ++src;
                } else {
                    *dst++ = *src++;
                }
            } else if (*src == '\'' || *src == '"') {
                quote = *src++;
            } else if (is_space(*src)) {
                break;
            } else {
                *dst++ = *src++;
            }
        }
        if (quote)
            return ZSH_PARSE_UNTERMINATED_QUOTE;
        while (is_space(*src))
            ++src;
        *dst++ = 0;
    }
    *argc = count;
    return ZSH_PARSE_OK;
}

const char *zsh_parse_status_text(zsh_parse_status_t status)
{
    switch (status) {
    case ZSH_PARSE_OK: return "ok";
    case ZSH_PARSE_TOO_LONG: return "line too long";
    case ZSH_PARSE_TOO_MANY_ARGS: return "too many arguments";
    case ZSH_PARSE_UNTERMINATED_QUOTE: return "unterminated quote";
    default: return "parse error";
    }
}
