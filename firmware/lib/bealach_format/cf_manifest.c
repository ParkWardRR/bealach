/* Provenance: cairn-esp32-device-firmware @ ead3532, lib/bealach_format/cf_manifest.c
 * Renamed bealach_* → bealach_* for Bealach. Wire format markers unchanged. */

/* Manifest and receipt encoding, decoding and signing. */

#include <string.h>

#include "bealach_format.h"

/* Manifest CBOR keys. Integer keys keep the encoding compact and unambiguous. */
#define K_MANIFEST_VERSION 1
#define K_BUNDLE_ID        2
#define K_DEVICE_ID        3
#define K_DEVICE_KEY_ID    4
#define K_BOOT_ID          5
#define K_FIRMWARE_VERSION 6
#define K_SCHEMA_VERSION   7
#define K_CAPTURE_STARTED  8
#define K_CAPTURE_ENDED    9
#define K_UTC_BASIS_MS     10
#define K_UTC_BASIS_ACC_MS 11
#define K_FIRST_SEQ        12
#define K_LAST_SEQ         13
#define K_RECORD_COUNTS    14
#define K_MEMBERS          15
#define K_CHUNK_DESCS      16
#define K_CONTENT_ROOT     17
#define K_PREVIOUS_ROOT    18
#define K_POLICY_VERSION   19
#define K_RECOVERY_STATE   20
#define K_DISCARDED_TAIL   21
#define K_SIGNATURE_ALGO   22
#define K_TRIP_SEQ         23 /* optional */

/*
 * Keys 24-28 are mandatory. They sit after the optional trip_seq so the encoder
 * emits keys in ascending order.
 */
#define K_VEHICLE_ID       24
#define K_ASSIGNMENT_ID    25
#define K_DEVICE_COUNTER   26
#define K_KEY_VERSION      27
#define K_ENCRYPTION_SUITE 28

/*
 * Optional, and last: the engine profile that produced the bundle. The profile
 * decides the OBD request, every conversion, the cadences and the thresholds, so
 * a bundle that does not name it cannot be checked against the rules that made
 * it. The digest rather than only a name, because a profile edited without a
 * version bump is a different profile and only the digest says so.
 */
#define K_ENGINE_PROFILE   29 /* optional */

/*
 * trip_seq and engine_profile are independently optional, so the count is the
 * mandatory set plus however many are present -- 27, 28 or 29 are all
 * well-formed. Not a choice between two totals.
 */
#define MANIFEST_FIELD_COUNT_BASE 27
#define MANIFEST_FIELD_COUNT_MAX  29

/* Receipt keys. 1..10 are covered by the signature; 11 is the signature. */
#define RK_VERSION      1
#define RK_RECEIPT_ID   2
#define RK_DEVICE_ID    3
#define RK_BUNDLE_ID    4
#define RK_CONTENT_ROOT 5
#define RK_INGEST_UTC   6
#define RK_SERVER_KEY   7
#define RK_SCHEMA_VER   8
#define RK_OBJECT_IDS   9
#define RK_SIG_ALGO     10
#define RK_SIGNATURE    11

#define RECEIPT_SIGNED_FIELD_COUNT 10
#define RECEIPT_FIELD_COUNT        11

/* ── manifest encode ──────────────────────────────────────────────────────── */

