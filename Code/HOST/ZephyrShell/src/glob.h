#ifndef ZEPHYR_SHELL_GLOB_H
#define ZEPHYR_SHELL_GLOB_H

#include <stdint.h>
#include <zephyr/fs.h>
#include "shell.h"

#define ZSH_GLOB_MAX 128

uint8_t zsh_glob_has_pattern(const char *path);
uint8_t zsh_glob_match(const char *pattern, const char *name);
zep_fs_status_t zsh_glob_collect(const char *pattern, uint8_t *count);
const char *zsh_glob_name(uint8_t index);
zep_fs_status_t zsh_glob_path(const char *pattern, const char *name,
                              char path[ZSH_PATH_SIZE]);

#endif
