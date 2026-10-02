#include <string.h>
#include <zephyr/fs.h>
#include "path.h"

static zep_fs_status_t restore_cwd(const char *cwd)
{
    return zep_fs_chdir(cwd);
}

zep_fs_status_t zsh_path_split(const char *path, char *parent,
                               uint16_t parent_size, char leaf[13])
{
    const char *end;
    const char *slash;
    uint16_t n;

    if (!path || !*path || !parent || parent_size < 2 || !leaf)
        return ZEP_FS_BAD_NAME;
    end = path + strlen(path);
    while (end > path + 1 && end[-1] == '/')
        --end;
    if (end == path || (end == path + 1 && path[0] == '/'))
        return ZEP_FS_BAD_NAME;
    slash = end;
    while (slash > path && slash[-1] != '/')
        --slash;
    n = (uint16_t)(end - slash);
    if (n == 0 || n > 12)
        return ZEP_FS_BAD_NAME;
    memcpy(leaf, slash, n);
    leaf[n] = 0;

    if (slash == path) {
        parent[0] = '.';
        parent[1] = 0;
    } else if (slash == path + 1 && path[0] == '/') {
        parent[0] = '/';
        parent[1] = 0;
    } else {
        n = (uint16_t)(slash - path - 1);
        if ((uint16_t)(n + 1) > parent_size)
            return ZEP_FS_RANGE;
        memcpy(parent, path, n);
        parent[n] = 0;
    }
    return ZEP_FS_OK;
}

zep_fs_status_t zsh_path_enter_parent(const char *path,
                                      zsh_path_scope_t *scope)
{
    char parent[ZSH_PATH_SIZE];
    zep_fs_status_t status;

    if (!scope)
        return ZEP_FS_RANGE;
    scope->active = 0;
    status = zep_fs_getcwd(scope->cwd, sizeof(scope->cwd));
    if (status != ZEP_FS_OK)
        return status;
    status = zsh_path_split(path, parent, sizeof(parent), scope->leaf);
    if (status != ZEP_FS_OK)
        return status;
    status = zep_fs_chdir(parent);
    if (status != ZEP_FS_OK) {
        (void)restore_cwd(scope->cwd);
        return status;
    }
    scope->active = 1;
    return ZEP_FS_OK;
}

zep_fs_status_t zsh_path_leave(zsh_path_scope_t *scope)
{
    zep_fs_status_t status;
    if (!scope || !scope->active)
        return ZEP_FS_OK;
    status = restore_cwd(scope->cwd);
    scope->active = 0;
    return status;
}

zep_fs_status_t zsh_path_chdir_atomic(const char *path)
{
    char old[ZSH_PATH_SIZE];
    zep_fs_status_t status;

    status = zep_fs_getcwd(old, sizeof(old));
    if (status != ZEP_FS_OK)
        return status;
    status = (!path || !*path) ? zep_fs_root() : zep_fs_chdir(path);
    if (status != ZEP_FS_OK)
        (void)restore_cwd(old);
    return status;
}

zep_fs_status_t zsh_paths_same_parent(const char *left, const char *right,
                                      char left_leaf[13],
                                      char right_leaf[13], uint8_t *same)
{
    zsh_path_scope_t scope;
    char left_cwd[ZSH_PATH_SIZE];
    char right_cwd[ZSH_PATH_SIZE];
    zep_fs_status_t status;

    if (!same)
        return ZEP_FS_RANGE;
    *same = 0;
    status = zsh_path_enter_parent(left, &scope);
    if (status != ZEP_FS_OK)
        return status;
    strcpy(left_leaf, scope.leaf);
    status = zep_fs_getcwd(left_cwd, sizeof(left_cwd));
    if (zsh_path_leave(&scope) != ZEP_FS_OK && status == ZEP_FS_OK)
        status = ZEP_FS_IO;
    if (status != ZEP_FS_OK)
        return status;

    status = zsh_path_enter_parent(right, &scope);
    if (status != ZEP_FS_OK)
        return status;
    strcpy(right_leaf, scope.leaf);
    status = zep_fs_getcwd(right_cwd, sizeof(right_cwd));
    if (zsh_path_leave(&scope) != ZEP_FS_OK && status == ZEP_FS_OK)
        status = ZEP_FS_IO;
    if (status != ZEP_FS_OK)
        return status;
    *same = (uint8_t)(strcmp(left_cwd, right_cwd) == 0);
    return ZEP_FS_OK;
}