bealach_err_t bealach_manifest_encode(const bealach_manifest_t *m,
                                  uint8_t *out, size_t out_cap, size_t *written)
{
    if (strcmp(m->signature_algorithm, BEALACH_SIGALG_ED25519) != 0) {
        return BEALACH_ERR_MALFORMED;
    }
    /* Mandatory, and only one suite exists: a manifest naming anything else
     * would describe segments this code did not seal. */
    if (strcmp(m->encryption_suite, BEALACH_ENCRYPTION_SUITE_V1) != 0) {
        return BEALACH_ERR_MALFORMED;
    }
    if (m->member_count > BEALACH_MAX_MEMBERS) return BEALACH_ERR_TOO_MANY_MEMBERS;

    bealach_cbor_enc_t e;
    bealach_cbor_init(&e, out, out_cap);

    {
        unsigned fields = MANIFEST_FIELD_COUNT_BASE;
        if (m->has_trip_seq) fields++;
        if (m->has_engine_profile) fields++;
        bealach_cbor_map(&e, fields);
    }

    bealach_cbor_key(&e, K_MANIFEST_VERSION);
    bealach_cbor_uint(&e, m->manifest_version);
    bealach_cbor_key(&e, K_BUNDLE_ID);
    bealach_cbor_bytes(&e, m->bundle_id, 16);
    bealach_cbor_key(&e, K_DEVICE_ID);
    bealach_cbor_bytes(&e, m->device_id, 16);
    bealach_cbor_key(&e, K_DEVICE_KEY_ID);
    bealach_cbor_bytes(&e, m->device_key_id, 8);
    bealach_cbor_key(&e, K_BOOT_ID);
    bealach_cbor_bytes(&e, m->boot_id, 16);
    bealach_cbor_key(&e, K_FIRMWARE_VERSION);
    bealach_cbor_text(&e, m->firmware_version);
    bealach_cbor_key(&e, K_SCHEMA_VERSION);
    bealach_cbor_uint(&e, m->schema_version);
    bealach_cbor_key(&e, K_CAPTURE_STARTED);
    bealach_cbor_uint(&e, m->capture_started_monotonic_us);
    bealach_cbor_key(&e, K_CAPTURE_ENDED);
    bealach_cbor_uint(&e, m->capture_ended_monotonic_us);
    bealach_cbor_key(&e, K_UTC_BASIS_MS);
    bealach_cbor_uint(&e, m->utc_basis_ms);
    bealach_cbor_key(&e, K_UTC_BASIS_ACC_MS);
    bealach_cbor_uint(&e, m->utc_basis_acc_ms);
    bealach_cbor_key(&e, K_FIRST_SEQ);
    bealach_cbor_uint(&e, m->first_seq);
    bealach_cbor_key(&e, K_LAST_SEQ);
    bealach_cbor_uint(&e, m->last_seq);

    /* Record counts: a nested map, keys ascending by record type. */
    size_t counted = 0;
    for (int t = 0; t < 256; t++) {
        if (m->record_counts[t] != 0) counted++;
    }
    bealach_cbor_key(&e, K_RECORD_COUNTS);
    bealach_cbor_map(&e, counted);
    for (int t = 0; t < 256; t++) {
        if (m->record_counts[t] == 0) continue;
        bealach_cbor_key(&e, (uint64_t)t);
        bealach_cbor_uint(&e, m->record_counts[t]);
    }

    /* Members: sorted by raw name bytes, as the content root requires. */
    bealach_member_t sorted[BEALACH_MAX_MEMBERS];
    for (size_t i = 0; i < m->member_count; i++) sorted[i] = m->members[i];
    bealach_sort_members(sorted, m->member_count);

    bealach_cbor_key(&e, K_MEMBERS);
    bealach_cbor_array(&e, m->member_count);
    for (size_t i = 0; i < m->member_count; i++) {
        bealach_cbor_array(&e, 3);
        bealach_cbor_text(&e, sorted[i].name);
        bealach_cbor_uint(&e, sorted[i].length);
        bealach_cbor_bytes(&e, sorted[i].sha256, 32);
    }

    bealach_cbor_key(&e, K_CHUNK_DESCS);
    bealach_cbor_array(&e, m->chunk_count);
    for (size_t i = 0; i < m->chunk_count; i++) {
        bealach_cbor_array(&e, 3);
        bealach_cbor_uint(&e, m->chunks[i].index);
        bealach_cbor_uint(&e, m->chunks[i].byte_length);
        bealach_cbor_bytes(&e, m->chunks[i].sha256, 32);
    }

    bealach_cbor_key(&e, K_CONTENT_ROOT);
    bealach_cbor_bytes(&e, m->content_root, 32);

    bealach_cbor_key(&e, K_PREVIOUS_ROOT);
    if (m->has_previous_root) {
        bealach_cbor_bytes(&e, m->previous_bundle_root, 32);
    } else {
        bealach_cbor_null(&e);
    }

    bealach_cbor_key(&e, K_POLICY_VERSION);
    bealach_cbor_uint(&e, m->policy_version);
    bealach_cbor_key(&e, K_RECOVERY_STATE);
    bealach_cbor_uint(&e, m->recovery_state);
    bealach_cbor_key(&e, K_DISCARDED_TAIL);
    bealach_cbor_uint(&e, m->discarded_tail_bytes);
    bealach_cbor_key(&e, K_SIGNATURE_ALGO);
    bealach_cbor_text(&e, m->signature_algorithm);

    if (m->has_trip_seq) {
        bealach_cbor_key(&e, K_TRIP_SEQ);
        bealach_cbor_uint(&e, m->trip_seq);
    }

    bealach_cbor_key(&e, K_VEHICLE_ID);
    bealach_cbor_bytes(&e, m->vehicle_id, 16);
    bealach_cbor_key(&e, K_ASSIGNMENT_ID);
    bealach_cbor_bytes(&e, m->assignment_id, 16);
    bealach_cbor_key(&e, K_DEVICE_COUNTER);
    bealach_cbor_uint(&e, m->device_counter);
    bealach_cbor_key(&e, K_KEY_VERSION);
    bealach_cbor_uint(&e, m->storage_key_version);
    bealach_cbor_key(&e, K_ENCRYPTION_SUITE);
    bealach_cbor_text(&e, m->encryption_suite);

    if (m->has_engine_profile) {
        bealach_cbor_key(&e, K_ENGINE_PROFILE);
        bealach_cbor_array(&e, 3);
        bealach_cbor_text(&e, m->engine_profile_id);
        bealach_cbor_uint(&e, m->engine_profile_version);
        bealach_cbor_bytes(&e, m->engine_profile_sha256, 32);
    }

    if (e.overflow) return BEALACH_ERR_BUFFER_TOO_SMALL;
    if (written) *written = e.len;
    return BEALACH_OK;
}

