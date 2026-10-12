/* Provenance: cairn-esp32-device-firmware @ ead3532, lib/bealach_config/bealach_config.c
 * Renamed bealach_* → bealach_* for Bealach. Wire format markers unchanged. */

#include "bealach_config.h"

#include <string.h>

#include "bealach_format.h"
#include "bealach_kv.h"

/* ── small helpers ────────────────────────────────────────────────────────── */

/* Not dead-store eliminated: a volatile pointer is not. Used on anything decrypted. */
static void scrub(void *p, size_t n)
{
    volatile uint8_t *v = (volatile uint8_t *)p;
    while (n--) *v++ = 0;
}

static uint64_t get_le64(const uint8_t *p)
{
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
    return v;
}

static void put_le64(uint8_t *p, uint64_t v)
{
    for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i));
}

static void note(const bealach_config_ops_t *ops, const char *msg)
{
    if (ops && ops->log) ops->log(ops->ctx, msg);
}

const char *bealach_cfg_result_name(bealach_cfg_result_t r)
{
    switch (r) {
    case BEALACH_CFG_OK:                  return "ok";
    case BEALACH_CFG_RATE_LIMITED:        return "rate_limited";
    case BEALACH_CFG_MALFORMED:           return "malformed";
    case BEALACH_CFG_WRONG_DEVICE:        return "wrong_device";
    case BEALACH_CFG_UNAUTHORIZED_SIGNER: return "unauthorized_signer";
    case BEALACH_CFG_BAD_SIGNATURE:       return "bad_signature";
    case BEALACH_CFG_REPLAYED_COUNTER:    return "replayed_counter";
    case BEALACH_CFG_BAD_SEAL:            return "bad_seal";
    case BEALACH_CFG_UNKNOWN_FIELD:       return "unknown_field";
    case BEALACH_CFG_DUPLICATE_FIELD:     return "duplicate_field";
    case BEALACH_CFG_OUT_OF_RANGE:        return "out_of_range";
    case BEALACH_CFG_CREDENTIAL_REFUSED:  return "credential_refused";
    case BEALACH_CFG_STORE_FAILED:        return "store_failed";
    default:                            return "?";
    }
}

/* ── defaults ─────────────────────────────────────────────────────────────── */

void bealach_config_settings_defaults(bealach_config_settings_t *s)
{
    memset(s, 0, sizeof *s);
    s->lte_enabled = 0;
    s->lte_mode = 0;               /* digests only */
    s->lte_roaming = 0;
    s->lte_paused = 0;
    s->billing_day = 1;
    s->alert_pct = 80;
    s->wifi_slot_max_s = 90;
    s->wifi_slots_per_session = 2;
    s->home_scan_enabled = 1;      /* the owner accepted the no-phone scan */
}

/* ── persistence: two slots, the newer valid one wins ─────────────────────── */

#define SLOT_MAGIC 0x43464731u   /* "CFG1" */

typedef struct {
    uint32_t magic;
    uint32_t generation;
    uint64_t counter;
    bealach_config_settings_t settings;
    bealach_config_settings_t previous;
    uint8_t  have_previous;
    uint8_t  pad[3];
    uint32_t crc;
} stored_t;

static const char *slot_key(uint32_t generation) { return (generation & 1u) ? "cfg_b" : "cfg_a"; }

static uint32_t stored_crc(const stored_t *s)
{
    return bealach_crc32((const uint8_t *)s, offsetof(stored_t, crc));
}

static bool load_slot(const char *key, stored_t *out)
{
    if (!bealach_kv_get_blob(key, out, sizeof *out)) return false;
    return out->magic == SLOT_MAGIC && out->crc == stored_crc(out);
}

