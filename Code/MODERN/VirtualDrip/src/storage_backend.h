#ifndef STORAGE_BACKEND_H
#define STORAGE_BACKEND_H

/**
 * @file storage_backend.h
 * Flat CP/M drive-image backend used by Virtual Drip storage packets.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

#define STORAGE_RECORD_SIZE 128u
#define STORAGE_LBA_COUNT 65536u
#define STORAGE_IMAGE_SIZE ((uint32_t)(STORAGE_RECORD_SIZE * STORAGE_LBA_COUNT))
#define STORAGE_EMPTY_BYTE 0xE5u

/** Flat 8 MiB image backing CP/M drive A. */
typedef struct {
    FILE *file;
    const char *path;
} StorageBackend;

void storage_backend_init(StorageBackend *backend);
bool storage_backend_open(StorageBackend *backend, const char *path);
void storage_backend_close(StorageBackend *backend);
bool storage_backend_read(StorageBackend *backend, uint32_t lba, uint8_t *data);
bool storage_backend_write(StorageBackend *backend, uint32_t lba, const uint8_t *data);
const char *storage_backend_path(const StorageBackend *backend);

#endif
