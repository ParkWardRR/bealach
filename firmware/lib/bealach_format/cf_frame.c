/* Provenance: cairn-esp32-device-firmware @ ead3532, lib/bealach_format/cf_frame.c
 * Renamed bealach_* → bealach_* for Bealach. Wire format markers unchanged. */

/*
 * Segment headers, frame sealing and the recovery scan.
 *
 * The scan is the algorithm that decides what survives a power cut, so it
 * follows the specification literally and is checked against the committed
 * vectors. Its behaviour is stop-at-first-invalid: every frame before the
 * failure is retained, everything after it is reported as a discarded tail
 * with an exact byte count and a reason.
 *
 * In v3 every frame is sealed, but nothing structural depends on the key: the
 * CRC and the prev_crc32 chain are computed over the ciphertext frame, so a
 * keyless scan reaches exactly the same structural verdict as a keyed one. The
 * key adds one check, authentication, and it runs last.
 */

#include <stdio.h>
#include <string.h>

#include "bealach_format.h"

static const uint8_t SEGMENT_MAGIC[4] = { 'C', 'R', 'N', '3' };

/* Byte offsets within the 128-byte segment header (§3.1). Spelled out because
 * an off-by-one here is invisible until two implementations disagree on a card. */
#define OFF_MAGIC           0
#define OFF_FORMAT_VERSION  4
#define OFF_HEADER_LEN      6
#define OFF_DEVICE_ID       8
#define OFF_BOOT_ID         24
#define OFF_VEHICLE_ID      40
#define OFF_ASSIGNMENT_ID   56
#define OFF_SEGMENT_INDEX   72
#define OFF_FIRST_SEQ       76
#define OFF_OPENED_US       80
#define OFF_KEY_VERSION     88
#define OFF_DEVICE_COUNTER  92
#define OFF_RESERVED        100 /* 24 bytes, zero */
#define OFF_HEADER_CRC      (BEALACH_SEGMENT_HEADER_SIZE - 4)

/* ── little-endian helpers ────────────────────────────────────────────────── */

static void put_u16(uint8_t *p, uint16_t v)
{
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)((v >> 8) & 0xFF);
}

static void put_u32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)((v >> 8) & 0xFF);
    p[2] = (uint8_t)((v >> 16) & 0xFF);
    p[3] = (uint8_t)((v >> 24) & 0xFF);
}

static void put_u64(uint8_t *p, uint64_t v)
{
    for (int i = 0; i < 8; i++) p[i] = (uint8_t)((v >> (8 * i)) & 0xFF);
}

