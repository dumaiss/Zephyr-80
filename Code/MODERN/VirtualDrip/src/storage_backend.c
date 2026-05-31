#define _DEFAULT_SOURCE

#include "storage_backend.h"

#include <errno.h>
#include <stdio.h>
#include <string.h>

#define STORAGE_FILL_CHUNK 4096u

static bool storage_backend_size_is_valid(FILE *file, const char *path)
{
    if (fseek(file, 0, SEEK_END) != 0) {
        perror(path);
        return false;
    }

    long size = ftell(file);
    if (size < 0) {
        perror(path);
        return false;
    }

    if (size != (long)STORAGE_IMAGE_SIZE) {
        fprintf(stderr,
            "Disk image %s has size %ld bytes; expected %u bytes\n",
            path,
            size,
            (unsigned)STORAGE_IMAGE_SIZE);
        return false;
    }

    rewind(file);
    return true;
}

static bool storage_backend_create_image(FILE *file, const char *path)
{
    uint8_t fill[STORAGE_FILL_CHUNK];
    memset(fill, STORAGE_EMPTY_BYTE, sizeof(fill));

    uint32_t remaining = STORAGE_IMAGE_SIZE;
    while (remaining > 0) {
        size_t chunk = remaining < sizeof(fill) ? (size_t)remaining : sizeof(fill);
        if (fwrite(fill, 1, chunk, file) != chunk) {
            fprintf(stderr, "Failed to initialize disk image %s\n", path);
            return false;
        }
        remaining -= (uint32_t)chunk;
    }

    if (fflush(file) != 0) {
        perror(path);
        return false;
    }

    rewind(file);
    return true;
}

void storage_backend_init(StorageBackend *backend)
{
    if (backend == NULL) {
        return;
    }

    backend->file = NULL;
    backend->path = NULL;
}

bool storage_backend_open(StorageBackend *backend, const char *path)
{
    if (backend == NULL || path == NULL || path[0] == '\0') {
        fprintf(stderr, "Storage image path is empty\n");
        return false;
    }

    storage_backend_close(backend);

    FILE *file = fopen(path, "r+b");
    if (file == NULL && errno == ENOENT) {
        file = fopen(path, "w+b");
        if (file == NULL) {
            perror(path);
            return false;
        }
        if (!storage_backend_create_image(file, path)) {
            fclose(file);
            return false;
        }
        printf("Created drive A image %s (%u bytes, fill=0x%02X)\n",
            path,
            (unsigned)STORAGE_IMAGE_SIZE,
            STORAGE_EMPTY_BYTE);
    } else if (file == NULL) {
        perror(path);
        return false;
    } else if (!storage_backend_size_is_valid(file, path)) {
        fclose(file);
        return false;
    }

    backend->file = file;
    backend->path = path;
    printf("Storage drive A image: %s (%u bytes)\n", path, (unsigned)STORAGE_IMAGE_SIZE);
    return true;
}

void storage_backend_close(StorageBackend *backend)
{
    if (backend == NULL) {
        return;
    }

    if (backend->file != NULL) {
        fclose(backend->file);
    }
    backend->file = NULL;
    backend->path = NULL;
}

bool storage_backend_read(StorageBackend *backend, uint32_t lba, uint8_t *data)
{
    if (backend == NULL || backend->file == NULL || data == NULL || lba >= STORAGE_LBA_COUNT) {
        return false;
    }

    long offset = (long)lba * (long)STORAGE_RECORD_SIZE;
    if (fseek(backend->file, offset, SEEK_SET) != 0) {
        perror(storage_backend_path(backend));
        return false;
    }

    size_t read_count = fread(data, 1, STORAGE_RECORD_SIZE, backend->file);
    if (read_count != STORAGE_RECORD_SIZE) {
        if (ferror(backend->file)) {
            perror(storage_backend_path(backend));
        } else {
            fprintf(stderr,
                "Short read from %s at LBA %u: %zu bytes\n",
                storage_backend_path(backend),
                (unsigned)lba,
                read_count);
        }
        return false;
    }

    return true;
}

bool storage_backend_write(StorageBackend *backend, uint32_t lba, const uint8_t *data)
{
    if (backend == NULL || backend->file == NULL || data == NULL || lba >= STORAGE_LBA_COUNT) {
        return false;
    }

    long offset = (long)lba * (long)STORAGE_RECORD_SIZE;
    if (fseek(backend->file, offset, SEEK_SET) != 0) {
        perror(storage_backend_path(backend));
        return false;
    }

    if (fwrite(data, 1, STORAGE_RECORD_SIZE, backend->file) != STORAGE_RECORD_SIZE) {
        perror(storage_backend_path(backend));
        return false;
    }

    if (fflush(backend->file) != 0) {
        perror(storage_backend_path(backend));
        return false;
    }

    return true;
}

const char *storage_backend_path(const StorageBackend *backend)
{
    return backend == NULL || backend->path == NULL ? "" : backend->path;
}
