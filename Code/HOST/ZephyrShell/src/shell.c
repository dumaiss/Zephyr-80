#include <cpm.h>
#include <string.h>
#include <zephyr/fs.h>
#include "builtins.h"
#include "exec.h"
#include "parser.h"
#include "shell.h"

/* Transitional ZephyrOS namespace policy: FS2 is currently mounted as CP/M
 * drive B:.  Keep the assumption here until a native volume-selection API
 * replaces it. */
#define ZSH_NATIVE_DRIVE 1

static char line[ZSH_LINE_SIZE];
static char previous_line[ZSH_LINE_SIZE];
static uint8_t previous_length;
static char *argv[ZSH_MAX_ARGS];

static void print_prompt(void)
{
    char cwd[ZSH_PATH_SIZE];
    uint8_t drive = (uint8_t)bdos(25, 0);
    uint8_t user = (uint8_t)bdos(32, 0xff);
    zep_fs_status_t status = zep_fs_getcwd(cwd, sizeof(cwd));

    zsh_putc((uint8_t)('A' + drive));
    zsh_print_u8(user);
    zsh_putc(':');
    if (status != ZEP_FS_OK) zsh_putc('?');
    else zsh_puts(cwd);
    zsh_putc(0x24);
    zsh_putc(' ');
}

static void erase_input(uint8_t count)
{
    while (count--)
        zsh_puts("\b \b");
}

static uint8_t read_line(void)
{
    uint8_t length = 0;
    uint8_t escape_state = 0;
    uint8_t byte;

    line[0] = 0;
    for (;;) {
        do {
            byte = (uint8_t)bdos(6, 0xff);
        } while (!byte);

        if (escape_state) {
            if (escape_state == 1 && byte == '[') {
                escape_state = 2;
                continue;
            }
            if (escape_state == 2 && byte == 'A' && previous_length) {
                erase_input(length);
                memcpy(line, previous_line, previous_length + 1);
                length = previous_length;
                zsh_puts(line);
            }
            escape_state = 0;
            continue;
        }
        if (byte == 0x1b) {
            escape_state = 1;
            continue;
        }
        if (byte == '\r' || byte == '\n')
            break;
        if (byte == 0x0c) {
            zsh_putc(0x0c);
            print_prompt();
            zsh_puts(line);
            continue;
        }
        if (byte == 0x03) {
            zsh_puts("^C\n");
            (void)bdos(0, 0);
            return 0;
        }
        if (byte == 0x15 || byte == 0x18) {
            erase_input(length);
            length = 0;
            line[0] = 0;
            continue;
        }
        if (byte == 0x08 || byte == 0x7f) {
            if (length) {
                --length;
                line[length] = 0;
                zsh_puts("\b \b");
            }
            continue;
        }
        if ((byte == '\t' || byte >= 0x20) && length < ZSH_LINE_SIZE - 1) {
            line[length++] = (char)byte;
            line[length] = 0;
            zsh_putc(byte);
        }
    }
    zsh_putc('\n');
    if (length) {
        memcpy(previous_line, line, length + 1);
        previous_length = length;
    }
    return 1;
}

int zsh_run(void)
{
    uint8_t argc;
    zsh_parse_status_t parsed;

    (void)bdos(14, ZSH_NATIVE_DRIVE);
    zsh_puts("ZephyrShell v1 - native FS2 shell\n");
    for (;;) {
        print_prompt();
        if (!read_line())
            continue;
        parsed = zsh_parse_line(line, argv, &argc);
        if (parsed != ZSH_PARSE_OK) {
            zsh_puts("zsh: "); zsh_puts(zsh_parse_status_text(parsed));
            zsh_putc('\n');
            continue;
        }
        if (!argc)
            continue;
        if (!zsh_builtin_dispatch(argc, argv))
            zsh_exec_com(argc, argv);
    }
}