static bool persist(const bealach_config_t *c, uint32_t generation, uint64_t counter,
                    const bealach_config_settings_t *settings,
                    const bealach_config_settings_t *previous, bool have_previous)
{
    stored_t s;
    memset(&s, 0, sizeof s);
    s.magic = SLOT_MAGIC;
    s.generation = generation;
    s.counter = counter;
    s.settings = *settings;
    if (previous) s.previous = *previous;
    s.have_previous = have_previous ? 1 : 0;
    s.crc = stored_crc(&s);
    (void)c;
    return bealach_kv_set_blob(slot_key(generation), &s, sizeof s);
}

void bealach_config_init(bealach_config_t *c, const uint8_t device_id[16], const uint8_t enc_scalar[32],
                       const uint8_t enc_public[32])
{
    memset(c, 0, sizeof *c);
    memcpy(c->device_id, device_id, 16);
    memcpy(c->enc_scalar, enc_scalar, 32);
    memcpy(c->enc_public, enc_public, 32);
    bealach_config_settings_defaults(&c->settings);
    c->previous = c->settings;

    stored_t a, b, *best = NULL;
    bool va = load_slot("cfg_a", &a), vb = load_slot("cfg_b", &b);
    if (va && vb) best = (a.generation >= b.generation) ? &a : &b;
    else if (va)  best = &a;
    else if (vb)  best = &b;

    if (best) {
        c->settings = best->settings;
        c->previous = best->previous;
        c->have_previous = best->have_previous != 0;
        c->counter = best->counter;
        c->generation = best->generation;
    }
}

/* ── keys and the seal ────────────────────────────────────────────────────── */

bool bealach_config_derive_keys(const uint8_t seed[32], uint8_t scalar[32], uint8_t pub[32])
{
    static const char info[] = "cairn/config-key/v1";
    if (!bealach_hkdf_sha256(NULL, 0, seed, 32, (const uint8_t *)info, sizeof info - 1, scalar, 32))
        return false;
    return bealach_x25519_public(pub, scalar);
}

static bool seal_key(uint8_t key[32], const uint8_t shared[32], const uint8_t eph_pub[32],
                     const uint8_t device_pub[32])
{
    static const char info[] = "cairn/config-seal/v1";
    uint8_t salt[64];
    memcpy(salt, eph_pub, 32);
    memcpy(salt + 32, device_pub, 32);
    return bealach_hkdf_sha256(salt, 64, shared, 32, (const uint8_t *)info, sizeof info - 1, key, 32);
}

size_t bealach_config_build(uint8_t *out, size_t cap, const uint8_t device_id[16],
                          const uint8_t device_enc_pub[32], const uint8_t signer_seed[32],
                          const uint8_t signer_pub[32], uint64_t counter,
                          const uint8_t *payload, size_t payload_len,
                          const uint8_t eph_priv[32], const uint8_t nonce[24])
{
    if (payload_len == 0 || payload_len > BEALACH_CFG_MAX_PAYLOAD) return 0;
    size_t total = BEALACH_CFG_HEADER_LEN + payload_len + 16 + 64;
    if (cap < total) return 0;

    uint8_t eph_pub[32], shared[32], key[32];
    size_t ret = 0;

    if (!bealach_x25519_public(eph_pub, eph_priv)) goto out;
    if (!bealach_x25519(shared, eph_priv, device_enc_pub)) goto out;
    if (!seal_key(key, shared, eph_pub, device_enc_pub)) goto out;

    memset(out, 0, total);
    memcpy(out, "CCFG", 4);
    out[4] = 0;
    memcpy(out + 5, device_id, 16);
    memcpy(out + 21, signer_pub, 32);
    put_le64(out + 53, counter);
    memcpy(out + 61, eph_pub, 32);
    memcpy(out + 93, nonce, 24);
    out[117] = (uint8_t)payload_len;
    out[118] = (uint8_t)(payload_len >> 8);

    /* The header is the AAD, so device, signer, counter and key cannot be edited
     * without failing the tag. */
    bealach_xchacha20poly1305_seal(key, nonce, out, BEALACH_CFG_HEADER_LEN, payload, payload_len,
                                 out + BEALACH_CFG_HEADER_LEN,
                                 out + BEALACH_CFG_HEADER_LEN + payload_len);
    bealach_ed25519_sign(out, total - 64, signer_seed, signer_pub, out + total - 64);
    ret = total;

out:
    scrub(shared, sizeof shared);
    scrub(key, sizeof key);
    return ret;
}

