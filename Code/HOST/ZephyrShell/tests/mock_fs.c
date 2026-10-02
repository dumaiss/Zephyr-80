#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zephyr/fs.h>
#include "mock_fs.h"

#define MOCK_NODES 32
#define MOCK_HANDLES 2
#define MOCK_PATH 208

typedef struct {
    uint8_t used;
    uint8_t flags;
    char path[MOCK_PATH];
    uint8_t *data;
    uint32_t size;
    uint32_t capacity;
} mock_node_t;

typedef struct {
    mock_node_t *node;
    uint32_t position;
    uint8_t writable;
} mock_handle_t;

static mock_node_t nodes[MOCK_NODES];
static mock_handle_t handles[MOCK_HANDLES];
static char current[MOCK_PATH];
static uint8_t dir_open;
static uint16_t dir_index;
static uint16_t read_calls;
static uint16_t write_calls;
static uint16_t readdir_calls;
static uint16_t closedir_calls;
static uint16_t fail_read_call;
static uint16_t fail_write_call;
static uint16_t fail_readdir_call;
static zep_fs_status_t fail_read_status;
static zep_fs_status_t fail_write_status;
static zep_fs_status_t fail_readdir_status;

static mock_node_t *find_node(const char *path)
{
    uint8_t i;
    for (i = 0; i < MOCK_NODES; ++i)
        if (nodes[i].used && strcmp(nodes[i].path, path) == 0)
            return &nodes[i];
    return 0;
}

static mock_node_t *new_node(const char *path, uint8_t flags)
{
    uint8_t i;
    mock_node_t *node = find_node(path);
    if (node)
        return node;
    for (i = 0; i < MOCK_NODES; ++i) {
        if (!nodes[i].used) {
            nodes[i].used = 1;
            nodes[i].flags = flags;
            strcpy(nodes[i].path, path);
            return &nodes[i];
        }
    }
    abort();
}

static void component_path(const char *name, char out[MOCK_PATH])
{
    size_t n = strlen(current);
    size_t m = strlen(name);
    if (n + m + 2 > MOCK_PATH) abort();
    strcpy(out, current);
    if (n != 1) out[n++] = '/';
    memcpy(out + n, name, m + 1);
}

static void parent_of(const char *path, char out[MOCK_PATH])
{
    const char *slash = strrchr(path, '/');
    size_t n;
    if (!slash || slash == path) {
        strcpy(out, "/");
        return;
    }
    n = (size_t)(slash - path);
    memcpy(out, path, n);
    out[n] = 0;
}

void mock_fs_reset(void)
{
    uint8_t i;
    for (i = 0; i < MOCK_NODES; ++i) {
        free(nodes[i].data);
        memset(&nodes[i], 0, sizeof(nodes[i]));
    }
    memset(handles, 0, sizeof(handles));
    strcpy(current, "/");
    dir_open = 0;
    dir_index = 0;
    read_calls = write_calls = readdir_calls = closedir_calls = 0;
    fail_read_call = fail_write_call = fail_readdir_call = 0;
    fail_read_status = fail_write_status = fail_readdir_status = ZEP_FS_OK;
    (void)new_node("/", ZEP_FS_FLAG_DIRECTORY);
}

void mock_fs_add_dir(const char *path)
{
    (void)new_node(path, ZEP_FS_FLAG_DIRECTORY);
}

void mock_fs_add_file(const char *path, uint32_t size, uint8_t seed)
{
    uint32_t i;
    mock_node_t *node = new_node(path, 0);
    free(node->data);
    node->data = size ? (uint8_t *)malloc((size_t)size) : 0;
    node->size = node->capacity = size;
    for (i = 0; i < size; ++i)
        node->data[i] = (uint8_t)(seed + (uint8_t)i);
}

uint8_t mock_fs_exists(const char *path) { return find_node(path) != 0; }
uint32_t mock_fs_size(const char *path) { return find_node(path)->size; }
uint8_t mock_fs_byte(const char *path, uint32_t offset) { return find_node(path)->data[offset]; }
const char *mock_fs_cwd(void) { return current; }
void mock_fs_fail_read(uint16_t call, zep_fs_status_t status) { fail_read_call = call; fail_read_status = status; }
void mock_fs_fail_write(uint16_t call, zep_fs_status_t status) { fail_write_call = call; fail_write_status = status; }
void mock_fs_fail_readdir(uint16_t call, zep_fs_status_t status) { fail_readdir_call = call; fail_readdir_status = status; }
uint16_t mock_fs_closedir_count(void) { return closedir_calls; }

zep_fs_status_t zep_fs_root(void) { strcpy(current, "/"); return ZEP_FS_OK; }

zep_fs_status_t zep_fs_cdup(void)
{
    char parent[MOCK_PATH];
    parent_of(current, parent);
    strcpy(current, parent);
    return ZEP_FS_OK;
}