static uint16_t get_u16(const uint8_t *p)
{
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t get_u32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint64_t get_u64(const uint8_t *p)
{
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
    return v;
}

/* ── record types ─────────────────────────────────────────────────────────── */

bool bealach_record_type_known(uint8_t t)
{
    return t >= BEALACH_REC_GNSS_SAMPLE && t <= BEALACH_REC_TIME_OBSERVATION;
}

const char *bealach_record_type_name(uint8_t t)
{
    switch (t) {
    case BEALACH_REC_GNSS_SAMPLE:      return "GNSS_SAMPLE";
    case BEALACH_REC_IMU_SUMMARY:      return "IMU_SUMMARY";
    case BEALACH_REC_IMU_RAW_WINDOW:   return "IMU_RAW_WINDOW";
    case BEALACH_REC_OBD_SNAPSHOT:     return "OBD_SNAPSHOT";
    case BEALACH_REC_DEVICE_HEALTH:    return "DEVICE_HEALTH";
    case BEALACH_REC_TRIP_EVENT:       return "TRIP_EVENT";
    case BEALACH_REC_STATE_TRANSITION: return "STATE_TRANSITION";
    case BEALACH_REC_GNSS_GAP:         return "GNSS_GAP";
    case BEALACH_REC_POLICY_SNAPSHOT:  return "POLICY_SNAPSHOT";
    case BEALACH_REC_OBD_EXTENDED:     return "OBD_EXTENDED";
    case BEALACH_REC_TIME_OBSERVATION: return "TIME_OBSERVATION";
    default:                         return "UNKNOWN";
    }
}

const char *bealach_event_type_name(uint8_t t)
{
    switch (t) {
    case BEALACH_EVENT_TRIP_START:        return "TRIP_START";
    case BEALACH_EVENT_TRIP_END:          return "TRIP_END";
    case BEALACH_EVENT_HARSH_BRAKE:       return "HARSH_BRAKE";
    case BEALACH_EVENT_HARSH_ACCEL:       return "HARSH_ACCELERATION";
    case BEALACH_EVENT_HARSH_CORNERING:   return "HARSH_CORNERING";
    case BEALACH_EVENT_IMPACT:            return "IMPACT";
    case BEALACH_EVENT_HARSH_MOTION:      return "HARSH_MOTION";
    case BEALACH_EVENT_CAPTURE_RECOVERED: return "CAPTURE_RECOVERED";
    default:                            return "UNKNOWN_EVENT";
    }
}

bealach_err_t bealach_encode_trip_event(uint8_t event_type, int32_t lat_e7,
                                    int32_t lon_e7, const char *detail,
                                    uint8_t *out, size_t out_cap,
                                    size_t *written)
{
    size_t dlen = (detail != NULL) ? strlen(detail) : 0;
    if (dlen > BEALACH_MAX_EVENT_DETAIL) dlen = BEALACH_MAX_EVENT_DETAIL;

    size_t total = 12 + dlen;
    if (out_cap < total) return BEALACH_ERR_BUFFER_TOO_SMALL;

    memset(out, 0, total);
    out[0] = event_type;
    out[1] = (uint8_t)dlen;
    /* out[2..3] reserved, zero */
    put_u32(out + 4, (uint32_t)lat_e7);
    put_u32(out + 8, (uint32_t)lon_e7);
    if (dlen > 0) memcpy(out + 12, detail, dlen);

    *written = total;
    return BEALACH_OK;
}

void bealach_health_state_names(uint8_t state, char *out, size_t cap)
{
    static const struct {
        uint8_t     bit;
        const char *name;
    } bits[] = {
        { BEALACH_HEALTH_DEGRADED_GNSS,     "DEGRADED_GNSS" },
        { BEALACH_HEALTH_DEGRADED_STORAGE,  "DEGRADED_STORAGE" },
        { BEALACH_HEALTH_DEGRADED_TIME,     "DEGRADED_TIME" },
        { BEALACH_HEALTH_DEGRADED_NETWORK,  "DEGRADED_NETWORK" },
        { BEALACH_HEALTH_LOW_POWER,         "LOW_POWER" },
        { BEALACH_HEALTH_RECOVERY_REQUIRED, "RECOVERY_REQUIRED" },
        { BEALACH_HEALTH_DEGRADED_SENSING,  "DEGRADED_SENSING" },
    };

    if (cap == 0) return;

    if (state == BEALACH_HEALTH_OK) {
        snprintf(out, cap, "OK");
        return;
    }

    size_t  used = 0;
    uint8_t seen = 0;

    out[0] = '\0';
    for (size_t i = 0; i < sizeof(bits) / sizeof(bits[0]); i++) {
        if ((state & bits[i].bit) == 0) continue;

        int n = snprintf(out + used, cap - used, "%s%s",
                         (used > 0) ? "|" : "", bits[i].name);
        if (n < 0 || (size_t)n >= cap - used) return;
        used += (size_t)n;
        seen |= bits[i].bit;
    }

    /* Render anything this build does not know rather than dropping it, so a
     * log written by newer firmware stays readable. */
    uint8_t unknown = (uint8_t)(state & (uint8_t)~seen);
    if (unknown != 0) {
        snprintf(out + used, cap - used, "%s0x%02x", (used > 0) ? "|" : "",
                 unknown);
    }
}

const char *bealach_stop_reason_name(bealach_stop_reason_t r)
{
    switch (r) {
    case BEALACH_STOP_EOF:           return "EOF";
    case BEALACH_STOP_TORN_TAIL:     return "TORN_TAIL";
    case BEALACH_STOP_CORRUPT_FRAME: return "CORRUPT_FRAME";
    case BEALACH_STOP_CHAIN_BREAK:   return "CHAIN_BREAK";
    case BEALACH_STOP_SEQ_GAP:       return "SEQ_GAP";
    case BEALACH_STOP_AUTH_FAILED:   return "AUTH_FAILED";
    default:                       return "?";
    }
}

const char *bealach_strerror(bealach_err_t e)
{
    switch (e) {
    case BEALACH_OK:                        return "ok";
    case BEALACH_ERR_BAD_MAGIC:             return "bad segment magic";
    case BEALACH_ERR_BAD_HEADER_CRC:        return "segment header CRC mismatch";
    case BEALACH_ERR_SHORT_HEADER:          return "segment shorter than header";
    case BEALACH_ERR_UNSUPPORTED_VERSION:   return "unsupported format version";
    case BEALACH_ERR_BAD_HEADER_LEN:        return "header_len below the minimum";
    case BEALACH_ERR_PAYLOAD_TOO_LARGE:     return "payload exceeds the maximum";
    case BEALACH_ERR_BUFFER_TOO_SMALL:      return "output buffer too small";
    case BEALACH_ERR_NON_CANONICAL:         return "non-canonical encoding";
    case BEALACH_ERR_TRUNCATED:             return "truncated input";
    case BEALACH_ERR_UNSUPPORTED_CBOR:      return "unsupported CBOR feature";
    case BEALACH_ERR_MALFORMED:             return "malformed";
    case BEALACH_ERR_BAD_SIGNATURE:         return "signature verification failed";
    case BEALACH_ERR_CONTENT_ROOT_MISMATCH: return "content root does not match members";
    case BEALACH_ERR_RECEIPT_ROOT_MISMATCH: return "receipt acknowledges different content";
    case BEALACH_ERR_TOO_MANY_MEMBERS:      return "too many members";
    case BEALACH_ERR_READ_FAILED:           return "segment read failed";
    case BEALACH_ERR_NO_KEY:                return "no storage key for this segment";
    case BEALACH_ERR_KEY_VERSION_MISMATCH:  return "segment storage_key_version does not match the key held";
    case BEALACH_ERR_AUTH_FAILED:           return "frame authentication failed";
    case BEALACH_ERR_BINDING_MISMATCH:      return "segment header disagrees with manifest";
    default:                              return "unknown error";
    }
}

/* ── segment header ───────────────────────────────────────────────────────── */

bealach_err_t bealach_encode_segment_header(const bealach_segment_header_t *h,
                                        uint8_t *out, size_t out_cap)
{
    if (out_cap < BEALACH_SEGMENT_HEADER_SIZE) return BEALACH_ERR_BUFFER_TOO_SMALL;

    memset(out, 0, BEALACH_SEGMENT_HEADER_SIZE); /* reserved bytes are zero */
    memcpy(out + OFF_MAGIC, SEGMENT_MAGIC, 4);
    put_u16(out + OFF_FORMAT_VERSION, BEALACH_FORMAT_VERSION);
    put_u16(out + OFF_HEADER_LEN, BEALACH_SEGMENT_HEADER_SIZE);
    memcpy(out + OFF_DEVICE_ID, h->device_id, 16);
    memcpy(out + OFF_BOOT_ID, h->boot_id, 16);
    memcpy(out + OFF_VEHICLE_ID, h->vehicle_id, 16);
    memcpy(out + OFF_ASSIGNMENT_ID, h->assignment_id, 16);
    put_u32(out + OFF_SEGMENT_INDEX, h->segment_index);
    put_u32(out + OFF_FIRST_SEQ, h->first_seq);
    put_u64(out + OFF_OPENED_US, h->opened_monotonic_us);
    put_u32(out + OFF_KEY_VERSION, h->storage_key_version);
    put_u64(out + OFF_DEVICE_COUNTER, h->device_counter);
    put_u32(out + OFF_HEADER_CRC, bealach_crc32(out, OFF_HEADER_CRC));

    return BEALACH_OK;
}

bealach_err_t bealach_parse_segment_header(const uint8_t *buf, size_t len,
                                       bealach_segment_header_t *out,
                                       size_t *header_len)
{
    if (len < BEALACH_SEGMENT_HEADER_SIZE) return BEALACH_ERR_SHORT_HEADER;
    if (memcmp(buf + OFF_MAGIC, SEGMENT_MAGIC, 4) != 0) return BEALACH_ERR_BAD_MAGIC;

    uint32_t stored = get_u32(buf + OFF_HEADER_CRC);
    if (bealach_crc32(buf, OFF_HEADER_CRC) != stored) return BEALACH_ERR_BAD_HEADER_CRC;

    out->format_version = get_u16(buf + OFF_FORMAT_VERSION);
    size_t hlen = get_u16(buf + OFF_HEADER_LEN);

    memcpy(out->device_id, buf + OFF_DEVICE_ID, 16);
    memcpy(out->boot_id, buf + OFF_BOOT_ID, 16);
    memcpy(out->vehicle_id, buf + OFF_VEHICLE_ID, 16);
    memcpy(out->assignment_id, buf + OFF_ASSIGNMENT_ID, 16);
    out->segment_index       = get_u32(buf + OFF_SEGMENT_INDEX);
    out->first_seq           = get_u32(buf + OFF_FIRST_SEQ);
    out->opened_monotonic_us = get_u64(buf + OFF_OPENED_US);
    out->storage_key_version = get_u32(buf + OFF_KEY_VERSION);
    out->device_counter      = get_u64(buf + OFF_DEVICE_COUNTER);

    if (header_len) *header_len = hlen;

    if (out->format_version != BEALACH_FORMAT_VERSION) return BEALACH_ERR_UNSUPPORTED_VERSION;
    if (hlen < BEALACH_SEGMENT_HEADER_SIZE) return BEALACH_ERR_BAD_HEADER_LEN;

    return BEALACH_OK;
}

/* ── the segment cipher ───────────────────────────────────────────────────── */

bealach_err_t bealach_segment_cipher_init(bealach_segment_cipher_t *c,
                                      const uint8_t key[BEALACH_SEGMENT_KEY_SIZE],
                                      const uint8_t *header, size_t header_len)
{
    if (header_len < BEALACH_SEGMENT_HEADER_SIZE || header_len > BEALACH_MAX_HEADER_LEN) {
        return BEALACH_ERR_BAD_HEADER_LEN;
    }

    memcpy(c->key, key, BEALACH_SEGMENT_KEY_SIZE);

    /* Everything but the header CRC. The CRC is a damage detector over bytes
     * that are already authenticated; binding it too would add nothing. */
    c->header_aad_len = header_len - 4;
    memcpy(c->header_aad, header, c->header_aad_len);
    return BEALACH_OK;
}

void bealach_segment_cipher_wipe(bealach_segment_cipher_t *c)
{
    volatile uint8_t *v = (volatile uint8_t *)c->key;
    for (size_t i = 0; i < sizeof(c->key); i++) v[i] = 0;
}

/* ── frames ───────────────────────────────────────────────────────────────── */

bealach_err_t bealach_encode_frame(const bealach_segment_cipher_t *c,
                               const uint8_t nonce[BEALACH_NONCE_SIZE],
                               uint8_t record_type, uint8_t schema_version,
                               uint16_t flags, uint32_t seq,
                               uint32_t monotonic_ms, uint32_t prev_crc32,
                               const uint8_t *payload, size_t payload_len,
                               uint8_t *out, size_t out_cap,
                               size_t *written, uint32_t *crc_out)
{
    if (payload_len > BEALACH_MAX_PAYLOAD_SIZE) return BEALACH_ERR_PAYLOAD_TOO_LARGE;

    size_t frame_len = BEALACH_FRAME_OVERHEAD + payload_len;
    if (out_cap < frame_len) return BEALACH_ERR_BUFFER_TOO_SMALL;

    put_u16(out + 0, (uint16_t)frame_len);
    out[2] = record_type;
    out[3] = schema_version;
    put_u16(out + 4, flags);
    put_u16(out + 6, 0); /* reserved */
    put_u32(out + 8, seq);
    put_u32(out + 12, monotonic_ms);
    put_u32(out + 16, prev_crc32);
    put_u32(out + 20, 0); /* reserved2, aligns the sealed payload to 4 bytes */

    uint8_t *n   = out + BEALACH_FRAME_HEADER_SIZE;
    uint8_t *ct  = n + BEALACH_NONCE_SIZE;
    uint8_t *tag = ct + payload_len;

    memcpy(n, nonce, BEALACH_NONCE_SIZE);

    /*
     * The frame header is authenticated exactly as written — frame_len, seq and
     * prev_crc32 included — so a frame cannot be re-chained, renumbered or
     * resized without failing its tag. Frame header first, then the segment
     * header, matching §3.6 byte for byte.
     */
    bealach_xchacha20poly1305_seal2(c->key, n, out, BEALACH_FRAME_HEADER_SIZE,
                                  c->header_aad, c->header_aad_len, payload,
                                  payload_len, ct, tag);

    /* The CRC covers the sealed frame, so no key is needed to check it. */
    size_t   crc_span = frame_len - BEALACH_FRAME_TRAILER_SIZE;
    uint32_t crc      = bealach_crc32(out, crc_span);
    put_u32(out + crc_span, crc);

    if (written) *written = frame_len;
    if (crc_out) *crc_out = crc;

    return BEALACH_OK;
}

bealach_err_t bealach_open_frame(const bealach_segment_cipher_t *c, uint8_t *frame,
                             size_t frame_len, const uint8_t **payload,
                             size_t *payload_len)
{
    if (frame_len < BEALACH_MIN_FRAME_LEN) return BEALACH_ERR_AUTH_FAILED;

    size_t   n_len = frame_len - BEALACH_FRAME_OVERHEAD;
    uint8_t *nonce = frame + BEALACH_FRAME_HEADER_SIZE;
    uint8_t *ct    = nonce + BEALACH_NONCE_SIZE;
    uint8_t *tag   = ct + n_len;

    if (!bealach_xchacha20poly1305_open2(c->key, nonce, frame, BEALACH_FRAME_HEADER_SIZE,
                                       c->header_aad, c->header_aad_len, ct, n_len,
                                       tag, ct)) {
        return BEALACH_ERR_AUTH_FAILED;
    }

    if (payload) *payload = ct;
    if (payload_len) *payload_len = n_len;
    return BEALACH_OK;
}

/* ── the recovery scan ────────────────────────────────────────────────────── */

bealach_err_t bealach_scan_segment_stream(bealach_read_fn read, void *read_user,
                                      uint64_t len,
                                      bealach_scan_state_t state,
                                      const bealach_scan_opts_t *opts,
                                      bealach_scan_result_t *out)
{
    size_t header_len = 0;

    /*
     * One frame is resident at a time. A segment on the card is far larger than
     * ESP32 DRAM, and the recovery scan has to work without PSRAM being
     * present, so nothing here scales with segment size. The header buffer is
     * static for the same reason as the stage: a keyed scan holds up to
     * BEALACH_MAX_HEADER_LEN bytes of it as AAD, and so does the cipher, which is
     * static too — together they would be a large bite of a task stack.
     */
    static uint8_t                stage[BEALACH_MAX_FRAME_LEN];
    static uint8_t                head[BEALACH_MAX_HEADER_LEN];
    static bealach_segment_cipher_t cipher;

    bealach_key_fn   key_fn     = (opts != NULL) ? opts->key : NULL;
    bealach_frame_cb cb         = (opts != NULL) ? opts->on_frame : NULL;
    void          *cb_user    = (opts != NULL) ? opts->frame_user : NULL;

    memset(out, 0, sizeof(*out));

    if (len < BEALACH_SEGMENT_HEADER_SIZE) return BEALACH_ERR_SHORT_HEADER;
    if (!read(read_user, 0, head, BEALACH_SEGMENT_HEADER_SIZE)) return BEALACH_ERR_READ_FAILED;

    bealach_err_t err = bealach_parse_segment_header(head, BEALACH_SEGMENT_HEADER_SIZE,
                                                 &out->header, &header_len);
    if (err != BEALACH_OK) return err;
    if (header_len > len) return BEALACH_ERR_BAD_HEADER_LEN;
    out->header_len = header_len;

    if (key_fn != NULL) {
        /*
         * The whole header is the AAD, so a keyed scan needs every byte of it.
         * A structural scan needs only the fixed 128 and skips the rest.
         */
        if (header_len > BEALACH_MAX_HEADER_LEN) return BEALACH_ERR_BAD_HEADER_LEN;
        if (header_len > BEALACH_SEGMENT_HEADER_SIZE &&
            !read(read_user, BEALACH_SEGMENT_HEADER_SIZE, head + BEALACH_SEGMENT_HEADER_SIZE,
                  header_len - BEALACH_SEGMENT_HEADER_SIZE)) {
            return BEALACH_ERR_READ_FAILED;
        }

        uint8_t key[BEALACH_SEGMENT_KEY_SIZE];
        err = key_fn(opts->key_user, &out->header, key);
        if (err != BEALACH_OK) return err;

        err = bealach_segment_cipher_init(&cipher, key, head, header_len);
        memset(key, 0, sizeof(key));
        if (err != BEALACH_OK) return err;
        out->keyed = true;
    }

    /*
     * For a chain's first segment the caller has no prior state, so the
     * header's own first_seq establishes the expectation. The journal is the
     * first and only segment of its own chain.
     */
    uint32_t expected_seq = state.expected_seq;
    if ((out->header.segment_index == 0 ||
         out->header.segment_index == BEALACH_JOURNAL_SEGMENT_INDEX) &&
        state.expected_seq == 0 && state.expected_prev == 0) {
        expected_seq = out->header.first_seq;
    }
    uint32_t expected_prev = state.expected_prev;

    uint64_t offset = header_len;
    bool     have_first = false;

    for (;;) {
        uint64_t remaining = len - offset;

        if (remaining == 0) {
            out->stop = BEALACH_STOP_EOF;
            break;
        }
        if (remaining < BEALACH_MIN_FRAME_LEN) {
            out->stop = BEALACH_STOP_TORN_TAIL;
            break;
        }

        /* The length prefix comes first so a truncated frame is recognizable
         * without trusting anything inside it. */
        uint8_t lenbuf[2];
        if (!read(read_user, offset, lenbuf, sizeof(lenbuf))) {
            err = BEALACH_ERR_READ_FAILED;
            goto done;
        }

        size_t frame_len = get_u16(lenbuf);
        if (frame_len < BEALACH_MIN_FRAME_LEN || frame_len > BEALACH_MAX_FRAME_LEN) {
            out->stop = BEALACH_STOP_TORN_TAIL;
            break;
        }
        if (offset + frame_len > len) {
            out->stop = BEALACH_STOP_TORN_TAIL;
            break;
        }

        if (!read(read_user, offset, stage, frame_len)) {
            err = BEALACH_ERR_READ_FAILED;
            goto done;
        }

        uint8_t *body = stage;
        uint32_t stored_crc = get_u32(body + frame_len - BEALACH_FRAME_TRAILER_SIZE);
        uint32_t computed   = bealach_crc32(body, frame_len - BEALACH_FRAME_TRAILER_SIZE);

        if (computed != stored_crc) {
            out->stop = BEALACH_STOP_CORRUPT_FRAME;
            break;
        }

        bealach_frame_t f;
        f.record_type    = body[2];
        f.schema_version = body[3];
        f.flags          = get_u16(body + 4);
        f.seq            = get_u32(body + 8);
        f.monotonic_ms   = get_u32(body + 12);
        f.prev_crc32     = get_u32(body + 16);
        f.payload        = NULL;
        f.payload_len    = 0;
        f.decrypted      = false;
        f.sealed         = body + BEALACH_FRAME_HEADER_SIZE;
        f.sealed_len     = frame_len - BEALACH_FRAME_HEADER_SIZE - BEALACH_FRAME_TRAILER_SIZE;
        f.crc32          = stored_crc;

        /*
         * The chain detects a record that was removed, reordered or spliced —
         * each remaining frame would still be individually CRC-valid, so only
         * prev_crc32 can catch it.
         */
        if (f.prev_crc32 != expected_prev) {
            out->stop = BEALACH_STOP_CHAIN_BREAK;
            break;
        }
        if (f.seq != expected_seq) {
            out->stop = BEALACH_STOP_SEQ_GAP;
            break;
        }

        /*
         * Authentication comes after the structural checks, not before: those
         * need no key and must give the same verdict whether or not one is
         * held, so a damaged frame reports as damage rather than as an auth
         * failure. An auth failure stops the scan exactly as corruption does —
         * a frame whose authenticity is in doubt makes everything after it
         * equally doubtful — and is never skipped past.
         */
        if (out->keyed) {
            const uint8_t *pt = NULL;
            size_t         pt_len = 0;
            if (bealach_open_frame(&cipher, body, frame_len, &pt, &pt_len) != BEALACH_OK) {
                out->stop = BEALACH_STOP_AUTH_FAILED;
                break;
            }
            f.payload     = pt;
            f.payload_len = pt_len;
            f.decrypted   = true;
            f.sealed      = NULL; /* decrypted in place; the ciphertext is gone */
            f.sealed_len  = 0;
        }

        /*
         * An unknown record type is not an error: it is skipped via frame_len,
         * counted and reported. That is how a newer device stays partially
         * readable by an older decoder, and the frame CRC (and, keyed, the tag)
         * still applies so the skipped record remains integrity-checked.
         */
        if (!bealach_record_type_known(f.record_type)) out->unknown_type_count++;
        out->record_counts[f.record_type]++;

        if (!have_first) {
            out->first_seq = f.seq;
            have_first = true;
        }
        out->last_seq = f.seq;
        out->frames++;

        expected_seq  = f.seq + 1;
        expected_prev = stored_crc;
        offset       += frame_len;

        if (cb && !cb(&f, cb_user)) {
            out->stop = BEALACH_STOP_EOF;
            break;
        }
    }

    out->stop_offset          = (size_t)offset;
    out->discarded_tail_bytes = (uint32_t)(len - offset);
    out->next.expected_seq    = expected_seq;
    out->next.expected_prev   = expected_prev;
    err = BEALACH_OK;

done:
    /* The stage held plaintext after a keyed scan, and the cipher a key. */
    if (out->keyed) {
        bealach_segment_cipher_wipe(&cipher);
        memset(stage, 0, sizeof(stage));
    }
    return err;
}

/* ── the buffer entry point ───────────────────────────────────────────────── */

typedef struct {
    const uint8_t *buf;
    size_t         len;
} mem_reader_t;

static bool mem_read(void *user, uint64_t offset, uint8_t *dst, size_t len)
{
    const mem_reader_t *m = user;

    if (offset > m->len || len > m->len - offset) return false;
    memcpy(dst, m->buf + offset, len);
    return true;
}

/*
 * Thin wrapper over the streaming scan, so the in-memory path the conformance
 * vectors drive and the on-card path the firmware recovers through are the same
 * body of code. The buffer is never written: a keyed scan decrypts in the
 * stream's own stage, not in the caller's bytes.
 */
bealach_err_t bealach_scan_segment(const uint8_t *buf, size_t len,
                               bealach_scan_state_t state,
                               const bealach_scan_opts_t *opts,
                               bealach_scan_result_t *out)
{
    mem_reader_t m = { buf, len };
    return bealach_scan_segment_stream(mem_read, &m, len, state, opts, out);
}

/* ── payload builders ─────────────────────────────────────────────────────── */

void bealach_encode_gnss_sample(const bealach_gnss_sample_t *s, uint8_t out[32])
{
    memset(out, 0, 32);
    put_u32(out + 0, (uint32_t)s->lat_e7);
    put_u32(out + 4, (uint32_t)s->lon_e7);
    put_u32(out + 8, (uint32_t)s->alt_cm);
    put_u16(out + 12, s->speed_cmps);
    put_u16(out + 14, s->heading_cdeg);
    put_u16(out + 16, s->hdop_e2);
    put_u16(out + 18, s->h_acc_cm);
    put_u16(out + 20, s->v_acc_cm);
    out[22] = s->fix_type;
    out[23] = s->sats_used;
    out[24] = s->sats_visible;
    out[25] = s->source_flags;
    put_u32(out + 26, (uint32_t)s->utc_offset_ms);
    put_u16(out + 30, s->utc_acc_ms);
}

void bealach_encode_imu_summary(const bealach_imu_summary_t *s, uint8_t out[20])
{
    memset(out, 0, 20);
    put_u16(out + 0, s->window_ms);
    put_u16(out + 2, s->accel_rms_mg);
    put_u16(out + 4, (uint16_t)s->accel_peak_x_mg);
    put_u16(out + 6, (uint16_t)s->accel_peak_y_mg);
    put_u16(out + 8, (uint16_t)s->accel_peak_z_mg);
    put_u16(out + 10, (uint16_t)s->gyro_peak_dps_e1);
    put_u16(out + 12, s->variance);
    put_u16(out + 14, s->sample_count);
    out[16] = s->event_flags;
}

void bealach_encode_obd_snapshot(const bealach_obd_snapshot_t *s, uint8_t out[24])
{
    memset(out, 0, 24);
    put_u16(out + 0, (uint16_t)s->speed_kph);
    put_u16(out + 2, (uint16_t)s->rpm);
    put_u16(out + 4, s->fuel_pressure_kpa);
    out[6]  = s->throttle_pct;
    out[7]  = s->engine_load_pct;
    out[8]  = (uint8_t)s->coolant_temp_c;
    out[9]  = (uint8_t)s->intake_temp_c;
    out[10] = (uint8_t)s->timing_advance_deg;
    out[11] = s->pid_error_count;
    put_u32(out + 12, s->pids_requested);
    put_u32(out + 16, s->pids_answered);
    put_u16(out + 20, s->poll_cadence_ms);
}

void bealach_encode_obd_extended(const bealach_obd_extended_t *s, uint8_t out[24])
{
    memset(out, 0, 24);
    put_u16(out + 0, s->map_kpa);
    put_u16(out + 2, s->maf_cgps);
    put_u16(out + 4, s->lambda_e4);
    put_u16(out + 6, s->abs_load_raw);
    out[8]  = s->baro_kpa;
    out[9]  = (uint8_t)s->ambient_temp_c;
    out[10] = (uint8_t)s->fuel_trim_short_pct;
    out[11] = (uint8_t)s->fuel_trim_long_pct;
    put_u32(out + 12, s->pids_requested);
    put_u32(out + 16, s->pids_answered);
    put_u16(out + 20, s->poll_cadence_ms);
    out[22] = s->fuel_level_pct;
    out[23] = s->pedal_pct;
}

void bealach_encode_time_observation(const bealach_time_observation_t *s, uint8_t out[16])
{
    memset(out, 0, 16);
    put_u64(out + 0, s->utc_ms);
    put_u32(out + 8, s->acc_ms);
    out[12] = s->source;
    out[13] = s->flags;
}

void bealach_encode_device_health(const bealach_device_health_t *s, uint8_t out[16])
{
    memset(out, 0, 16);
    put_u16(out + 0, s->battery_mv);
    put_u16(out + 2, s->sd_write_errors);
    put_u16(out + 4, s->sd_free_mib);
    out[6] = (uint8_t)s->device_temp_c;
    out[7] = (uint8_t)s->rssi_dbm;
    put_u16(out + 8, s->ext_sensor_1);
    put_u16(out + 10, s->ext_sensor_2);
    out[12] = s->health_state;
    out[13] = s->reboot_count;
}

void bealach_encode_gnss_gap(const bealach_gnss_gap_t *s, uint8_t out[12])
{
    memset(out, 0, 12);
    put_u32(out + 0, s->duration_ms);
    put_u16(out + 4, s->expected_samples);
    out[6] = s->cause;
}

void bealach_encode_state_transition(const bealach_state_transition_t *s, uint8_t out[20])
{
    memset(out, 0, 20);
    out[0] = s->region;
    out[1] = s->from_state;
    out[2] = s->to_state;
    out[3] = s->trigger_event;
    out[4] = s->reason_code;
    out[5] = s->policy_version;
    put_u16(out + 8, s->start_score_e2);
    put_u16(out + 10, s->stop_score_e2);
    put_u32(out + 12, s->wake_cause);
}