/* ── manifest decode ──────────────────────────────────────────────────────── */

static bealach_err_t manifest_decode_raw(const uint8_t *buf, size_t len,
                                       bealach_manifest_t *m)
{
    bealach_cbor_dec_t d;
    bealach_cbor_dec_init(&d, buf, len);

    memset(m, 0, sizeof(*m));

    size_t n;
    bealach_err_t err = bealach_cbor_map_header(&d, &n);
    if (err != BEALACH_OK) return err;
    if (n < MANIFEST_FIELD_COUNT_BASE || n > MANIFEST_FIELD_COUNT_MAX)
        return BEALACH_ERR_MALFORMED;

    for (size_t i = 0; i < n; i++) {
        uint64_t key;
        err = bealach_cbor_uint_read(&d, &key);
        if (err != BEALACH_OK) return err;

        uint64_t v;

        switch (key) {
        case K_MANIFEST_VERSION:
            if ((err = bealach_cbor_uint_read(&d, &v)) != BEALACH_OK) return err;
            if (v != BEALACH_MANIFEST_VERSION) return BEALACH_ERR_MALFORMED;
            m->manifest_version = (uint8_t)v;
            break;
        case K_BUNDLE_ID:
            if ((err = bealach_cbor_bytes_n(&d, m->bundle_id, 16)) != BEALACH_OK) return err;
            break;
        case K_DEVICE_ID:
            if ((err = bealach_cbor_bytes_n(&d, m->device_id, 16)) != BEALACH_OK) return err;
            break;
        case K_DEVICE_KEY_ID:
            if ((err = bealach_cbor_bytes_n(&d, m->device_key_id, 8)) != BEALACH_OK) return err;
            break;
        case K_BOOT_ID:
            if ((err = bealach_cbor_bytes_n(&d, m->boot_id, 16)) != BEALACH_OK) return err;
            break;
        case K_FIRMWARE_VERSION:
            err = bealach_cbor_text_read(&d, m->firmware_version, sizeof(m->firmware_version));
            if (err != BEALACH_OK) return err;
            break;
        case K_SCHEMA_VERSION:
            if ((err = bealach_cbor_uint_read(&d, &v)) != BEALACH_OK) return err;
            m->schema_version = (uint8_t)v;
            break;
        case K_CAPTURE_STARTED:
            if ((err = bealach_cbor_uint_read(&d, &m->capture_started_monotonic_us)) != BEALACH_OK)
                return err;
            break;
        case K_CAPTURE_ENDED:
            if ((err = bealach_cbor_uint_read(&d, &m->capture_ended_monotonic_us)) != BEALACH_OK)
                return err;
            break;
        case K_UTC_BASIS_MS:
            if ((err = bealach_cbor_uint_read(&d, &m->utc_basis_ms)) != BEALACH_OK) return err;
            break;
        case K_UTC_BASIS_ACC_MS:
            if ((err = bealach_cbor_uint_read(&d, &v)) != BEALACH_OK) return err;
            m->utc_basis_acc_ms = (uint32_t)v;
            break;
        case K_FIRST_SEQ:
            if ((err = bealach_cbor_uint_read(&d, &v)) != BEALACH_OK) return err;
            m->first_seq = (uint32_t)v;
            break;
        case K_LAST_SEQ:
            if ((err = bealach_cbor_uint_read(&d, &v)) != BEALACH_OK) return err;
            m->last_seq = (uint32_t)v;
            break;
        case K_RECORD_COUNTS: {
            size_t cnt;
            if ((err = bealach_cbor_map_header(&d, &cnt)) != BEALACH_OK) return err;
            int64_t prev = -1;
            for (size_t j = 0; j < cnt; j++) {
                uint64_t rt, c;
                if ((err = bealach_cbor_uint_read(&d, &rt)) != BEALACH_OK) return err;
                if (rt > 255 || (int64_t)rt <= prev) return BEALACH_ERR_NON_CANONICAL;
                prev = (int64_t)rt;
                if ((err = bealach_cbor_uint_read(&d, &c)) != BEALACH_OK) return err;
                m->record_counts[rt] = (uint32_t)c;
            }
            break;
        }
        case K_MEMBERS: {
            size_t cnt;
            if ((err = bealach_cbor_array_header(&d, &cnt)) != BEALACH_OK) return err;
            if (cnt > BEALACH_MAX_MEMBERS) return BEALACH_ERR_TOO_MANY_MEMBERS;
            for (size_t j = 0; j < cnt; j++) {
                size_t fields;
                if ((err = bealach_cbor_array_header(&d, &fields)) != BEALACH_OK) return err;
                if (fields != 3) return BEALACH_ERR_MALFORMED;

                err = bealach_cbor_text_read(&d, m->members[j].name, BEALACH_MAX_MEMBER_NAME);
                if (err != BEALACH_OK) return err;
                if ((err = bealach_cbor_uint_read(&d, &m->members[j].length)) != BEALACH_OK)
                    return err;
                if ((err = bealach_cbor_bytes_n(&d, m->members[j].sha256, 32)) != BEALACH_OK)
                    return err;

                if (j > 0 && strcmp(m->members[j].name, m->members[j - 1].name) <= 0) {
                    return BEALACH_ERR_NON_CANONICAL;
                }
            }
            m->member_count = cnt;
            break;
        }
        case K_CHUNK_DESCS: {
            size_t cnt;
            if ((err = bealach_cbor_array_header(&d, &cnt)) != BEALACH_OK) return err;
            if (cnt > BEALACH_MAX_CHUNKS) return BEALACH_ERR_MALFORMED;
            for (size_t j = 0; j < cnt; j++) {
                size_t fields;
                if ((err = bealach_cbor_array_header(&d, &fields)) != BEALACH_OK) return err;
                if (fields != 3) return BEALACH_ERR_MALFORMED;

                uint64_t idx, blen;
                if ((err = bealach_cbor_uint_read(&d, &idx)) != BEALACH_OK) return err;
                if ((err = bealach_cbor_uint_read(&d, &blen)) != BEALACH_OK) return err;
                if ((err = bealach_cbor_bytes_n(&d, m->chunks[j].sha256, 32)) != BEALACH_OK)
                    return err;

                if (idx != j) return BEALACH_ERR_MALFORMED;
                m->chunks[j].index       = (uint32_t)idx;
                m->chunks[j].byte_length = (uint32_t)blen;
            }
            m->chunk_count = cnt;
            break;
        }
        case K_CONTENT_ROOT:
            if ((err = bealach_cbor_bytes_n(&d, m->content_root, 32)) != BEALACH_OK) return err;
            break;
        case K_PREVIOUS_ROOT:
            if (bealach_cbor_is_null(&d)) {
                m->has_previous_root = false;
            } else {
                err = bealach_cbor_bytes_n(&d, m->previous_bundle_root, 32);
                if (err != BEALACH_OK) return err;
                m->has_previous_root = true;
            }
            break;
        case K_POLICY_VERSION:
            if ((err = bealach_cbor_uint_read(&d, &v)) != BEALACH_OK) return err;
            m->policy_version = (uint8_t)v;
            break;
        case K_RECOVERY_STATE:
            if ((err = bealach_cbor_uint_read(&d, &v)) != BEALACH_OK) return err;
            if (v > BEALACH_RECOVERY_SALVAGED) return BEALACH_ERR_MALFORMED;
            m->recovery_state = (uint8_t)v;
            break;
        case K_DISCARDED_TAIL:
            if ((err = bealach_cbor_uint_read(&d, &v)) != BEALACH_OK) return err;
            m->discarded_tail_bytes = (uint32_t)v;
            break;
        case K_SIGNATURE_ALGO:
            err = bealach_cbor_text_read(&d, m->signature_algorithm,
                                       sizeof(m->signature_algorithm));
            if (err != BEALACH_OK) return err;
            if (strcmp(m->signature_algorithm, BEALACH_SIGALG_ED25519) != 0) {
                return BEALACH_ERR_MALFORMED;
            }
            break;
        case K_TRIP_SEQ:
            if ((err = bealach_cbor_uint_read(&d, &v)) != BEALACH_OK) return err;
            if (v > UINT32_MAX) return BEALACH_ERR_MALFORMED;
            m->trip_seq = (uint32_t)v;
            m->has_trip_seq = true;
            break;
        case K_VEHICLE_ID:
            if ((err = bealach_cbor_bytes_n(&d, m->vehicle_id, 16)) != BEALACH_OK) return err;
            break;
        case K_ASSIGNMENT_ID:
            if ((err = bealach_cbor_bytes_n(&d, m->assignment_id, 16)) != BEALACH_OK) return err;
            break;
        case K_DEVICE_COUNTER:
            if ((err = bealach_cbor_uint_read(&d, &m->device_counter)) != BEALACH_OK) return err;
            break;
        case K_KEY_VERSION:
            if ((err = bealach_cbor_uint_read(&d, &v)) != BEALACH_OK) return err;
            if (v > UINT32_MAX) return BEALACH_ERR_MALFORMED;
            m->storage_key_version = (uint32_t)v;
            break;
        case K_ENCRYPTION_SUITE:
            err = bealach_cbor_text_read(&d, m->encryption_suite,
                                       sizeof(m->encryption_suite));
            if (err != BEALACH_OK) return err;
            if (strcmp(m->encryption_suite, BEALACH_ENCRYPTION_SUITE_V1) != 0) {
                return BEALACH_ERR_MALFORMED;
            }
            break;
        case K_ENGINE_PROFILE: {
            size_t fields = 0;
            if ((err = bealach_cbor_array_header(&d, &fields)) != BEALACH_OK) return err;
            if (fields != 3) return BEALACH_ERR_MALFORMED;
            err = bealach_cbor_text_read(&d, m->engine_profile_id,
                                       sizeof(m->engine_profile_id));
            if (err != BEALACH_OK) return err;
            if ((err = bealach_cbor_uint_read(&d, &v)) != BEALACH_OK) return err;
            if (v > UINT8_MAX) return BEALACH_ERR_MALFORMED;
            m->engine_profile_version = (uint8_t)v;
            err = bealach_cbor_bytes_n(&d, m->engine_profile_sha256, 32);
            if (err != BEALACH_OK) return err;
            m->has_engine_profile = true;
            break;
        }
        default:
            return BEALACH_ERR_MALFORMED;
        }
    }

    if (d.pos != d.len) return BEALACH_ERR_MALFORMED;
    return BEALACH_OK;
}

