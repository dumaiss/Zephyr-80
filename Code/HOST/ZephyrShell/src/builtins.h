#ifndef ZEPHYR_SHELL_BUILTINS_H
#define ZEPHYR_SHELL_BUILTINS_H

#include <stdint.h>
#include <zephyr/fs.h>

int zsh_builtin_dispatch(uint8_t argc, char **argv);
zep_fs_status_t zsh_copy_file(const char *source, const char *destination);
zep_fs_status_t zsh_move_file(const char *source, const char *destination);
zep_fs_status_t zsh_list_path(const char *path, uint8_t long_form);

#endif
