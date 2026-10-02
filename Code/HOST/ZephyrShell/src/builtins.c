#include <string.h>
#include <zephyr/fs.h>
#include "builtins.h"
#include "path.h"
#include "shell.h"

static uint8_t io_buffer[ZSH_IO_SIZE];

#define ZSH_SPACE_SATURATED 0xffffffffUL

static uint8_t eqi(const char *left, const char *right)
{
    char a;
    char b;
    do {
        a = *left++;
        b = *right++;
        if (a >= 'A' && a <= 'Z') a = (char)(a + ('a' - 'A'));
        if (b >= 'A' && b <= 'Z') b = (char)(b + ('a' - 'A'));
        if (a != b) return 0;
    } while (a);
    return 1;
}

static void print_space(uint32_t bytes)
{
    if (bytes == ZSH_SPACE_SATURATED)
        zsh_puts(">=4 GiB");
    else {
        zsh_print_u32(bytes);
        zsh_puts(" bytes");
    }
}

static zep_fs_status_t open_path(const char *path, zep_fs_open_mode_t mode,
                                 zep_fs_handle_t *handle)
{
    zsh_path_scope_t scope;
    zep_fs_status_t status;
    zep_fs_status_t restore;

    status = zsh_path_enter_parent(path, &scope);
    if (status != ZEP_FS_OK)
        return status;
    status = zep_fs_open(scope.leaf, mode, handle);
    restore = zsh_path_leave(&scope);
    if (restore != ZEP_FS_OK) {
        if (status == ZEP_FS_OK)
            (void)zep_fs_close(*handle);
        return restore;
    }
    return status;
}

static zep_fs_status_t stat_component(const char *path, zep_fs_stat_t *info)
{
    zsh_path_scope_t scope;
    zep_fs_status_t status;
    zep_fs_status_t restore;

    status = zsh_path_enter_parent(path, &scope);
    if (status != ZEP_FS_OK)
        return status;
    status = zep_fs_stat(scope.leaf, info);
    restore = zsh_path_leave(&scope);
    return status == ZEP_FS_OK ? restore : status;
}

static zep_fs_status_t directory_path(const char *path, zep_fs_stat_t *info)
{
    char old[ZSH_PATH_SIZE];
    zep_fs_status_t status;
    zep_fs_status_t restore;

    status = zep_fs_getcwd(old, sizeof(old));
    if (status != ZEP_FS_OK)
        return status;
    status = zep_fs_chdir(path);
    restore = zep_fs_chdir(old);
    if (status != ZEP_FS_OK)
        return status;
    if (restore != ZEP_FS_OK)
        return restore;
    info->flags = ZEP_FS_FLAG_DIRECTORY;
    info->size = 0;
    return ZEP_FS_OK;
}

static zep_fs_status_t stat_path(const char *path, zep_fs_stat_t *info)
{
    zep_fs_status_t status = directory_path(path, info);
    if (status == ZEP_FS_OK)
        return status;
    return stat_component(path, info);
}

static zep_fs_status_t resolve_destination_path(const char *source,
                                                const char *destination,
                                                char resolved[ZSH_PATH_SIZE])
{
    char parent[ZSH_PATH_SIZE];
    char leaf[13];
    zep_fs_stat_t info;
    zep_fs_status_t status;
    uint16_t destination_length;
    uint16_t leaf_length;
    uint8_t add_slash;

    status = stat_path(destination, &info);
    if (status != ZEP_FS_OK && status != ZEP_FS_NOT_FOUND)
        return status;
    if (status != ZEP_FS_OK || !(info.flags & ZEP_FS_FLAG_DIRECTORY)) {
        destination_length = (uint16_t)strlen(destination);
        if (destination_length >= ZSH_PATH_SIZE)
            return ZEP_FS_RANGE;
        strcpy(resolved, destination);
        return ZEP_FS_OK;
    }

    status = zsh_path_split(source, parent, sizeof(parent), leaf);
    if (status != ZEP_FS_OK)
        return status;
    destination_length = (uint16_t)strlen(destination);
    leaf_length = (uint16_t)strlen(leaf);
    add_slash = (uint8_t)(destination_length != 0 &&
                          destination[destination_length - 1] != '/');
    if ((uint16_t)(destination_length + add_slash + leaf_length + 1) >
        ZSH_PATH_SIZE)
        return ZEP_FS_RANGE;
    memcpy(resolved, destination, destination_length);
    if (add_slash)
        resolved[destination_length++] = '/';
    memcpy(resolved + destination_length, leaf, leaf_length + 1);
    return ZEP_FS_OK;
}

