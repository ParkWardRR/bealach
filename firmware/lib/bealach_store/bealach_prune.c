/* Provenance: cairn-esp32-device-firmware @ ead3532, lib/bealach_store/bealach_prune.c
 * Renamed bealach_* → bealach_* for Bealach. Wire format markers unchanged. */

#include "bealach_prune.h"

#include <stdio.h>
#include <string.h>

#include "board_config.h"
#include "bealach_format.h"
#include "bealach_fs.h"
#include "bealach_log.h"
#include "bealach_store.h"

static const char *TAG = "PRUNE";

#define PATH_MAX_LEN 192

const char *bealach_prune_result_name(bealach_prune_result_t r)
{
    switch (r) {
    case BEALACH_PRUNE_OK:                  return "OK";
    case BEALACH_PRUNE_RECEIPT_MALFORMED:   return "RECEIPT_MALFORMED";
    case BEALACH_PRUNE_RECEIPT_UNVERIFIED:  return "RECEIPT_UNVERIFIED";
    case BEALACH_PRUNE_WRONG_BUNDLE:        return "WRONG_BUNDLE";
    case BEALACH_PRUNE_NO_PINNED_KEY:       return "NO_PINNED_KEY";
    case BEALACH_PRUNE_STORE_FAILED:        return "STORE_FAILED";
    default:                              return "UNKNOWN";
    }
}

static void tohex(const uint8_t *b, size_t len, char *out)
{
    static const char *d = "0123456789abcdef";
    for (size_t i = 0; i < len; i++) {
        out[i * 2]     = d[b[i] >> 4];
        out[i * 2 + 1] = d[b[i] & 0x0f];
    }
    out[len * 2] = '\0';
}

/* ── receipts ─────────────────────────────────────────────────────────────── */

static void receipt_path(const char *id_text, char *out, size_t cap)
{
    snprintf(out, cap, "%s/%s.cbor", BEALACH_DIR_RECEIPTS, id_text);
}

bool bealach_receipt_store(const char *id_text, const uint8_t *receipt,
                         size_t receipt_len)
{
    char path[PATH_MAX_LEN];
    receipt_path(id_text, path, sizeof(path));

    bealach_file_t *f = bealach_fs_open(path, BEALACH_FS_WRITE);
    if (f == NULL) return false;

    size_t n = bealach_fs_write(f, receipt, receipt_len);
    bealach_fs_flush(f);
    bealach_fs_close(f);

    return n == receipt_len;
}

bool bealach_receipt_exists(const char *id_text)
{
    char path[PATH_MAX_LEN];
    receipt_path(id_text, path, sizeof(path));
    return bealach_fs_exists(path);
}

/* ── the prune journal ───────────────────────────────────────────────────── */

static void journal_path(const char *id_text, char *out, size_t cap)
{
    snprintf(out, cap, "%s/prune-%s.json", BEALACH_DIR_STATE, id_text);
}

/*
 * The intent names the bundle and the content root its receipt acknowledged,
 * and is flushed before the first delete. That ordering is the whole point: it
 * converts "some files are missing" into "a prune was authorized and is
 * incomplete", which is a recoverable state rather than an ambiguous one.
 */
static bool intent_write(const char *id_text, const uint8_t root[32])
{
    char path[PATH_MAX_LEN], root_hex[65];
    journal_path(id_text, path, sizeof(path));
    tohex(root, 32, root_hex);

    bealach_file_t *f = bealach_fs_open(path, BEALACH_FS_WRITE);
    if (f == NULL) return false;

    char line[256];
    int  n = snprintf(line, sizeof(line),
                      "{\"bundle\":\"%s\",\"content_root\":\"%s\","
                      "\"state\":\"intent\"}\n",
                      id_text, root_hex);

    size_t written = bealach_fs_write(f, line, (size_t)n);
    bealach_fs_flush(f);
    bealach_fs_close(f);

    return written == (size_t)n;
}

static void intent_clear(const char *id_text)
{
    char path[PATH_MAX_LEN];
    journal_path(id_text, path, sizeof(path));
    bealach_fs_remove(path);
}

/* ── deletion ─────────────────────────────────────────────────────────────── */

static bool delete_bundle_dir(const char *id_text)
{
    char dir[PATH_MAX_LEN];
    snprintf(dir, sizeof(dir), "%s/%s", BEALACH_DIR_BUNDLES, id_text);

    bealach_dir_t *d = bealach_fs_opendir(dir);
    if (d == NULL) return false;

    /* Collect names first: removing while iterating invalidates the iterator. */
    char   names[BEALACH_MAX_MEMBERS + 4][64];
    size_t count = 0;
    char   name[64];
    bool   is_dir = false;

    while (bealach_fs_readdir(d, name, sizeof(name), &is_dir, NULL)) {
        if (!is_dir && count < sizeof(names) / sizeof(names[0])) {
            snprintf(names[count], sizeof(names[0]), "%s", name);
            count++;
        }
    }
    bealach_fs_closedir(d);

    for (size_t i = 0; i < count; i++) {
        char path[PATH_MAX_LEN + 64];
        snprintf(path, sizeof(path), "%s/%s", dir, names[i]);
        if (!bealach_fs_remove(path)) {
            BEALACH_LOGE(TAG, "cannot remove %s", path);
            return false;
        }
    }

    return bealach_fs_rmdir(dir);
}

