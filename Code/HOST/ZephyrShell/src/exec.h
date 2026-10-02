#ifndef ZEPHYR_SHELL_EXEC_H
#define ZEPHYR_SHELL_EXEC_H

#include <stdint.h>
#include <zephyr/fs.h>

zep_fs_status_t zsh_exec_open_path(const char *command, char name[13],
                                   zep_fs_stat_t *info,
                                   zep_fs_handle_t *handle);
void zsh_exec_com(uint8_t argc, char **argv);

#endif