bealach_err_t bealach_manifest_decode(const uint8_t *buf, size_t len,
                                  bealach_manifest_t *out,
                                  uint8_t *scratch, size_t scratch_cap)
{
    bealach_err_t err = manifest_decode_raw(buf, len, out);
    if (err != BEALACH_OK) return err;

    /*
     * Canonicality by round-trip: re-encode and require byte equality. A
     * manifest whose bytes we would not ourselves have produced cannot be
     * safely re-serialized, and any discrepancy would silently break signature
     * verification.
     */
    size_t written = 0;
    err = bealach_manifest_encode(out, scratch, scratch_cap, &written);
    if (err != BEALACH_OK) return err;

    if (written != len || memcmp(scratch, buf, len) != 0) {
        return BEALACH_ERR_NON_CANONICAL;
    }

    return BEALACH_OK;
}

bealach_err_t bealach_manifest_verify_content_root(const bealach_manifest_t *m)
{
    uint8_t computed[32];

    bealach_err_t err = bealach_content_root(m->members, m->member_count, computed);
    if (err != BEALACH_OK) return err;

    if (memcmp(computed, m->content_root, 32) != 0) {
        return BEALACH_ERR_CONTENT_ROOT_MISMATCH;
    }
    return BEALACH_OK;
}

/* ── binding (§5.4) ───────────────────────────────────────────────────────── */