zep_fs_status_t zep_fs_chdir(const char *path)
{
    char component[13];
    char next[MOCK_PATH];
    const char *p = path;
    uint8_t n;
    mock_node_t *node;
    if (!path || !*path) return ZEP_FS_BAD_NAME;
    if (*p == '/') { strcpy(current, "/"); while (*p == '/') ++p; }
    while (*p) {
        n = 0;
        while (*p && *p != '/') {
            if (n == 12) return ZEP_FS_BAD_NAME;
            component[n++] = *p++;
        }
        component[n] = 0;
        while (*p == '/') ++p;
        if (strcmp(component, ".") == 0) continue;
        if (strcmp(component, "..") == 0) { (void)zep_fs_cdup(); continue; }
        component_path(component, next);
        node = find_node(next);
        if (!node) return ZEP_FS_NOT_FOUND;
        if (!(node->flags & ZEP_FS_FLAG_DIRECTORY)) return ZEP_FS_NOT_DIR;
        strcpy(current, next);
    }
    return ZEP_FS_OK;
}

zep_fs_status_t zep_fs_getcwd(char *dst, uint16_t capacity)
{
    size_t n = strlen(current) + 1;
    if (!dst || n > capacity) return ZEP_FS_RANGE;
    memcpy(dst, current, n);
    return ZEP_FS_OK;
}

zep_fs_status_t zep_fs_stat(const char *name, zep_fs_stat_t *out)
{
    char path[MOCK_PATH];
    mock_node_t *node;
    component_path(name, path);
    node = find_node(path);
    if (!node) return ZEP_FS_NOT_FOUND;
    out->size = node->size;
    out->flags = node->flags;
    return ZEP_FS_OK;
}

zep_fs_status_t zep_fs_open(const char *name, zep_fs_open_mode_t mode,
                            zep_fs_handle_t *out)
{
    char path[MOCK_PATH];
    mock_node_t *node;
    uint8_t i;
    component_path(name, path);
    node = find_node(path);
    if (mode == ZEP_FS_OPEN_READ) {
        if (!node) return ZEP_FS_NOT_FOUND;
        if (node->flags & ZEP_FS_FLAG_DIRECTORY) return ZEP_FS_IS_DIR;
    } else {
        if (node && (node->flags & ZEP_FS_FLAG_DIRECTORY)) return ZEP_FS_IS_DIR;
        if (mode == ZEP_FS_OPEN_CREATE_NEW && node) return ZEP_FS_EXISTS;
        if (!node) node = new_node(path, 0);
        if (mode == ZEP_FS_OPEN_CREATE_ALWAYS) node->size = 0;
    }
    for (i = 0; i < MOCK_HANDLES; ++i) {
        if (!handles[i].node) {
            handles[i].node = node;
            handles[i].position = 0;
            handles[i].writable = mode != ZEP_FS_OPEN_READ;
            *out = (zep_fs_handle_t)(i + 1);
            return ZEP_FS_OK;
        }
    }
    return ZEP_FS_NO_HANDLE;
}

zep_fs_status_t zep_fs_close(zep_fs_handle_t handle)
{
    if (!handle || handle > MOCK_HANDLES || !handles[handle - 1].node)
        return ZEP_FS_NO_HANDLE;
    handles[handle - 1].node = 0;
    return ZEP_FS_OK;
}

zep_fs_status_t zep_fs_read(zep_fs_handle_t handle, void *dst,
                            uint16_t length, uint16_t *actual)
{
    mock_handle_t *h;
    uint32_t remain;
    uint16_t count;
    ++read_calls;
    if (actual) *actual = 0;
    if (fail_read_call == read_calls) return fail_read_status;
    if (!handle || handle > MOCK_HANDLES || !(h = &handles[handle - 1])->node)
        return ZEP_FS_NO_HANDLE;
    remain = h->node->size - h->position;
    count = remain < length ? (uint16_t)remain : length;
    if (count) memcpy(dst, h->node->data + h->position, count);
    h->position += count;
    if (actual) *actual = count;
    return ZEP_FS_OK;
}

zep_fs_status_t zep_fs_write(zep_fs_handle_t handle, const void *src,
                             uint16_t length, uint16_t *actual)
{
    mock_handle_t *h;
    uint32_t needed;
    uint8_t *data;
    ++write_calls;
    if (actual) *actual = 0;
    if (fail_write_call == write_calls) return fail_write_status;
    if (!handle || handle > MOCK_HANDLES || !(h = &handles[handle - 1])->node)
        return ZEP_FS_NO_HANDLE;
    needed = h->position + length;
    if (needed > h->node->capacity) {
        data = (uint8_t *)realloc(h->node->data, (size_t)needed);
        if (!data) return ZEP_FS_NO_SPACE;
        h->node->data = data;
        h->node->capacity = needed;
    }
    memcpy(h->node->data + h->position, src, length);
    h->position += length;
    if (h->position > h->node->size) h->node->size = h->position;
    if (actual) *actual = length;
    return ZEP_FS_OK;
}

