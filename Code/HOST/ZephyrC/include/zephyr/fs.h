/* fs.h -- native Zephyr byte-oriented filesystem.
 *
 * This is the C interface to BDOS function 218.  It is deliberately separate
 * from z88dk stdio and CP/M FCBs: names are native 8.3 components, transfers
 * are byte counts, and directories are explicit objects.
 */
#ifndef ZEPHYR_FS_H
#define ZEPHYR_FS_H

#include <zephyr/zephyr.h>

typedef uint8_t zep_fs_handle_t;
typedef uint8_t zep_fs_dir_t;
typedef uint8_t zep_fs_status_t;

/* Function-218 version-1 status values.  These values are ABI, not ZephyrC's
 * generic ZEP_E* results. */
#define ZEP_FS_OK             0x00
#define ZEP_FS_NOT_FOUND      0x40
#define ZEP_FS_END            0x41
#define ZEP_FS_EXISTS         0x42
#define ZEP_FS_BAD_NAME       0x43
#define ZEP_FS_READ_ONLY      0x44
#define ZEP_FS_NO_SPACE       0x45
#define ZEP_FS_NOT_DIR        0x46
#define ZEP_FS_IS_DIR         0x47
#define ZEP_FS_NO_HANDLE      0x48
#define ZEP_FS_STALE          0x49
#define ZEP_FS_RANGE          0x4a
#define ZEP_FS_NO_MEDIA       0x4b
#define ZEP_FS_TRANSPORT      0x4c
#define ZEP_FS_UNKNOWN_WRITE  0x4d
#define ZEP_FS_IO             0x4e
#define ZEP_FS_UNSUPPORTED    0xff

#define ZEP_FS_FLAG_DIRECTORY 0x10

typedef enum {
    ZEP_FS_OPEN_READ = 0,
    ZEP_FS_OPEN_UPDATE = 1,
    ZEP_FS_OPEN_CREATE_NEW = 2,
    ZEP_FS_OPEN_CREATE_ALWAYS = 3
} zep_fs_open_mode_t;

typedef struct {
    uint32_t size;
    uint8_t flags;
} zep_fs_stat_t;

typedef struct {
    char name[13];             /* NAME.EXT plus NUL */
    uint32_t size;
    uint8_t flags;
} zep_fs_dirent_t;

/* File and namespace names are one ordinary NUL-terminated 8.3 component.
 * They never accept drive, USER or directory syntax. */
zep_fs_status_t zep_fs_open(const char *name, zep_fs_open_mode_t mode,
                            zep_fs_handle_t *out);
zep_fs_status_t zep_fs_close(zep_fs_handle_t handle);
zep_fs_status_t zep_fs_read(zep_fs_handle_t handle, void *dst,
                            uint16_t length, uint16_t *actual);
zep_fs_status_t zep_fs_write(zep_fs_handle_t handle, const void *src,
                             uint16_t length, uint16_t *actual);
zep_fs_status_t zep_fs_seek(zep_fs_handle_t handle, uint32_t offset);
zep_fs_status_t zep_fs_tell(zep_fs_handle_t handle, uint32_t *offset);
zep_fs_status_t zep_fs_sync(zep_fs_handle_t handle);
zep_fs_status_t zep_fs_truncate(zep_fs_handle_t handle, uint32_t size);

zep_fs_status_t zep_fs_stat(const char *name, zep_fs_stat_t *out);
zep_fs_status_t zep_fs_delete(const char *name);
zep_fs_status_t zep_fs_rename(const char *old_name, const char *new_name);
zep_fs_status_t zep_fs_mkdir(const char *name);
zep_fs_status_t zep_fs_rmdir(const char *name);

/* CHDIR walks slash-separated 8.3 components.  A leading slash first selects
 * the provider root; "." and ".." are handled as conveniences.  Zephyr-80
 * keeps its writable FS2 tree at that root and mounts the read-only CP/M USER-0
 * recovery volume at /CPM/A. */
zep_fs_status_t zep_fs_chdir(const char *path);
zep_fs_status_t zep_fs_cdup(void);
zep_fs_status_t zep_fs_root(void);
zep_fs_status_t zep_fs_getcwd(char *dst, uint16_t capacity);

/* The native service has one directory iterator.  OPENDIR opens the current
 * directory and CLOSEDIR releases its controller context. */
zep_fs_status_t zep_fs_opendir(zep_fs_dir_t *out);
zep_fs_status_t zep_fs_readdir(zep_fs_dir_t dir, zep_fs_dirent_t *out);
zep_fs_status_t zep_fs_closedir(zep_fs_dir_t dir);

/* Byte counts saturate at UINT32_MAX.  The KiB form remains exact for
 * volumes far larger than FAT32 can represent. */
zep_fs_status_t zep_fs_space(uint32_t *free_bytes, uint32_t *total_bytes);
zep_fs_status_t zep_fs_space_kib(uint32_t *free_kib, uint32_t *total_kib);

#endif