static zep_fs_status_t remove_path(const char *path)
{
    zsh_path_scope_t scope;
    zep_fs_stat_t info;
    zep_fs_status_t status;
    zep_fs_status_t restore;

    status = zsh_path_enter_parent(path, &scope);
    if (status != ZEP_FS_OK)
        return status;
    status = zep_fs_stat(scope.leaf, &info);
    if (status == ZEP_FS_OK && (info.flags & ZEP_FS_FLAG_DIRECTORY))
        status = ZEP_FS_IS_DIR;
    if (status == ZEP_FS_OK)
        status = zep_fs_delete(scope.leaf);
    restore = zsh_path_leave(&scope);
    return status == ZEP_FS_OK ? restore : status;
}

static zep_fs_status_t namespace_path(const char *path,
                                      zep_fs_status_t (*operation)(const char *))
{
    zsh_path_scope_t scope;
    zep_fs_status_t status;
    zep_fs_status_t restore;

    status = zsh_path_enter_parent(path, &scope);
    if (status != ZEP_FS_OK)
        return status;
    status = operation(scope.leaf);
    restore = zsh_path_leave(&scope);
    return status == ZEP_FS_OK ? restore : status;
}

static zep_fs_status_t copy_regular_file(const char *source,
                                         const char *destination)
{
    char source_leaf[13];
    char destination_leaf[13];
    uint8_t same_parent;
    zep_fs_handle_t input = 0;
    zep_fs_handle_t output = 0;
    zep_fs_status_t status;
    zep_fs_status_t close_status;
    uint16_t got;
    uint16_t put;

    status = zsh_paths_same_parent(source, destination, source_leaf,
                                   destination_leaf, &same_parent);
    if (status != ZEP_FS_OK)
        return status;
    if (same_parent && eqi(source_leaf, destination_leaf))
        return ZEP_FS_EXISTS;
    status = open_path(source, ZEP_FS_OPEN_READ, &input);
    if (status != ZEP_FS_OK)
        return status;
    status = open_path(destination, ZEP_FS_OPEN_CREATE_ALWAYS, &output);
    if (status != ZEP_FS_OK) {
        (void)zep_fs_close(input);
        return status;
    }

    for (;;) {
        got = 0;
        status = zep_fs_read(input, io_buffer, ZSH_IO_SIZE, &got);
        if (status != ZEP_FS_OK)
            break;
        if (got != 0) {
            put = 0;
            status = zep_fs_write(output, io_buffer, got, &put);
            if (status != ZEP_FS_OK)
                break;
            if (put != got) {
                status = ZEP_FS_IO;
                break;
            }
        }
        if (got != ZSH_IO_SIZE)
            break;
    }

    close_status = zep_fs_close(output);
    if (status == ZEP_FS_OK && close_status != ZEP_FS_OK)
        status = close_status;
    close_status = zep_fs_close(input);
    if (status == ZEP_FS_OK && close_status != ZEP_FS_OK)
        status = close_status;
    return status;
}

zep_fs_status_t zsh_copy_file(const char *source, const char *destination)
{
    char resolved[ZSH_PATH_SIZE];
    zep_fs_stat_t info;
    zep_fs_status_t status;

    status = stat_path(source, &info);
    if (status != ZEP_FS_OK)
        return status;
    if (info.flags & ZEP_FS_FLAG_DIRECTORY)
        return ZEP_FS_IS_DIR;
    status = resolve_destination_path(source, destination, resolved);
    if (status != ZEP_FS_OK)
        return status;
    return copy_regular_file(source, resolved);
}

zep_fs_status_t zsh_move_file(const char *source, const char *destination)
{
    char resolved[ZSH_PATH_SIZE];
    char source_leaf[13];
    char destination_leaf[13];
    uint8_t same;
    zsh_path_scope_t scope;
    zep_fs_stat_t info;
    zep_fs_status_t status;
    zep_fs_status_t restore;

    status = stat_path(source, &info);
    if (status != ZEP_FS_OK)
        return status;
    status = resolve_destination_path(source, destination, resolved);
    if (status != ZEP_FS_OK)
        return status;
    status = zsh_paths_same_parent(source, resolved, source_leaf,
                                   destination_leaf, &same);
    if (status != ZEP_FS_OK)
        return status;
    if (same) {
        if (eqi(source_leaf, destination_leaf))
            return ZEP_FS_OK;
        status = zsh_path_enter_parent(source, &scope);
        if (status != ZEP_FS_OK)
            return status;
        status = zep_fs_rename(source_leaf, destination_leaf);
        restore = zsh_path_leave(&scope);
        return status == ZEP_FS_OK ? restore : status;
    }
    if (info.flags & ZEP_FS_FLAG_DIRECTORY)
        return ZEP_FS_UNSUPPORTED;
    status = copy_regular_file(source, resolved);
    if (status != ZEP_FS_OK)
        return status;
    return remove_path(source);
}