/*
 * The capture segment index named by "seg-NNNNNNNN.seg", exactly that shape —
 * eight decimal digits, as the store and the Go reference both write it. Any
 * other spelling is not a capture segment name, so a header cannot be matched
 * to it.
 */
static bool capture_index_from_name(const char *name, uint32_t *out)
{
    if (strlen(name) != 16 || strncmp(name, "seg-", 4) != 0 ||
        strcmp(name + 12, ".seg") != 0) {
        return false;
    }

    uint32_t v = 0;
    for (int i = 4; i < 12; i++) {
        if (name[i] < '0' || name[i] > '9') return false;
        v = v * 10u + (uint32_t)(name[i] - '0');
    }
    *out = v;
    return true;
}

bealach_err_t bealach_verify_segment_binding(const bealach_manifest_t *m, const char *name,
                                         const bealach_segment_header_t *h,
                                         const char **field)
{
    const char *bad = NULL;

    /* Same order as the Go reference, so both name the same first mismatch. */
    if (memcmp(h->device_id, m->device_id, 16) != 0) {
        bad = "device_id";
    } else if (memcmp(h->boot_id, m->boot_id, 16) != 0) {
        bad = "boot_id";
    } else if (memcmp(h->vehicle_id, m->vehicle_id, 16) != 0) {
        bad = "vehicle_id";
    } else if (memcmp(h->assignment_id, m->assignment_id, 16) != 0) {
        bad = "assignment_id";
    } else if (h->device_counter != m->device_counter) {
        bad = "device_counter";
    } else if (h->storage_key_version != m->storage_key_version) {
        bad = "storage_key_version";
    } else if (strcmp(name, "journal.seg") == 0) {
        if (h->segment_index != BEALACH_JOURNAL_SEGMENT_INDEX) bad = "segment_index";
    } else {
        /*
         * A capture segment's index is a key-derivation input, so a segment
         * renamed into another position would still open under its own key —
         * only this check notices that it is in the wrong place.
         */
        uint32_t want = 0;
        if (!capture_index_from_name(name, &want) || want != h->segment_index) {
            bad = "segment_index";
        }
    }

    if (field) *field = bad;
    return (bad == NULL) ? BEALACH_OK : BEALACH_ERR_BINDING_MISMATCH;
}

