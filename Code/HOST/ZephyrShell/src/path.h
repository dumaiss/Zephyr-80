#ifndef ZEPHYR_SHELL_PATH_H
#define ZEPHYR_SHELL_PATH_H

#include <stdint.h>
#include <zephyr/fs.h>
#include "shell.h"

typedef struct {
    char cwd[ZSH_PATH_SIZE];
    char leaf[13];
    uint8_t active;
} zsh_path_scope_t;

zep_fs_status_t zsh_path_split(const char *path, char *parent,
                               uint16_t parent_size, char leaf[13]);
zep_fs_status_t zsh_path_enter_parent(const char *path,
                                      zsh_path_scope_t *scope);
zep_fs_status_t zsh_path_leave(zsh_path_scope_t *scope);
zep_fs_status_t zsh_path_chdir_atomic(const char *path);
zep_fs_status_t zsh_paths_same_parent(const char *left, const char *right,
                                      char left_leaf[13],
                                      char right_leaf[13], uint8_t *same);

#endif