static void print_entry(const char *name, const zep_fs_stat_t *info,
                        uint8_t long_form)
{
    uint8_t is_dir = (uint8_t)(info->flags & ZEP_FS_FLAG_DIRECTORY);
    if (long_form) {
        zsh_putc(is_dir ? 'd' : '-');
        zsh_putc(' ');
        zsh_print_u32(info->size);
        zsh_putc(' ');
    }
    zsh_puts(name);
    if (is_dir) zsh_putc('/');
    zsh_putc('\n');
}

static zep_fs_status_t list_current(uint8_t long_form)
{
    zep_fs_dir_t dir;
    zep_fs_dirent_t entry;
    zep_fs_stat_t info;
    zep_fs_status_t status;
    zep_fs_status_t close_status;

    status = zep_fs_opendir(&dir);
    if (status != ZEP_FS_OK)
        return status;
    for (;;) {
        status = zep_fs_readdir(dir, &entry);
        if (status == ZEP_FS_END) {
            status = ZEP_FS_OK;
            break;
        }
        if (status != ZEP_FS_OK)
            break;
        info.size = entry.size;
        info.flags = entry.flags;
        print_entry(entry.name, &info, long_form);
    }
    close_status = zep_fs_closedir(dir);
    return status == ZEP_FS_OK ? close_status : status;
}

zep_fs_status_t zsh_list_path(const char *path, uint8_t long_form)
{
    char old[ZSH_PATH_SIZE];
    zep_fs_stat_t info;
    zep_fs_status_t status;
    zep_fs_status_t restore;

    if (!path)
        return list_current(long_form);
    status = zep_fs_getcwd(old, sizeof(old));
    if (status != ZEP_FS_OK)
        return status;
    status = zep_fs_chdir(path);
    if (status == ZEP_FS_OK) {
        status = list_current(long_form);
        restore = zep_fs_chdir(old);
        return status == ZEP_FS_OK ? restore : status;
    }
    (void)zep_fs_chdir(old);
    status = stat_component(path, &info);
    if (status == ZEP_FS_OK)
        print_entry(path, &info, long_form);
    return status;
}

static void usage(const char *text)
{
    zsh_puts("usage: "); zsh_puts(text); zsh_putc('\n');
}

static void builtin_help(void)
{
    zsh_puts("cd [path]       change native directory (default /)\n");
    zsh_puts("pwd             print native directory\n");
    zsh_puts("ls [-l] [path]  list directory (alias: dir)\n");
    zsh_puts("cp SRC DST      copy a regular file\n");
    zsh_puts("mv SRC DST      rename or move a regular file\n");
    zsh_puts("rm FILE...      remove regular files (alias: del)\n");
    zsh_puts("mkdir PATH      create directory (alias: md)\n");
    zsh_puts("rmdir PATH      remove empty directory (alias: rd)\n");
    zsh_puts("cat FILE...     print files (alias: type)\n");
    zsh_puts("stat PATH       show type and byte size\n");
    zsh_puts("df              show native volume space in KiB\n");
    zsh_puts("echo [ARGS...]  print arguments\n");
    zsh_puts("help            show this summary\n");
    zsh_puts("keys: Ctrl-L clear, Up recall last command\n");
}

static int builtin_cat(uint8_t argc, char **argv)
{
    zep_fs_handle_t handle;
    zep_fs_status_t status;
    zep_fs_status_t close_status;
    uint16_t got;
    uint16_t i;
    uint8_t arg;

    if (argc < 2) {
        usage("cat FILE [FILE ...]");
        return 1;
    }
    for (arg = 1; arg < argc; ++arg) {
        status = open_path(argv[arg], ZEP_FS_OPEN_READ, &handle);
        if (status != ZEP_FS_OK) {
            zsh_error_status("cat", argv[arg], status);
            continue;
        }
        do {
            got = 0;
            status = zep_fs_read(handle, io_buffer, ZSH_IO_SIZE, &got);
            if (status != ZEP_FS_OK)
                break;
            for (i = 0; i < got; ++i)
                zsh_putc(io_buffer[i]);
        } while (got == ZSH_IO_SIZE);
        close_status = zep_fs_close(handle);
        if (status == ZEP_FS_OK)
            status = close_status;
        if (status != ZEP_FS_OK)
            zsh_error_status("cat", argv[arg], status);
    }
    return 1;
}