/* ── manifest signing ─────────────────────────────────────────────────────── */

bealach_err_t bealach_manifest_sign(const bealach_manifest_t *m,
                                const uint8_t seed[32], const uint8_t pub[32],
                                uint8_t *encoded, size_t encoded_cap, size_t *written,
                                uint8_t sig[64])
{
    size_t n = 0;
    bealach_err_t err = bealach_manifest_encode(m, encoded, encoded_cap, &n);
    if (err != BEALACH_OK) return err;

    bealach_ed25519_sign(encoded, n, seed, pub, sig);
    if (written) *written = n;
    return BEALACH_OK;
}

bealach_err_t bealach_manifest_verify(const uint8_t *encoded, size_t len,
                                  const uint8_t sig[64], const uint8_t pub[32])
{
    /*
     * Verified against the bytes as received, before parsing, so verification
     * never depends on this implementation's ability to re-encode.
     */
    if (!bealach_ed25519_verify(encoded, len, sig, pub)) return BEALACH_ERR_BAD_SIGNATURE;
    return BEALACH_OK;
}

/* ── receipt ──────────────────────────────────────────────────────────────── */

static bealach_err_t receipt_encode_fields(const bealach_receipt_t *r, bool with_sig,
                                         uint8_t *out, size_t out_cap, size_t *written)
{
    if (strcmp(r->signature_algorithm, BEALACH_SIGALG_ED25519) != 0) {
        return BEALACH_ERR_MALFORMED;
    }

    bealach_cbor_enc_t e;
    bealach_cbor_init(&e, out, out_cap);

    bealach_cbor_map(&e, with_sig ? RECEIPT_FIELD_COUNT : RECEIPT_SIGNED_FIELD_COUNT);

    bealach_cbor_key(&e, RK_VERSION);
    bealach_cbor_uint(&e, r->receipt_version);
    bealach_cbor_key(&e, RK_RECEIPT_ID);
    bealach_cbor_bytes(&e, r->receipt_id, 16);
    bealach_cbor_key(&e, RK_DEVICE_ID);
    bealach_cbor_bytes(&e, r->device_id, 16);
    bealach_cbor_key(&e, RK_BUNDLE_ID);
    bealach_cbor_bytes(&e, r->bundle_id, 16);
    bealach_cbor_key(&e, RK_CONTENT_ROOT);
    bealach_cbor_bytes(&e, r->content_root, 32);
    bealach_cbor_key(&e, RK_INGEST_UTC);
    bealach_cbor_uint(&e, r->server_ingest_utc_ms);
    bealach_cbor_key(&e, RK_SERVER_KEY);
    bealach_cbor_bytes(&e, r->server_key_id, 8);
    bealach_cbor_key(&e, RK_SCHEMA_VER);
    bealach_cbor_uint(&e, r->ingest_schema_version);

    bealach_cbor_key(&e, RK_OBJECT_IDS);
    bealach_cbor_array(&e, r->object_id_count);
    for (size_t i = 0; i < r->object_id_count; i++) {
        bealach_cbor_text(&e, r->object_ids[i]);
    }

    bealach_cbor_key(&e, RK_SIG_ALGO);
    bealach_cbor_text(&e, r->signature_algorithm);

    if (with_sig) {
        bealach_cbor_key(&e, RK_SIGNATURE);
        bealach_cbor_bytes(&e, r->signature, 64);
    }

    if (e.overflow) return BEALACH_ERR_BUFFER_TOO_SMALL;
    if (written) *written = e.len;
    return BEALACH_OK;
}