/* ── rate limit and audit ─────────────────────────────────────────────────── */

#define RATE_WINDOW_MS   60000u
#define RATE_MAX_IN_WIN  10u

static bool rate_ok(bealach_config_t *c, uint32_t now)
{
    if (c->window_count == 0 || (int32_t)(now - c->window_start_ms) >= (int32_t)RATE_WINDOW_MS) {
        c->window_start_ms = now;
        c->window_count = 0;
    }
    if (c->window_count >= RATE_MAX_IN_WIN) return false;
    c->window_count++;
    return true;
}

static void audit(bealach_config_t *c, uint64_t counter, const uint8_t signer_id[4],
                  bealach_cfg_result_t r, uint32_t now)
{
    bealach_cfg_audit_t *a = &c->audit[c->audit_next];
    a->counter = counter;
    if (signer_id) memcpy(a->signer_id, signer_id, 4); else memset(a->signer_id, 0, 4);
    a->result = (uint8_t)r;
    a->at_ms = now;
    c->audit_next = (uint8_t)((c->audit_next + 1) % BEALACH_CFG_AUDIT_N);
    if (r != BEALACH_CFG_OK) c->rejected_total++;
}

/* ── the payload ──────────────────────────────────────────────────────────── */

typedef struct {
    bealach_cred_kind_t kind;
    size_t off, len;            /* the field's CBOR bytes inside the decrypted payload */
} cred_span_t;

#define MAX_CREDS 3

typedef struct {
    bealach_config_settings_t next;
    cred_span_t creds[MAX_CREDS];
    size_t ncreds;
} parsed_t;

static bool read_u(bealach_cbor_dec_t *d, uint64_t max, uint64_t *v)
{
    if (bealach_cbor_uint_read(d, v) != BEALACH_OK) return false;
    return *v <= max;
}

