#ifndef ZEPHYR_SHELL_MOCK_FS_H
#define ZEPHYR_SHELL_MOCK_FS_H

#include <stdint.h>
#include <zephyr/fs.h>

void mock_fs_reset(void);
void mock_fs_add_dir(const char *path);
void mock_fs_add_file(const char *path, uint32_t size, uint8_t seed);
uint8_t mock_fs_exists(const char *path);
uint32_t mock_fs_size(const char *path);
uint8_t mock_fs_byte(const char *path, uint32_t offset);
const char *mock_fs_cwd(void);
void mock_fs_fail_read(uint16_t call, zep_fs_status_t status);
void mock_fs_fail_write(uint16_t call, zep_fs_status_t status);
void mock_fs_fail_readdir(uint16_t call, zep_fs_status_t status);
uint16_t mock_fs_closedir_count(void);

#endif