bealach_err_t bealach_receipt_signing_bytes(const bealach_receipt_t *r,
                                        uint8_t *out, size_t out_cap, size_t *written)
{
    return receipt_encode_fields(r, false, out, out_cap, written);
}

bealach_err_t bealach_receipt_encode(const bealach_receipt_t *r,
                                 uint8_t *out, size_t out_cap, size_t *written)
{
    return receipt_encode_fields(r, true, out, out_cap, written);
}

static bealach_err_t receipt_decode_raw(const uint8_t *buf, size_t len, bealach_receipt_t *r)
{
    bealach_cbor_dec_t d;
    bealach_cbor_dec_init(&d, buf, len);

    memset(r, 0, sizeof(*r));

    size_t n;
    bealach_err_t err = bealach_cbor_map_header(&d, &n);
    if (err != BEALACH_OK) return err;
    if (n != RECEIPT_FIELD_COUNT) return BEALACH_ERR_MALFORMED;

    for (size_t i = 0; i < n; i++) {
        uint64_t key;
        err = bealach_cbor_uint_read(&d, &key);
        if (err != BEALACH_OK) return err;

        uint64_t v;

        switch (key) {
        case RK_VERSION:
            if ((err = bealach_cbor_uint_read(&d, &v)) != BEALACH_OK) return err;
            if (v != BEALACH_RECEIPT_VERSION) return BEALACH_ERR_MALFORMED;
            r->receipt_version = (uint8_t)v;
            break;
        case RK_RECEIPT_ID:
            if ((err = bealach_cbor_bytes_n(&d, r->receipt_id, 16)) != BEALACH_OK) return err;
            break;
        case RK_DEVICE_ID:
            if ((err = bealach_cbor_bytes_n(&d, r->device_id, 16)) != BEALACH_OK) return err;
            break;
        case RK_BUNDLE_ID:
            if ((err = bealach_cbor_bytes_n(&d, r->bundle_id, 16)) != BEALACH_OK) return err;
            break;
        case RK_CONTENT_ROOT:
            if ((err = bealach_cbor_bytes_n(&d, r->content_root, 32)) != BEALACH_OK) return err;
            break;
        case RK_INGEST_UTC:
            if ((err = bealach_cbor_uint_read(&d, &r->server_ingest_utc_ms)) != BEALACH_OK)
                return err;
            break;
        case RK_SERVER_KEY:
            if ((err = bealach_cbor_bytes_n(&d, r->server_key_id, 8)) != BEALACH_OK) return err;
            break;
        case RK_SCHEMA_VER:
            if ((err = bealach_cbor_uint_read(&d, &v)) != BEALACH_OK) return err;
            r->ingest_schema_version = (uint8_t)v;
            break;
        case RK_OBJECT_IDS: {
            size_t cnt;
            if ((err = bealach_cbor_array_header(&d, &cnt)) != BEALACH_OK) return err;
            if (cnt > BEALACH_MAX_OBJECT_IDS) return BEALACH_ERR_MALFORMED;
            for (size_t j = 0; j < cnt; j++) {
                err = bealach_cbor_text_read(&d, r->object_ids[j], BEALACH_MAX_OBJECT_ID_LEN);
                if (err != BEALACH_OK) return err;
            }
            r->object_id_count = cnt;
            break;
        }
        case RK_SIG_ALGO:
            err = bealach_cbor_text_read(&d, r->signature_algorithm,
                                       sizeof(r->signature_algorithm));
            if (err != BEALACH_OK) return err;
            if (strcmp(r->signature_algorithm, BEALACH_SIGALG_ED25519) != 0) {
                return BEALACH_ERR_MALFORMED;
            }
            break;
        case RK_SIGNATURE:
            if ((err = bealach_cbor_bytes_n(&d, r->signature, 64)) != BEALACH_OK) return err;
            break;
        default:
            return BEALACH_ERR_MALFORMED;
        }
    }

    if (d.pos != d.len) return BEALACH_ERR_MALFORMED;
    return BEALACH_OK;
}