static bealach_cfg_result_t parse_payload(const uint8_t *p, size_t len, const bealach_config_settings_t *cur,
                                        parsed_t *out)
{
    bealach_cbor_dec_t d;
    bealach_cbor_dec_init(&d, p, len);
    out->next = *cur;
    out->ncreds = 0;

    size_t n;
    if (bealach_cbor_map_header(&d, &n) != BEALACH_OK) return BEALACH_CFG_MALFORMED;
    if (n == 0 || n > 32) return BEALACH_CFG_MALFORMED;

    int64_t last = -1;
    for (size_t i = 0; i < n; i++) {
        uint64_t key, v;
        if (bealach_cbor_uint_read(&d, &key) != BEALACH_OK) return BEALACH_CFG_MALFORMED;
        if ((int64_t)key == last) return BEALACH_CFG_DUPLICATE_FIELD;
        if ((int64_t)key < last) return BEALACH_CFG_MALFORMED;      /* not canonical */
        last = (int64_t)key;

        switch (key) {
        case BEALACH_CFG_KEY_LTE_ENABLED:
            if (!read_u(&d, 1, &v)) return BEALACH_CFG_OUT_OF_RANGE;
            out->next.lte_enabled = (uint8_t)v; break;
        case BEALACH_CFG_KEY_LTE_MODE:
            if (!read_u(&d, 1, &v)) return BEALACH_CFG_OUT_OF_RANGE;
            out->next.lte_mode = (uint8_t)v; break;
        case BEALACH_CFG_KEY_MONTHLY_KB:
            if (!read_u(&d, BEALACH_CFG_CAP_KB_MAX, &v)) return BEALACH_CFG_OUT_OF_RANGE;
            out->next.lte_monthly_cap_kb = (uint32_t)v; break;
        case BEALACH_CFG_KEY_DAILY_KB:
            if (!read_u(&d, BEALACH_CFG_CAP_KB_MAX, &v)) return BEALACH_CFG_OUT_OF_RANGE;
            out->next.lte_daily_cap_kb = (uint32_t)v; break;
        case BEALACH_CFG_KEY_TRIP_KB:
            if (!read_u(&d, BEALACH_CFG_CAP_KB_MAX, &v)) return BEALACH_CFG_OUT_OF_RANGE;
            out->next.lte_trip_cap_kb = (uint32_t)v; break;
        case BEALACH_CFG_KEY_BILLING_DAY:
            if (!read_u(&d, 28, &v) || v < 1) return BEALACH_CFG_OUT_OF_RANGE;
            out->next.billing_day = (uint8_t)v; break;
        case BEALACH_CFG_KEY_ROAMING:
            if (!read_u(&d, 1, &v)) return BEALACH_CFG_OUT_OF_RANGE;
            out->next.lte_roaming = (uint8_t)v; break;
        case BEALACH_CFG_KEY_PAUSED:
            if (!read_u(&d, 1, &v)) return BEALACH_CFG_OUT_OF_RANGE;
            out->next.lte_paused = (uint8_t)v; break;
        case BEALACH_CFG_KEY_ALERT_PCT:
            if (!read_u(&d, 100, &v) || v < 1) return BEALACH_CFG_OUT_OF_RANGE;
            out->next.alert_pct = (uint8_t)v; break;
        case BEALACH_CFG_KEY_SLOT_MAX_S:
            if (!read_u(&d, BEALACH_CFG_SLOT_MAX_S_MAX, &v) || v < BEALACH_CFG_SLOT_MAX_S_MIN)
                return BEALACH_CFG_OUT_OF_RANGE;
            out->next.wifi_slot_max_s = (uint16_t)v; break;
        case BEALACH_CFG_KEY_SLOTS:
            if (!read_u(&d, BEALACH_CFG_SLOTS_MAX, &v) || v < 1) return BEALACH_CFG_OUT_OF_RANGE;
            out->next.wifi_slots_per_session = (uint8_t)v; break;
        case BEALACH_CFG_KEY_HOME_SCAN:
            if (!read_u(&d, 1, &v)) return BEALACH_CFG_OUT_OF_RANGE;
            out->next.home_scan_enabled = (uint8_t)v; break;

        case BEALACH_CFG_KEY_APN:
        case BEALACH_CFG_KEY_SIM_PIN: {
            char text[BEALACH_CFG_PSK_MAX + 1];
            size_t start = d.pos;
            if (bealach_cbor_text_read(&d, text, sizeof text) != BEALACH_OK) return BEALACH_CFG_MALFORMED;
            size_t tl = strlen(text);
            bool pin = (key == BEALACH_CFG_KEY_SIM_PIN);
            if (tl == 0 || tl > (pin ? 8u : 63u)) { scrub(text, sizeof text); return BEALACH_CFG_OUT_OF_RANGE; }
            scrub(text, sizeof text);
            if (out->ncreds >= MAX_CREDS) return BEALACH_CFG_MALFORMED;
            out->creds[out->ncreds].kind = pin ? BEALACH_CRED_SIM_PIN : BEALACH_CRED_APN;
            out->creds[out->ncreds].off = start;
            out->creds[out->ncreds].len = d.pos - start;
            out->ncreds++;
            break;
        }

        case BEALACH_CFG_KEY_WIFI_NETWORKS: {
            size_t start = d.pos, nn;
            if (bealach_cbor_array_header(&d, &nn) != BEALACH_OK) return BEALACH_CFG_MALFORMED;
            if (nn > BEALACH_CFG_MAX_NETWORKS) return BEALACH_CFG_OUT_OF_RANGE;
            for (size_t k = 0; k < nn; k++) {
                size_t pair;
                char ssid[BEALACH_CFG_SSID_MAX + 1], psk[BEALACH_CFG_PSK_MAX + 1];
                if (bealach_cbor_array_header(&d, &pair) != BEALACH_OK || pair != 2) return BEALACH_CFG_MALFORMED;
                bealach_err_t e1 = bealach_cbor_text_read(&d, ssid, sizeof ssid);
                bealach_err_t e2 = (e1 == BEALACH_OK) ? bealach_cbor_text_read(&d, psk, sizeof psk) : e1;
                size_t sl = strlen(ssid), pl = strlen(psk);
                scrub(psk, sizeof psk);
                scrub(ssid, sizeof ssid);
                if (e2 != BEALACH_OK) return BEALACH_CFG_OUT_OF_RANGE;
                /* No zero-length SSID; a passphrase is empty (open) or 8..63. */
                if (sl == 0) return BEALACH_CFG_OUT_OF_RANGE;
                if (pl != 0 && pl < 8) return BEALACH_CFG_OUT_OF_RANGE;
            }
            if (out->ncreds >= MAX_CREDS) return BEALACH_CFG_MALFORMED;
            out->creds[out->ncreds].kind = BEALACH_CRED_WIFI_NETWORKS;
            out->creds[out->ncreds].off = start;
            out->creds[out->ncreds].len = d.pos - start;
            out->ncreds++;
            break;
        }

        default:
            return BEALACH_CFG_UNKNOWN_FIELD;
        }
    }

    if (d.pos != len) return BEALACH_CFG_MALFORMED;      /* trailing bytes */

    /* Cross-field sanity: a per-trip cap above the monthly one asks for something the
     * monthly cap will never allow; refuse rather than guess which was meant. */
    if (out->next.lte_monthly_cap_kb && out->next.lte_daily_cap_kb &&
        out->next.lte_daily_cap_kb > out->next.lte_monthly_cap_kb)
        return BEALACH_CFG_OUT_OF_RANGE;
    if (out->next.lte_monthly_cap_kb && out->next.lte_trip_cap_kb &&
        out->next.lte_trip_cap_kb > out->next.lte_monthly_cap_kb)
        return BEALACH_CFG_OUT_OF_RANGE;
    return BEALACH_CFG_OK;
}