/* ── dropping bundles no reader can accept ────────────────────────────────── */

/*
 * The manifest version, read from the first few bytes, or -1 when it cannot be
 * established.
 *
 * A deliberate peek rather than bealach_manifest_decode, because the whole point
 * is to classify manifests the decoder *refuses*. The encoding makes this safe
 * to do by hand: the manifest is a canonical CBOR map whose first key is 1,
 * manifest_version, encoded as a small unsigned integer. Anything that does not
 * match that shape exactly returns -1 and is left alone.
 */
static int manifest_version_of(const char *dir)
{
    char path[PATH_MAX_LEN];
    snprintf(path, sizeof(path), "%s/manifest.cbor", dir);

    bealach_file_t *f = bealach_fs_open(path, BEALACH_FS_READ);
    if (f == NULL) return -1;

    uint8_t h[4] = { 0, 0, 0, 0 };
    size_t  got  = bealach_fs_read(f, h, sizeof(h));
    bealach_fs_close(f);
    if (got < sizeof(h)) return -1;

    if ((h[0] & 0xe0) != 0xa0) return -1;        /* major type 5, a map */

    size_t i = 1;
    if ((h[0] & 0x1f) == 24) i = 2;              /* pair count in the next byte */
    else if ((h[0] & 0x1f) > 24) return -1;      /* a larger count: not ours */

    if (h[i] != 0x01) return -1;                 /* first key must be 1 */
    if (h[i + 1] > 0x17) return -1;              /* must be a small uint */

    return (int)h[i + 1];
}

static uint64_t bundle_dir_bytes(const char *dir)
{
    bealach_dir_t *d = bealach_fs_opendir(dir);
    if (d == NULL) return 0;

    uint64_t total = 0;
    char     name[64];
    bool     is_dir = false;
    uint64_t size   = 0;

    while (bealach_fs_readdir(d, name, sizeof(name), &is_dir, &size)) {
        if (!is_dir) total += size;
    }
    bealach_fs_closedir(d);
    return total;
}

bool bealach_prune_legacy_bundles(uint32_t *dropped, uint64_t *bytes_freed)
{
    if (dropped != NULL)     *dropped = 0;
    if (bytes_freed != NULL) *bytes_freed = 0;

    bealach_dir_t *d = bealach_fs_opendir(BEALACH_DIR_BUNDLES);
    if (d == NULL) return false;

    /* Names first: removing while iterating invalidates the iterator. */
    char   ids[32][28];
    size_t count = 0;
    char   name[64];
    bool   is_dir = false;

    while (count < sizeof(ids) / sizeof(ids[0]) &&
           bealach_fs_readdir(d, name, sizeof(name), &is_dir, NULL)) {
        if (!is_dir || strlen(name) != 26) continue;
        snprintf(ids[count], sizeof(ids[0]), "%s", name);
        count++;
    }
    bealach_fs_closedir(d);

    for (size_t i = 0; i < count; i++) {
        char dir[PATH_MAX_LEN];
        snprintf(dir, sizeof(dir), "%s/%s", BEALACH_DIR_BUNDLES, ids[i]);

        int v = manifest_version_of(dir);

        /*
         * Only a version this firmware positively read AND that is older than
         * the one it writes. An unreadable shape (-1) is left alone: it might
         * be a torn write worth recovering, and this command must never become
         * a way to delete data that a receipt could still redeem.
         */
        if (v < 0 || v >= BEALACH_MANIFEST_VERSION) continue;

        uint64_t bytes = bundle_dir_bytes(dir);

        if (!delete_bundle_dir(ids[i])) {
            BEALACH_LOGE(TAG, "could not drop legacy bundle %s", ids[i]);
            continue;
        }

        BEALACH_LOGW(TAG, "dropped %s: manifest version %d, which no reader here "
                        "or on the server accepts (%llu bytes)",
                   ids[i], v, (unsigned long long)bytes);

        if (dropped != NULL)     (*dropped)++;
        if (bytes_freed != NULL) *bytes_freed += bytes;
    }

    return true;
}

/* ── the gate ─────────────────────────────────────────────────────────────── */

static bool key_is_usable(const uint8_t key[32])
{
    if (key == NULL) return false;

    for (int i = 0; i < 32; i++) {
        if (key[i] != 0) return true;
    }
    return false; /* all-zero placeholder verifies nothing */
}

