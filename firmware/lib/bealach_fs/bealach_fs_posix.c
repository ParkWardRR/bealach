/* Provenance: cairn-esp32-device-firmware @ ead3532, lib/bealach_fs/bealach_fs_posix.c
 * Renamed bealach_* → bealach_* for Bealach. Wire format markers unchanged. */

/*
 * POSIX backend, used by the host tests. Empty when building for the device.
 *
 * Paths are rooted under a caller-supplied directory so a test can work in a
 * temp tree while the store keeps using the same absolute card paths it uses on
 * the device. That means the code under test is byte-for-byte the code that
 * ships, rather than a parallel implementation that resembles it.
 */

#ifndef ARDUINO

#include "bealach_fs.h"

#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

struct bealach_file {
    FILE *f;
};

struct bealach_dir {
    DIR  *d;
    char  path[1024];
};

static char s_root[768];

bool bealach_fs_begin(const char *root)
{
    if (root == NULL) {
        s_root[0] = '\0';
        return true;
    }
    snprintf(s_root, sizeof(s_root), "%s", root);
    return mkdir(s_root, 0775) == 0 || errno == EEXIST;
}

void bealach_fs_end(void) { s_root[0] = '\0'; }

/* Join the configured root with a store path. */
static const char *real_path(const char *path)
{
    static char buf[1024];

    if (s_root[0] == '\0') {
        snprintf(buf, sizeof(buf), "%s", path);
    } else {
        snprintf(buf, sizeof(buf), "%s%s", s_root, path);
    }
    return buf;
}

bool bealach_fs_mkdir(const char *path)
{
    const char *p = real_path(path);
    if (mkdir(p, 0775) == 0) return true;
    return errno == EEXIST;
}

bool bealach_fs_exists(const char *path)
{
    struct stat st;
    return stat(real_path(path), &st) == 0;
}

bool bealach_fs_remove(const char *path)
{
    return unlink(real_path(path)) == 0;
}

bool bealach_fs_rmdir(const char *path)
{
    return rmdir(real_path(path)) == 0;
}

bool bealach_fs_rename(const char *from, const char *to)
{
    /* Match the SD backend: refuse to clobber, because a sealed bundle is
     * never mutated and POSIX rename would silently replace the target. */
    if (bealach_fs_exists(to)) return false;

    char from_real[1024];
    snprintf(from_real, sizeof(from_real), "%s", real_path(from));

    return rename(from_real, real_path(to)) == 0;
}

bealach_file_t *bealach_fs_open(const char *path, bealach_fs_mode_t mode)
{
    const char *m = "rb";
    switch (mode) {
    case BEALACH_FS_WRITE:  m = "wb";  break;
    case BEALACH_FS_APPEND: m = "ab";  break;
    case BEALACH_FS_READ:
    default:              m = "rb";  break;
    }

    FILE *f = fopen(real_path(path), m);
    if (f == NULL) return NULL;

    bealach_file_t *h = calloc(1, sizeof(*h));
    if (h == NULL) {
        fclose(f);
        return NULL;
    }
    h->f = f;
    return h;
}

size_t bealach_fs_read(bealach_file_t *f, void *buf, size_t len)
{
    return fread(buf, 1, len, f->f);
}

size_t bealach_fs_write(bealach_file_t *f, const void *buf, size_t len)
{
    return fwrite(buf, 1, len, f->f);
}

bool bealach_fs_seek(bealach_file_t *f, uint64_t offset)
{
    return fseek(f->f, (long)offset, SEEK_SET) == 0;
}

uint64_t bealach_fs_size(bealach_file_t *f)
{
    long here = ftell(f->f);
    fseek(f->f, 0, SEEK_END);
    long end = ftell(f->f);
    fseek(f->f, here, SEEK_SET);
    return (end > 0) ? (uint64_t)end : 0;
}

bool bealach_fs_flush(bealach_file_t *f)
{
    return fflush(f->f) == 0;
}

void bealach_fs_close(bealach_file_t *f)
{
    if (f == NULL) return;
    fclose(f->f);
    free(f);
}

bool bealach_fs_file_size(const char *path, uint64_t *size)
{
    struct stat st;
    if (stat(real_path(path), &st) != 0) return false;
    *size = (uint64_t)st.st_size;
    return true;
}

bealach_dir_t *bealach_fs_opendir(const char *path)
{
    const char *p = real_path(path);

    DIR *d = opendir(p);
    if (d == NULL) return NULL;

    bealach_dir_t *h = calloc(1, sizeof(*h));
    if (h == NULL) {
        closedir(d);
        return NULL;
    }
    h->d = d;
    snprintf(h->path, sizeof(h->path), "%s", p);
    return h;
}

bool bealach_fs_readdir(bealach_dir_t *d, char *name, size_t cap, bool *is_dir,
                      uint64_t *size)
{
    for (;;) {
        struct dirent *e = readdir(d->d);
        if (e == NULL) return false;

        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;

        snprintf(name, cap, "%s", e->d_name);

        char full[2048];
        snprintf(full, sizeof(full), "%s/%s", d->path, e->d_name);

        struct stat st;
        if (stat(full, &st) != 0) continue;

        if (is_dir != NULL) *is_dir = S_ISDIR(st.st_mode);
        if (size != NULL)   *size = (uint64_t)st.st_size;
        return true;
    }
}

void bealach_fs_closedir(bealach_dir_t *d)
{
    if (d == NULL) return;
    closedir(d->d);
    free(d);
}

/*
 * A fixed synthetic capacity rather than the host disk's. The free-space floor
 * is store policy being tested, and a test that behaved differently on a full
 * laptop would be worse than no test.
 */
bool bealach_fs_space(uint64_t *total, uint64_t *used)
{
    *total = 32ULL * 1024 * 1024 * 1024;
    *used  = 1ULL * 1024 * 1024 * 1024;
    return true;
}

#endif /* !ARDUINO */