int zsh_builtin_dispatch(uint8_t argc, char **argv)
{
    char cwd[ZSH_PATH_SIZE];
    zep_fs_stat_t info;
    zep_fs_status_t status;
    uint32_t free_space;
    uint32_t total_space;
    uint8_t space_is_kib;
    uint8_t i;
    uint8_t long_form;
    const char *path;

    if (eqi(argv[0], "help")) {
        builtin_help();
    } else if (eqi(argv[0], "echo")) {
        for (i = 1; i < argc; ++i) {
            if (i != 1) zsh_putc(' ');
            zsh_puts(argv[i]);
        }
        zsh_putc('\n');
    } else if (eqi(argv[0], "pwd")) {
        if (argc != 1) usage("pwd");
        else if ((status = zep_fs_getcwd(cwd, sizeof(cwd))) != ZEP_FS_OK)
            zsh_error_status("pwd", 0, status);
        else { zsh_puts(cwd); zsh_putc('\n'); }
    } else if (eqi(argv[0], "cd")) {
        if (argc > 2) usage("cd [path]");
        else if ((status = zsh_path_chdir_atomic(argc == 1 ? "/" : argv[1])) != ZEP_FS_OK)
            zsh_error_status("cd", argc == 1 ? "/" : argv[1], status);
    } else if (eqi(argv[0], "ls") || eqi(argv[0], "dir")) {
        long_form = 0;
        path = 0;
        for (i = 1; i < argc; ++i) {
            if (eqi(argv[i], "-l")) long_form = 1;
            else if (!path) path = argv[i];
            else { usage("ls [-l] [path]"); return 1; }
        }
        status = zsh_list_path(path, long_form);
        if (status != ZEP_FS_OK) zsh_error_status("ls", path, status);
    } else if (eqi(argv[0], "cp")) {
        if (argc != 3) usage("cp SOURCE DESTINATION");
        else if ((status = zsh_copy_file(argv[1], argv[2])) != ZEP_FS_OK)
            zsh_error_status("cp", argv[2], status);
    } else if (eqi(argv[0], "mv")) {
        if (argc != 3) usage("mv SOURCE DESTINATION");
        else if ((status = zsh_move_file(argv[1], argv[2])) != ZEP_FS_OK)
            zsh_error_status("mv", argv[2], status);
    } else if (eqi(argv[0], "rm") || eqi(argv[0], "del")) {
        if (argc < 2) usage("rm FILE [FILE ...]");
        else for (i = 1; i < argc; ++i)
            if ((status = remove_path(argv[i])) != ZEP_FS_OK)
                zsh_error_status("rm", argv[i], status);
    } else if (eqi(argv[0], "mkdir") || eqi(argv[0], "md")) {
        if (argc != 2) usage("mkdir PATH");
        else if ((status = namespace_path(argv[1], zep_fs_mkdir)) != ZEP_FS_OK)
            zsh_error_status("mkdir", argv[1], status);
    } else if (eqi(argv[0], "rmdir") || eqi(argv[0], "rd")) {
        if (argc != 2) usage("rmdir PATH");
        else if ((status = namespace_path(argv[1], zep_fs_rmdir)) != ZEP_FS_OK)
            zsh_error_status("rmdir", argv[1], status);
    } else if (eqi(argv[0], "cat") || eqi(argv[0], "type")) {
        return builtin_cat(argc, argv);
    } else if (eqi(argv[0], "stat")) {
        if (argc != 2) usage("stat PATH");
        else if ((status = stat_path(argv[1], &info)) != ZEP_FS_OK)
            zsh_error_status("stat", argv[1], status);
        else {
            zsh_puts("name: "); zsh_puts(argv[1]);
            zsh_puts("\ntype: ");
            zsh_puts((info.flags & ZEP_FS_FLAG_DIRECTORY) ? "directory" : "file");
            zsh_puts("\nsize: "); zsh_print_u32(info.size); zsh_putc('\n');
        }
    } else if (eqi(argv[0], "df")) {
        if (argc != 1) usage("df");
        else {
            space_is_kib = 1;
            status = zep_fs_space_kib(&free_space, &total_space);
            if (status == ZEP_FS_UNSUPPORTED) {
                space_is_kib = 0;
                status = zep_fs_space(&free_space, &total_space);
            }
            if (status != ZEP_FS_OK)
                zsh_error_status("df", 0, status);
            else if (space_is_kib) {
                zsh_print_u32(free_space); zsh_puts(" KiB free / ");
                zsh_print_u32(total_space); zsh_puts(" KiB total\n");
            } else {
                print_space(free_space); zsh_puts(" free / ");
                print_space(total_space); zsh_puts(" total");
                if (free_space == ZSH_SPACE_SATURATED ||
                    total_space == ZSH_SPACE_SATURATED)
                    zsh_puts(" (32-bit API limit)");
                zsh_putc('\n');
            }
        }
    } else {
        return 0;
    }
    return 1;
}