bealach_prune_result_t bealach_receipt_check(const uint8_t *receipt, size_t receipt_len,
                                         const uint8_t pinned_key[32],
                                         const uint8_t uploaded_root[32])
{
    if (!key_is_usable(pinned_key)) return BEALACH_PRUNE_NO_PINNED_KEY;

    static bealach_receipt_t r;
    static uint8_t         scratch[1024];

    bealach_err_t derr =
        bealach_receipt_decode(receipt, receipt_len, &r, scratch, sizeof(scratch));
    if (derr != BEALACH_OK) {
        BEALACH_LOGE(TAG, "receipt does not decode: %s", bealach_strerror(derr));
        return BEALACH_PRUNE_RECEIPT_MALFORMED;
    }

    /*
     * Signature first, then what it covers. Distinguishing the two matters for
     * diagnosis: a bad signature means the wrong key or a forgery, while a
     * genuine signature over the wrong root means a server/bundle mix-up. Both
     * refuse to delete, but they mean different things on a bench.
     */
    if (bealach_receipt_verify(&r, pinned_key) != BEALACH_OK) {
        BEALACH_LOGE(TAG, "receipt does not verify against the pinned key; "
                        "nothing will be deleted");
        return BEALACH_PRUNE_RECEIPT_UNVERIFIED;
    }

    if (bealach_receipt_verify_acknowledges(&r, pinned_key, uploaded_root) != BEALACH_OK) {
        BEALACH_LOGE(TAG, "receipt is genuine but acknowledges different content; "
                        "refusing to delete");
        return BEALACH_PRUNE_WRONG_BUNDLE;
    }

    return BEALACH_PRUNE_OK;
}

bealach_prune_result_t bealach_prune_if_receipted(const char *id_text,
                                              const uint8_t *receipt,
                                              size_t receipt_len,
                                              const uint8_t pinned_key[32],
                                              const uint8_t uploaded_root[32])
{
    bealach_prune_result_t check =
        bealach_receipt_check(receipt, receipt_len, pinned_key, uploaded_root);
    if (check == BEALACH_PRUNE_NO_PINNED_KEY) {
        BEALACH_LOGW(TAG, "no server key is pinned; %s stays on the card", id_text);
    }
    if (check != BEALACH_PRUNE_OK) return check;

    /* Only now, with both conditions met, is deletion authorized. */
    if (!intent_write(id_text, uploaded_root)) {
        BEALACH_LOGE(TAG, "cannot write the prune intent for %s; refusing to "
                        "delete anything", id_text);
        return BEALACH_PRUNE_STORE_FAILED;
    }

    if (!delete_bundle_dir(id_text)) {
        BEALACH_LOGE(TAG, "prune of %s failed part-way; the intent record remains "
                        "so the next boot can finish it", id_text);
        return BEALACH_PRUNE_STORE_FAILED;
    }

    intent_clear(id_text);
    BEALACH_LOGI(TAG, "pruned %s (receipt verified against the pinned key)", id_text);
    return BEALACH_PRUNE_OK;
}

int bealach_prune_resume_interrupted(void)
{
    bealach_dir_t *d = bealach_fs_opendir(BEALACH_DIR_STATE);
    if (d == NULL) return 0;

    char   pending[8][64];
    size_t count = 0;
    char   name[64];
    bool   is_dir = false;

    while (bealach_fs_readdir(d, name, sizeof(name), &is_dir, NULL)) {
        if (is_dir) continue;
        if (strncmp(name, "prune-", 6) != 0) continue;
        if (count >= sizeof(pending) / sizeof(pending[0])) continue;

        snprintf(pending[count], sizeof(pending[0]), "%s", name);
        count++;
    }
    bealach_fs_closedir(d);

    int finished = 0;

    for (size_t i = 0; i < count; i++) {
        /* "prune-<id>.json" → "<id>" */
        char id_text[40];
        snprintf(id_text, sizeof(id_text), "%s", pending[i] + 6);
        char *dot = strstr(id_text, ".json");
        if (dot != NULL) *dot = '\0';

        /*
         * An intent is only ever written after a receipt was verified, so
         * finishing the delete is already authorized. The stored receipt is
         * required as corroboration: without it there is no local evidence the
         * data is safe, so the bundle is kept and the intent cleared. Erring
         * towards a full card is always recoverable; erring the other way is
         * not.
         */
        if (!bealach_receipt_exists(id_text)) {
            BEALACH_LOGE(TAG, "prune intent for %s has no stored receipt; keeping "
                            "the bundle and clearing the intent", id_text);
            intent_clear(id_text);
            continue;
        }

        BEALACH_LOGW(TAG, "finishing interrupted prune of %s", id_text);
        if (delete_bundle_dir(id_text)) {
            intent_clear(id_text);
            finished++;
        }
    }

    if (finished > 0) BEALACH_LOGI(TAG, "completed %d interrupted prune(s)", finished);
    return finished;
}