zep_fs_status_t zep_fs_delete(const char *name)
{
    char path[MOCK_PATH];
    mock_node_t *node;
    component_path(name, path);
    node = find_node(path);
    if (!node) return ZEP_FS_NOT_FOUND;
    if (node->flags & ZEP_FS_FLAG_DIRECTORY) return ZEP_FS_IS_DIR;
    free(node->data);
    memset(node, 0, sizeof(*node));
    return ZEP_FS_OK;
}

zep_fs_status_t zep_fs_rename(const char *old_name, const char *new_name)
{
    char old_path[MOCK_PATH];
    char new_path[MOCK_PATH];
    mock_node_t *node;
    component_path(old_name, old_path);
    component_path(new_name, new_path);
    node = find_node(old_path);
    if (!node) return ZEP_FS_NOT_FOUND;
    if (find_node(new_path)) return ZEP_FS_EXISTS;
    strcpy(node->path, new_path);
    return ZEP_FS_OK;
}

zep_fs_status_t zep_fs_mkdir(const char *name)
{
    char path[MOCK_PATH];
    component_path(name, path);
    if (find_node(path)) return ZEP_FS_EXISTS;
    (void)new_node(path, ZEP_FS_FLAG_DIRECTORY);
    return ZEP_FS_OK;
}

zep_fs_status_t zep_fs_rmdir(const char *name)
{
    char path[MOCK_PATH];
    size_t n;
    uint8_t i;
    mock_node_t *node;
    component_path(name, path);
    node = find_node(path);
    if (!node) return ZEP_FS_NOT_FOUND;
    if (!(node->flags & ZEP_FS_FLAG_DIRECTORY)) return ZEP_FS_NOT_DIR;
    n = strlen(path);
    for (i = 0; i < MOCK_NODES; ++i)
        if (nodes[i].used && strncmp(nodes[i].path, path, n) == 0 &&
            nodes[i].path[n] == '/') return ZEP_FS_IO;
    memset(node, 0, sizeof(*node));
    return ZEP_FS_OK;
}

zep_fs_status_t zep_fs_opendir(zep_fs_dir_t *out)
{
    if (dir_open) return ZEP_FS_NO_HANDLE;
    dir_open = 1; dir_index = 0; *out = 1; return ZEP_FS_OK;
}

zep_fs_status_t zep_fs_readdir(zep_fs_dir_t dir, zep_fs_dirent_t *out)
{
    size_t prefix = strcmp(current, "/") == 0 ? 1 : strlen(current) + 1;
    const char *name;
    ++readdir_calls;
    if (fail_readdir_call == readdir_calls) return fail_readdir_status;
    if (dir != 1 || !dir_open) return ZEP_FS_NO_HANDLE;
    while (dir_index < MOCK_NODES) {
        mock_node_t *node = &nodes[dir_index++];
        if (!node->used || strcmp(node->path, "/") == 0) continue;
        if (strncmp(node->path, current, strlen(current)) != 0) continue;
        name = node->path + prefix;
        if (!*name || strchr(name, '/')) continue;
        strncpy(out->name, name, sizeof(out->name));
        out->name[sizeof(out->name) - 1] = 0;
        out->size = node->size;
        out->flags = node->flags;
        return ZEP_FS_OK;
    }
    return ZEP_FS_END;
}

zep_fs_status_t zep_fs_closedir(zep_fs_dir_t dir)
{
    if (dir != 1 || !dir_open) return ZEP_FS_NO_HANDLE;
    dir_open = 0; ++closedir_calls; return ZEP_FS_OK;
}

zep_fs_status_t zep_fs_space(uint32_t *free_bytes, uint32_t *total_bytes)
{ *free_bytes = 1000; *total_bytes = 2000; return ZEP_FS_OK; }
zep_fs_status_t zep_fs_space_kib(uint32_t *free_kib, uint32_t *total_kib)
{ *free_kib = 100; *total_kib = 200; return ZEP_FS_OK; }
zep_fs_status_t zep_fs_seek(zep_fs_handle_t h, uint32_t p) { (void)h; (void)p; return ZEP_FS_UNSUPPORTED; }
zep_fs_status_t zep_fs_tell(zep_fs_handle_t h, uint32_t *p) { (void)h; (void)p; return ZEP_FS_UNSUPPORTED; }
zep_fs_status_t zep_fs_sync(zep_fs_handle_t h) { (void)h; return ZEP_FS_OK; }
zep_fs_status_t zep_fs_truncate(zep_fs_handle_t h, uint32_t s) { (void)h; (void)s; return ZEP_FS_UNSUPPORTED; }