/* ── receive ──────────────────────────────────────────────────────────────── */

typedef struct {
    uint64_t counter;
    uint8_t  signer_id[4];
    bool     have_signer;
} info_t;

static bealach_cfg_result_t process(bealach_config_t *c, const bealach_config_ops_t *ops,
                                  const uint8_t *msg, size_t len, uint8_t *scratch,
                                  size_t scratch_cap, info_t *info)
{
    if (len < BEALACH_CFG_MIN_MSG || len > BEALACH_CFG_MAX_MSG) return BEALACH_CFG_MALFORMED;
    if (memcmp(msg, "CCFG", 4) != 0 || msg[4] != 0) return BEALACH_CFG_MALFORMED;
    if (scratch_cap < BEALACH_CFG_SCRATCH_MIN) return BEALACH_CFG_MALFORMED;

    size_t ct_len = (size_t)msg[117] | ((size_t)msg[118] << 8);
    if (ct_len == 0 || ct_len > BEALACH_CFG_MAX_PAYLOAD) return BEALACH_CFG_MALFORMED;
    if (len != BEALACH_CFG_HEADER_LEN + ct_len + 16 + 64) return BEALACH_CFG_MALFORMED;

    if (memcmp(msg + 5, c->device_id, 16) != 0) return BEALACH_CFG_WRONG_DEVICE;

    const uint8_t *signer = msg + 21;
    uint8_t digest[32];
    bealach_sha256(signer, 32, digest);
    memcpy(info->signer_id, digest, 4);
    info->have_signer = true;
    info->counter = get_le64(msg + 53);

    if (!ops->signer_authorized || !ops->signer_authorized(ops->ctx, signer))
        return BEALACH_CFG_UNAUTHORIZED_SIGNER;

    if (!bealach_ed25519_verify(msg, len - 64, msg + len - 64, signer)) return BEALACH_CFG_BAD_SIGNATURE;

    /* Strictly greater: an equal counter is a replay, and a lower one is a rollback. */
    if (info->counter <= c->counter) return BEALACH_CFG_REPLAYED_COUNTER;

    uint8_t shared[32], key[32];
    bealach_cfg_result_t r = BEALACH_CFG_BAD_SEAL;
    bool opened = false;

    if (bealach_x25519(shared, c->enc_scalar, msg + 61) &&
        seal_key(key, shared, msg + 61, c->enc_public) &&
        bealach_xchacha20poly1305_open(key, msg + 93, msg, BEALACH_CFG_HEADER_LEN,
                                     msg + BEALACH_CFG_HEADER_LEN, ct_len,
                                     msg + BEALACH_CFG_HEADER_LEN + ct_len, scratch)) {
        opened = true;
    }
    scrub(shared, sizeof shared);
    scrub(key, sizeof key);
    if (!opened) return r;

    parsed_t pr;
    r = parse_payload(scratch, ct_len, &c->settings, &pr);
    if (r != BEALACH_CFG_OK) goto done;

    /* The credential gate. Whole message or nothing: a message that carries a credential
     * the dongle may not hold is refused in full, settings included. */
    if (pr.ncreds > 0) {
        bool enc = ops->storage_encrypted && ops->storage_encrypted(ops->ctx);
        if (!enc || !ops->store_credential) {
            c->refused_credentials += (uint32_t)pr.ncreds;
            note(ops, "config: credential field refused, storage is not encrypted");
            r = BEALACH_CFG_CREDENTIAL_REFUSED;
            goto done;
        }
        for (size_t i = 0; i < pr.ncreds; i++) {
            if (!ops->store_credential(ops->ctx, pr.creds[i].kind, scratch + pr.creds[i].off,
                                       pr.creds[i].len)) {
                r = BEALACH_CFG_STORE_FAILED;
                goto done;
            }
        }
    }

    /* Apply: the inactive slot first, so a power cut leaves the previous good one in force. */
    {
        uint32_t gen = c->generation + 1;
        if (!persist(c, gen, info->counter, &pr.next, &c->settings, true)) {
            r = BEALACH_CFG_STORE_FAILED;
            goto done;
        }
        c->previous = c->settings;
        c->have_previous = true;
        c->settings = pr.next;
        c->counter = info->counter;
        c->generation = gen;
        r = BEALACH_CFG_OK;
    }

done:
    scrub(&pr, sizeof pr);
    scrub(scratch, ct_len);
    return r;
}

