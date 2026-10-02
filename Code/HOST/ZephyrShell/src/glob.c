#include <string.h>
#include <zephyr/fs.h>
#include "glob.h"
#include "path.h"

static char glob_names[ZSH_GLOB_MAX][13];

static char fold(char c)
{
    if (c >= 'a' && c <= 'z')
        return (char)(c - ('a' - 'A'));
    return c;
}

uint8_t zsh_glob_has_pattern(const char *path)
{
    while (*path) {
        if (*path == '*' || *path == '?')
            return 1;
        ++path;
    }
    return 0;
}

uint8_t zsh_glob_match(const char *pattern, const char *name)
{
    const char *star = 0;
    const char *retry = 0;

    while (*name) {
        if (*pattern == '?' || fold(*pattern) == fold(*name)) {
            ++pattern;
            ++name;
        } else if (*pattern == '*') {
            star = pattern++;
            retry = name;
        } else if (star) {
            pattern = star + 1;
            name = ++retry;
        } else {
            return 0;
        }
    }
    while (*pattern == '*')
        ++pattern;
    return (uint8_t)(*pattern == 0);
}

zep_fs_status_t zsh_glob_collect(const char *pattern, uint8_t *count)
{
    zsh_path_scope_t scope;
    zep_fs_dir_t dir;
    zep_fs_dirent_t entry;
    zep_fs_status_t status;
    zep_fs_status_t close_status;
    zep_fs_status_t restore;

    if (!count)
        return ZEP_FS_RANGE;
    *count = 0;
    status = zsh_path_enter_parent(pattern, &scope);
    if (status != ZEP_FS_OK)
        return status;
    status = zep_fs_opendir(&dir);
    if (status != ZEP_FS_OK) {
        (void)zsh_path_leave(&scope);
        return status;
    }
    for (;;) {
        status = zep_fs_readdir(dir, &entry);
        if (status == ZEP_FS_END) {
            status = ZEP_FS_OK;
            break;
        }
        if (status != ZEP_FS_OK)
            break;
        if (!zsh_glob_match(scope.leaf, entry.name))
            continue;
        if (*count == ZSH_GLOB_MAX) {
            status = ZEP_FS_RANGE;
            break;
        }
        strcpy(glob_names[*count], entry.name);
        ++*count;
    }
    close_status = zep_fs_closedir(dir);
    restore = zsh_path_leave(&scope);
    if (status == ZEP_FS_OK && close_status != ZEP_FS_OK)
        status = close_status;
    if (status == ZEP_FS_OK && restore != ZEP_FS_OK)
        status = restore;
    if (status == ZEP_FS_OK && !*count)
        status = ZEP_FS_NOT_FOUND;
    return status;
}

const char *zsh_glob_name(uint8_t index)
{
    return glob_names[index];
}

zep_fs_status_t zsh_glob_path(const char *pattern, const char *name,
                              char path[ZSH_PATH_SIZE])
{
    char parent[ZSH_PATH_SIZE];
    char leaf[13];
    uint16_t parent_length;
    uint16_t name_length;

    if (zsh_path_split(pattern, parent, sizeof(parent), leaf) != ZEP_FS_OK)
        return ZEP_FS_BAD_NAME;
    if (strcmp(parent, ".") == 0) {
        name_length = (uint16_t)strlen(name);
        if (name_length >= ZSH_PATH_SIZE)
            return ZEP_FS_RANGE;
        strcpy(path, name);
        return ZEP_FS_OK;
    }
    parent_length = (uint16_t)strlen(parent);
    name_length = (uint16_t)strlen(name);
    if ((uint16_t)(parent_length + (parent_length != 1 || parent[0] != '/') +
                   name_length + 1) > ZSH_PATH_SIZE)
        return ZEP_FS_RANGE;
    strcpy(path, parent);
    if (parent_length != 1 || parent[0] != '/')
        path[parent_length++] = '/';
    memcpy(path + parent_length, name, name_length + 1);
    return ZEP_FS_OK;
}
