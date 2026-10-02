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

static uint8_t read_line(void)
{
    static uint8_t console_buffer[ZSH_LINE_SIZE + 1];
    uint8_t length;

    console_buffer[0] = ZSH_LINE_SIZE - 1;
    console_buffer[1] = 0;
    (void)bdos(10, (int)console_buffer);
    zsh_putc('\n');
    length = console_buffer[1];
    if (length >= ZSH_LINE_SIZE) {
        zsh_puts("zsh: input too long\n");
        return 0;
    }
    memcpy(line, console_buffer + 2, length);
    line[length] = 0;
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