bealach_cfg_result_t bealach_config_receive(bealach_config_t *c, const bealach_config_ops_t *ops,
                                        const uint8_t *msg, size_t len, uint32_t now_ms,
                                        uint8_t *scratch, size_t scratch_cap)
{
    if (!rate_ok(c, now_ms)) {
        c->rejected_total++;
        return BEALACH_CFG_RATE_LIMITED;
    }

    info_t info;
    memset(&info, 0, sizeof info);
    bealach_cfg_result_t r = process(c, ops, msg, len, scratch, scratch_cap, &info);
    audit(c, info.counter, info.have_signer ? info.signer_id : NULL, r, now_ms);
    return r;
}

bool bealach_config_rollback(bealach_config_t *c)
{
    if (!c->have_previous) return false;
    uint32_t gen = c->generation + 1;
    /* The counter stays where it is: a rollback must not reopen the door to replays. */
    if (!persist(c, gen, c->counter, &c->previous, &c->settings, true)) return false;
    bealach_config_settings_t tmp = c->settings;
    c->settings = c->previous;
    c->previous = tmp;
    c->generation = gen;
    return true;
}

/* ── report ───────────────────────────────────────────────────────────────── */

static size_t encode_settings(const bealach_config_settings_t *s, uint8_t *buf, size_t cap)
{
    bealach_cbor_enc_t e;
    bealach_cbor_init(&e, buf, cap);
    bealach_cbor_map(&e, 12);
    bealach_cbor_key(&e, BEALACH_CFG_KEY_LTE_ENABLED); bealach_cbor_uint(&e, s->lte_enabled);
    bealach_cbor_key(&e, BEALACH_CFG_KEY_LTE_MODE);    bealach_cbor_uint(&e, s->lte_mode);
    bealach_cbor_key(&e, BEALACH_CFG_KEY_MONTHLY_KB);  bealach_cbor_uint(&e, s->lte_monthly_cap_kb);
    bealach_cbor_key(&e, BEALACH_CFG_KEY_DAILY_KB);    bealach_cbor_uint(&e, s->lte_daily_cap_kb);
    bealach_cbor_key(&e, BEALACH_CFG_KEY_TRIP_KB);     bealach_cbor_uint(&e, s->lte_trip_cap_kb);
    bealach_cbor_key(&e, BEALACH_CFG_KEY_BILLING_DAY); bealach_cbor_uint(&e, s->billing_day);
    bealach_cbor_key(&e, BEALACH_CFG_KEY_ROAMING);     bealach_cbor_uint(&e, s->lte_roaming);
    bealach_cbor_key(&e, BEALACH_CFG_KEY_PAUSED);      bealach_cbor_uint(&e, s->lte_paused);
    bealach_cbor_key(&e, BEALACH_CFG_KEY_ALERT_PCT);   bealach_cbor_uint(&e, s->alert_pct);
    bealach_cbor_key(&e, BEALACH_CFG_KEY_SLOT_MAX_S);  bealach_cbor_uint(&e, s->wifi_slot_max_s);
    bealach_cbor_key(&e, BEALACH_CFG_KEY_SLOTS);       bealach_cbor_uint(&e, s->wifi_slots_per_session);
    bealach_cbor_key(&e, BEALACH_CFG_KEY_HOME_SCAN);   bealach_cbor_uint(&e, s->home_scan_enabled);
    return e.overflow ? 0 : e.len;
}

