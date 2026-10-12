/* Provenance: cairn-esp32-device-firmware @ ead3532, test/host/interop_writer.c
 * Renamed bealach_* → bealach_* for Bealach. Wire format markers unchanged. */

/*
 * The firmware's bundle writer, aimed at the server's reader.
 *
 * Seals real bundles with lib/bealach_store and lib/bealach_format - the code the device
 * runs, over a POSIX card - and leaves them on disk for the server's own verifier
 * (cairn-verify, Go) to accept or reject. Nothing in this program checks its own
 * output: a C writer judged by a C reader agrees with itself whatever it got wrong
 * (a wrong CRC polynomial, a reordered frame header). The only judge that counts is
 * the independent implementation, so that is the point of the program.
 *
 *   interop-writer <out-dir>
 *
 * writes
 *   <out-dir>/card/bundles/<ulid>/...   sealed bundles (manifest, signature, segments)
 *   <out-dir>/interop.env               DEVICE_KEY, ROOT_KEY, KEY_VERSION, BUNDLES
 *
 * Deterministic: the clock and both random streams are seeded, so two runs of the same
 * code write the same bytes, and a run that differs is a code change, not luck.
 *
 * The bundles are chosen to cover what a reader can get wrong, not for realism:
 *   1. one bundle that crosses a segment rotation (frame chain and prev_crc32 across
 *      files), with a second chain (the journal) interleaved;
 *   2. a second, small bundle, so device_counter advances and the per-bundle
 *      derivation is exercised twice.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "board_config.h"
#include "bealach_format.h"
#include "bealach_fs.h"
#include "bealach_kv.h"
#include "bealach_log.h"
#include "bealach_platform.h"
#include "bealach_store.h"

void bealach_host_advance(uint32_t ms);
void bealach_host_seed(uint64_t seed);
void bealach_host_rng_seed(uint64_t seed);
void bealach_kv_host_set_path(const char *path);

#define GNSS_FRAME_LEN (BEALACH_FRAME_OVERHEAD + 32)

static const uint8_t VEHICLE_ID[16] = {
    0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67,
    0x68, 0x69, 0x6a, 0x6b, 0x6c, 0x6d, 0x6e, 0x6f,
};
static const uint8_t ASSIGNMENT_ID[16] = {
    0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77,
    0x78, 0x79, 0x7a, 0x7b, 0x7c, 0x7d, 0x7e, 0x7f,
};

static bealach_storage_identity_t g_ident;

static int die(const char *what)
{
    fprintf(stderr, "interop-writer: %s\n", what);
    return 1;
}

static void hex(const uint8_t *b, size_t n, char *out)
{
    static const char d[] = "0123456789abcdef";
    for (size_t i = 0; i < n; i++) {
        out[2 * i]     = d[b[i] >> 4];
        out[2 * i + 1] = d[b[i] & 15];
    }
    out[2 * n] = '\0';
}

static int append_gnss(bealach_capture_t *cap, int first, int n)
{
    for (int i = first; i < first + n; i++) {
        bealach_gnss_sample_t s;
        memset(&s, 0, sizeof(s));
        s.lat_e7     = 340000000 + i;
        s.lon_e7     = -1185000000 - i;
        s.fix_type   = 3;
        s.sats_used  = 9;
        s.hdop_e2    = 120;
        s.h_acc_cm   = BEALACH_U16_UNKNOWN;
        s.v_acc_cm   = BEALACH_U16_UNKNOWN;
        s.utc_acc_ms = BEALACH_U16_UNKNOWN;

        uint8_t payload[32];
        bealach_encode_gnss_sample(&s, payload);
        bealach_host_advance(100);
        if (!bealach_capture_append(cap, BEALACH_CHAIN_CAPTURE, BEALACH_REC_GNSS_SAMPLE, 1, 0,
                                  bealach_millis(), payload, sizeof(payload))) {
            return 0;
        }
    }
    return 1;
}

static int append_journal(bealach_capture_t *cap, int n)
{
    for (int i = 0; i < n; i++) {
        bealach_state_transition_t t;
        memset(&t, 0, sizeof(t));
        t.region         = BEALACH_REGION_CAPTURE;
        t.to_state       = (uint8_t)i;
        t.policy_version = 1;

        uint8_t tp[20];
        bealach_encode_state_transition(&t, tp);
        bealach_host_advance(10);
        if (!bealach_capture_append(cap, BEALACH_CHAIN_JOURNAL, BEALACH_REC_STATE_TRANSITION, 1,
                                  0, bealach_millis(), tp, sizeof(tp))) {
            return 0;
        }

        bealach_device_health_t h;
        memset(&h, 0, sizeof(h));
        h.battery_mv    = (uint16_t)(12400 - i);
        h.sd_free_mib   = 4096;
        h.device_temp_c = 31;
        h.rssi_dbm      = -60;

        uint8_t hp[16];
        bealach_encode_device_health(&h, hp);
        bealach_host_advance(10);
        if (!bealach_capture_append(cap, BEALACH_CHAIN_JOURNAL, BEALACH_REC_DEVICE_HEALTH, 1, 0,
                                  bealach_millis(), hp, sizeof(hp))) {
            return 0;
        }
    }
    return 1;
}

static int seal_one(const uint8_t device_id[16], const uint8_t seed[32],
                    const uint8_t pub[32], int gnss_frames, int journal_pairs,
                    bool want_rotation, char id_out[27])
{
    uint8_t boot_id[16];
    bealach_new_boot_id(boot_id);

    bealach_capture_t cap;
    if (!bealach_capture_open_or_resume(&cap, device_id, boot_id, &g_ident)) {
        return die("cannot open a capture");
    }

    /* Journal records land before, between and after the capture frames. */
    int half = gnss_frames / 2;
    if (!append_gnss(&cap, 0, half) || !append_journal(&cap, journal_pairs) ||
        !append_gnss(&cap, half, gnss_frames - half) ||
        !append_journal(&cap, journal_pairs)) {
        return die("append failed");
    }
    if (want_rotation && cap.segment_index < 1) {
        return die("the bundle was meant to cross a segment rotation and did not");
    }

    uint8_t bundle_id[16];
    if (!bealach_capture_seal(&cap, seed, pub, "cairn-interop-writer", 1, 0, bundle_id)) {
        return die("seal failed");
    }
    bealach_ulid_encode(bundle_id, id_out);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: interop-writer <out-dir>\n");
        return 2;
    }
    const char *out = argv[1];
    char path[1024];

    if (mkdir(out, 0775) != 0 && access(out, F_OK) != 0) return die("cannot create out-dir");

    /* The key-value store (device identity, K_root, counters) lives beside the card,
     * not on it - on the device it is NVS, not the SD card. */
    snprintf(path, sizeof(path), "%s/kv.bin", out);
    unlink(path);
    bealach_kv_host_set_path(path);

    snprintf(path, sizeof(path), "%s/card", out);
    if (mkdir(path, 0775) != 0) return die("cannot create the card directory (exists?)");

    bealach_log_init(0);
    if (!bealach_fs_begin(path)) return die("bealach_fs_begin");
    bealach_host_seed(0x1707E40ULL);
    bealach_host_rng_seed(0x1707E40ULL ^ 0xA5A5A5A5DEADBEEFULL);
    if (!bealach_store_init()) return die("bealach_store_init");
    if (!bealach_kv_begin() || !bealach_storage_set_assignment(VEHICLE_ID, ASSIGNMENT_ID) ||
        !bealach_storage_identity_load(&g_ident)) {
        return die("identity load");
    }

    uint8_t device_id[16], seed[32], pub[32];
    uint32_t boot = 0;
    if (!bealach_identity_load(device_id, seed, pub, &boot)) return die("bealach_identity_load");

    /* More than one segment's worth, so the chain crosses a file boundary. */
    const int big = (int)(BEALACH_SEGMENT_MAX_BYTES / GNSS_FRAME_LEN) + 64;

    char a[27], b[27];
    if (seal_one(device_id, seed, pub, big, 24, true, a) != 0) return 1;
    if (seal_one(device_id, seed, pub, 40, 3, false, b) != 0) return 1;

    char device_hex[65], root_hex[65];
    hex(pub, 32, device_hex);
    hex(g_ident.root_key, BEALACH_ROOT_KEY_SIZE, root_hex);

    snprintf(path, sizeof(path), "%s/interop.env", out);
    FILE *f = fopen(path, "w");
    if (f == NULL) return die("cannot write interop.env");
    fprintf(f, "DEVICE_KEY=%s\nROOT_KEY=%s\nKEY_VERSION=%u\nBUNDLES=\"%s %s\"\n", device_hex,
            root_hex, (unsigned)g_ident.storage_key_version, a, b);
    fclose(f);

    bealach_kv_end();
    bealach_fs_end();

    printf("interop-writer: sealed %s (%d frames, rotated) and %s (40 frames) under %s/card\n",
           a, big, b, out);
    return 0;
}