bealach_err_t bealach_receipt_decode(const uint8_t *buf, size_t len,
                                 bealach_receipt_t *out,
                                 uint8_t *scratch, size_t scratch_cap)
{
    bealach_err_t err = receipt_decode_raw(buf, len, out);
    if (err != BEALACH_OK) return err;

    /*
     * The round-trip check matters more here than for the manifest: a receipt
     * carries its signature inline, so verification must re-encode the signed
     * fields. Accepting a non-canonical receipt would mean verifying bytes
     * other than those received.
     */
    size_t written = 0;
    err = bealach_receipt_encode(out, scratch, scratch_cap, &written);
    if (err != BEALACH_OK) return err;

    if (written != len || memcmp(scratch, buf, len) != 0) {
        return BEALACH_ERR_NON_CANONICAL;
    }

    return BEALACH_OK;
}

bealach_err_t bealach_receipt_verify(const bealach_receipt_t *r, const uint8_t pub[32])
{
    uint8_t signing[512];
    size_t  n = 0;

    bealach_err_t err = bealach_receipt_signing_bytes(r, signing, sizeof(signing), &n);
    if (err != BEALACH_OK) return err;

    if (!bealach_ed25519_verify(signing, n, r->signature, pub)) {
        return BEALACH_ERR_BAD_SIGNATURE;
    }
    return BEALACH_OK;
}

bealach_err_t bealach_receipt_verify_acknowledges(const bealach_receipt_t *r,
                                              const uint8_t pub[32],
                                              const uint8_t uploaded_root[32])
{
    bealach_err_t err = bealach_receipt_verify(r, pub);
    if (err != BEALACH_OK) return err;

    /*
     * Both conditions are required. A validly signed receipt for a different
     * bundle is not an acknowledgement of this one, and treating it as one
     * would let a misconfigured or hostile server induce deletion of data it
     * never received.
     */
    if (memcmp(r->content_root, uploaded_root, 32) != 0) {
        return BEALACH_ERR_RECEIPT_ROOT_MISMATCH;
    }
    return BEALACH_OK;
}