void bealach_config_report(const bealach_config_t *c, const bealach_config_ops_t *ops,
                         bealach_config_report_t *out)
{
    memset(out, 0, sizeof *out);
    out->settings = c->settings;
    out->counter = c->counter;

    static const char label[] = "cairn/config-state/v1";
    uint8_t buf[sizeof label - 1 + 160 + 8];
    memcpy(buf, label, sizeof label - 1);
    size_t n = encode_settings(&c->settings, buf + sizeof label - 1, 160);
    put_le64(buf + sizeof label - 1 + n, c->counter);
    bealach_sha256(buf, sizeof label - 1 + n + 8, out->state_hash);

    out->credentials_accepted = ops && ops->storage_encrypted && ops->storage_encrypted(ops->ctx) &&
                                ops->store_credential != NULL;
    out->refused_credentials = c->refused_credentials;
    out->rejected_total = c->rejected_total;

    /* Oldest first. Slots never written have result 0 and counter 0 and are skipped via
     * the next-slot walk below; track how many have been filled. */
    uint8_t count = 0;
    for (uint8_t i = 0; i < BEALACH_CFG_AUDIT_N; i++) {
        const bealach_cfg_audit_t *a = &c->audit[(c->audit_next + i) % BEALACH_CFG_AUDIT_N];
        if (a->at_ms == 0 && a->counter == 0 && a->result == 0) continue;
        out->audit[count++] = *a;
    }
    out->audit_count = count;
}
