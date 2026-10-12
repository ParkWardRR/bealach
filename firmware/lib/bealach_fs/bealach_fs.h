/* Provenance: cairn-esp32-device-firmware @ ead3532, lib/bealach_fs/bealach_fs.h
 * Renamed bealach_* → bealach_* for Bealach. Wire format markers unchanged. */

/*
 * A minimal filesystem abstraction, with an Arduino SD backend for the device
 * and a POSIX backend for host tests.
 *
 * This exists for one reason: the storage layer makes claims that are only
 * worth anything if they are tested. "A torn tail is truncated to the last
 * valid frame with an exact discarded byte count" and "an interrupted seal is
 * completed idempotently at the next boot" are properties about crash
 * behaviour, and they cannot be exercised by compiling for ESP32 and hoping.
 * Behind this interface the same bealach_store.c runs on the device and under a
 * host test that can tear a file mid-frame and re-open it.
 *
 * The surface is deliberately small and synchronous — exactly what the store
 * needs and nothing more. It is not a VFS.
 */

#ifndef BEALACH_FS_H
#define BEALACH_FS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct bealach_file bealach_file_t;
typedef struct bealach_dir  bealach_dir_t;

typedef enum {
    BEALACH_FS_READ,   /* fails if absent */
    BEALACH_FS_WRITE,  /* truncates or creates */
    BEALACH_FS_APPEND, /* creates if absent, writes at the end */
} bealach_fs_mode_t;

/* Mount point prefix, so the POSIX backend can root the tree in a temp dir
 * while the device uses absolute card paths. Pass NULL on the device. */
bool bealach_fs_begin(const char *root);
void bealach_fs_end(void);

bool bealach_fs_mkdir(const char *path);
bool bealach_fs_exists(const char *path);
bool bealach_fs_remove(const char *path);
bool bealach_fs_rmdir(const char *path);

/*
 * Rename, used to move a sealed bundle directory. Must fail rather than
 * overwrite if the destination exists: a sealed bundle is never mutated.
 */
bool bealach_fs_rename(const char *from, const char *to);

bealach_file_t *bealach_fs_open(const char *path, bealach_fs_mode_t mode);

/* Returns bytes transferred, which may be short; callers treat a short count
 * as a failure because the length is always known in advance. */
size_t   bealach_fs_read(bealach_file_t *f, void *buf, size_t len);
size_t   bealach_fs_write(bealach_file_t *f, const void *buf, size_t len);
bool     bealach_fs_seek(bealach_file_t *f, uint64_t offset);
uint64_t bealach_fs_size(bealach_file_t *f);
bool     bealach_fs_flush(bealach_file_t *f);
void     bealach_fs_close(bealach_file_t *f);

/* Size of a path without opening it for I/O. */
bool bealach_fs_file_size(const char *path, uint64_t *size);

bealach_dir_t *bealach_fs_opendir(const char *path);

/*
 * Next entry. `name` receives the basename only — the Arduino core has changed
 * whether name() is absolute between versions, and a store that guessed would
 * build paths like /cairn/bundles//cairn/bundles/X.
 */
bool bealach_fs_readdir(bealach_dir_t *d, char *name, size_t cap, bool *is_dir,
                      uint64_t *size);
void bealach_fs_closedir(bealach_dir_t *d);

/* Total and used bytes, for the free-space floor that protects capture data. */
bool bealach_fs_space(uint64_t *total, uint64_t *used);

#ifdef __cplusplus
}
#endif

#endif /* BEALACH_FS_H */
