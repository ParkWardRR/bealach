/* Provenance: cairn-esp32-device-firmware @ ead3532, lib/bealach_engine/bealach_engine.c
 * Renamed bealach_* → bealach_* for Bealach. Wire format markers unchanged. */

#include "bealach_engine.h"

#include <stdio.h>
#include <string.h>

#include "config.h"

/*
 * The tables. `make firmware ENGINES=...` writes bealach_engines_sel.h into build/engines/
 * and puts that directory on the include path, so the image carries exactly the
 * selection. A plain `pio run` (and the host tests) find no such file and use the
 * committed copy for ALL engines, which `make engines-check` keeps in step with
 * the engines/ YAML files.
 */
#if defined(__has_include)
#if __has_include("bealach_engines_sel.h")
#include "bealach_engines_sel.h"
#else
#include "gen/bealach_engines_gen.h"
#endif
#else
#include "gen/bealach_engines_gen.h"
#endif

/* ── identity and registry ────────────────────────────────────────────────── */

const bealach_engine_identity_t *bealach_engine_identity(void)
{
    return &k_engine_identity;
}

size_t bealach_engine_installed_count(void)
{
    return sizeof(k_engine_profiles) / sizeof(k_engine_profiles[0]);
}

const bealach_engine_profile_t *bealach_engine_installed(size_t i)
{
    return i < bealach_engine_installed_count() ? k_engine_profiles[i] : NULL;
}

const bealach_engine_profile_t *bealach_engine_find(const char *id)
{
    size_t i;
    if (id == NULL) return NULL;
    for (i = 0; i < bealach_engine_installed_count(); i++) {
        if (strcmp(k_engine_profiles[i]->id, id) == 0) return k_engine_profiles[i];
    }
    return NULL;
}

const bealach_engine_catalogue_entry_t *bealach_engine_catalogue(void)
{
    return k_engine_catalogue;
}

size_t bealach_engine_catalogue_count(void)
{
    return sizeof(k_engine_catalogue) / sizeof(k_engine_catalogue[0]);
}

/* ── the active profile and its resolved values ──────────────────────────── */

static const bealach_engine_profile_t *s_active;
static bealach_engine_params_t         s_params;

static void resolve(const bealach_engine_profile_t *p)
{
    bealach_engine_params_t r;
    uint32_t k = (p != NULL) ? p->known : 0;

    /* The defaults are what the firmware did before profiles existed (config.h). */
    r.obd_period_ms          = BEALACH_OBD_PERIOD_MS;
    r.obd_batch_period_ms    = BEALACH_OBD_BATCH_PERIOD_MS;
    r.cold_slots             = 1;
    r.engine_on_mv           = BEALACH_ENGINE_ON_MV;
    r.standby_idle_ms        = BEALACH_STANDBY_IDLE_MS;
    r.standby_heartbeat_ms   = BEALACH_STANDBY_HEARTBEAT_MS;
    r.drive_voltage_dwell_ms = BEALACH_DRIVE_VOLTAGE_DWELL_MS;
    r.drive_motion_dwell_ms  = BEALACH_DRIVE_MOTION_DWELL_MS;
    r.drive_both_dwell_ms    = BEALACH_DRIVE_BOTH_DWELL_MS;
    r.from_profile           = 0;

    if (k & BEALACH_K_OBD_PERIOD)          r.obd_period_ms = p->obd_period_ms;
    if (k & BEALACH_K_OBD_BATCH_PERIOD)    r.obd_batch_period_ms = p->obd_batch_period_ms;
    if ((k & BEALACH_K_COLD_SLOTS) && p->cold_slots > 0) r.cold_slots = p->cold_slots;
    if (k & BEALACH_K_ENGINE_ON_MV)        r.engine_on_mv = p->engine_on_mv;
    if (k & BEALACH_K_STANDBY_IDLE)        r.standby_idle_ms = p->standby_idle_ms;
    if (k & BEALACH_K_STANDBY_HEARTBEAT)   r.standby_heartbeat_ms = p->standby_heartbeat_ms;
    if (k & BEALACH_K_DRIVE_VOLTAGE_DWELL) r.drive_voltage_dwell_ms = p->drive_voltage_dwell_ms;
    if (k & BEALACH_K_DRIVE_MOTION_DWELL)  r.drive_motion_dwell_ms = p->drive_motion_dwell_ms;
    if (k & BEALACH_K_DRIVE_BOTH_DWELL)    r.drive_both_dwell_ms = p->drive_both_dwell_ms;

    r.from_profile = k & (BEALACH_K_OBD_PERIOD | BEALACH_K_OBD_BATCH_PERIOD |
                          BEALACH_K_COLD_SLOTS | BEALACH_K_ENGINE_ON_MV |
                          BEALACH_K_STANDBY_IDLE | BEALACH_K_STANDBY_HEARTBEAT |
                          BEALACH_K_DRIVE_VOLTAGE_DWELL | BEALACH_K_DRIVE_MOTION_DWELL |
                          BEALACH_K_DRIVE_BOTH_DWELL);
    if ((k & BEALACH_K_COLD_SLOTS) && p->cold_slots == 0) {
        r.from_profile &= ~BEALACH_K_COLD_SLOTS;
    }

    s_params = r;
    s_active = p;
}

void bealach_engine_select_default(void)
{
    const bealach_engine_profile_t *pick = NULL;
    size_t i;

    for (i = 0; i < bealach_engine_installed_count(); i++) {
        if (k_engine_profiles[i]->status != BEALACH_ENGINE_STUB) {
            pick = k_engine_profiles[i];
            break;
        }
    }
    if (pick == NULL) pick = bealach_engine_installed(0);
    resolve(pick);
}

bool bealach_engine_select(const char *id)
{
    const bealach_engine_profile_t *p = bealach_engine_find(id);
    if (p == NULL) return false;
    resolve(p);
    return true;
}

const bealach_engine_profile_t *bealach_engine_active(void)
{
    /* Normally already chosen at boot; this covers a caller that got here first. */
    if (s_active == NULL) bealach_engine_select_default();
    return s_active;
}

const bealach_engine_params_t *bealach_engine_params(void)
{
    if (s_active == NULL) bealach_engine_select_default();
    return &s_params;
}

bool bealach_engine_has_pids(void)
{
    const bealach_engine_profile_t *p = bealach_engine_active();
    return p != NULL && (p->known & BEALACH_K_PIDS) != 0 && p->n_pids > 0;
}

/* ── PIDs ─────────────────────────────────────────────────────────────────── */

const bealach_pid_t *bealach_engine_pid_for_field(const bealach_engine_profile_t *p,
                                              bealach_field_t f)
{
    uint8_t i;
    if (p == NULL || p->pids == NULL) return NULL;
    for (i = 0; i < p->n_pids; i++) {
        if (p->pids[i].field == (uint8_t)f) return &p->pids[i];
    }
    return NULL;
}

bealach_expr_status_t bealach_engine_eval_pid(const bealach_engine_profile_t *p,
                                          const bealach_pid_t *pid,
                                          const uint8_t data[4], int32_t *out)
{
    if (p == NULL || pid == NULL || p->code == NULL) return BEALACH_EXPR_ERR_ARG;
    return bealach_expr_eval(p->code + pid->code_off, pid->code_len, data, out);
}

size_t bealach_engine_batch_request(const bealach_engine_profile_t *p, char *buf,
                                  size_t cap)
{
    static const char hexd[] = "0123456789ABCDEF";
    size_t k = 0;
    uint8_t i;

    if (p == NULL || buf == NULL || p->pids == NULL || p->n_hot == 0) return 0;
    /* "01", two digits per PID, '\r', NUL */
    if (cap < 2u + 2u * p->n_hot + 2u) return 0;

    buf[k++] = '0';
    buf[k++] = '1';
    for (i = 0; i < p->n_hot; i++) {
        uint8_t pid = (uint8_t)p->pids[i].pid;
        buf[k++] = hexd[pid >> 4];
        buf[k++] = hexd[pid & 0x0F];
    }
    buf[k++] = '\r';
    buf[k]   = '\0';
    return k;
}

bool bealach_engine_batch_parse(const bealach_engine_profile_t *p, const uint8_t *bytes,
                              size_t n, int32_t values[BEALACH_FIELD_COUNT],
                              uint32_t *present)
{
    size_t  pos = 0;
    int     f;

    if (p == NULL || bytes == NULL || values == NULL || present == NULL ||
        p->pids == NULL || p->n_hot == 0) {
        return false;
    }

    for (f = 0; f < BEALACH_FIELD_COUNT; f++) values[f] = 0;
    *present = 0;

    /*
     * Walk whatever the ECU sent, keyed on the PID byte, rather than asserting
     * the reply mirrors the request.
     *
     * This used to demand the full expected byte count and each PID in request
     * order, failing the whole batch otherwise. On the 2026-10-07 drive that
     * threw away almost every batch: 225 of 239 samples came from the sequential
     * fallback at 1200 ms, against the 56 ms this path costs when it is accepted.
     * A reply carrying five of six PIDs, or carrying them reordered, is still
     * five good simultaneous measurements, and discarding them bought nothing.
     *
     * `present` already describes the result per field and every caller tests it
     * per field, so a partial batch has always been representable -- only this
     * function refused to produce one.
     *
     * Still strict about the things that would corrupt data rather than thin it:
     * a PID the active profile does not list as hot ends the parse, because
     * without knowing its length there is no way to find the next pair and
     * everything after it would be read at the wrong offset. Same for a pair
     * whose data bytes are not all present.
     */
    while (pos < n) {
        const bealach_pid_t *pid = NULL;
        uint8_t data[4] = { 0, 0, 0, 0 };
        int32_t v;
        uint8_t i, j;

        for (i = 0; i < p->n_hot; i++) {
            if ((uint8_t)p->pids[i].pid == bytes[pos]) {
                pid = &p->pids[i];
                break;
            }
        }
        if (pid == NULL) break;
        if (n - pos < (size_t)1u + pid->nbytes) break;

        pos++;
        for (j = 0; j < pid->nbytes && j < 4; j++) data[j] = bytes[pos++];

        if (bealach_engine_eval_pid(p, pid, data, &v) != BEALACH_EXPR_OK) break;
        if (pid->field != BEALACH_FIELD_NONE && pid->field < BEALACH_FIELD_COUNT) {
            values[pid->field] = v;
            *present |= 1u << pid->field;
        }
    }

    /* One field is a usable batch; none is not. */
    return *present != 0;
}

uint32_t bealach_engine_hot_field_mask(const bealach_engine_profile_t *p)
{
    uint32_t mask = 0;
    uint8_t  i;

    if (p == NULL || p->pids == NULL) return 0;

    for (i = 0; i < p->n_hot; i++) {
        if (p->pids[i].field != BEALACH_FIELD_NONE &&
            p->pids[i].field < BEALACH_FIELD_COUNT) {
            mask |= 1u << p->pids[i].field;
        }
    }
    return mask;
}

/* ── vehicle gate ─────────────────────────────────────────────────────────── */

const char *bealach_vehicle_verdict_name(bealach_vehicle_verdict_t v)
{
    switch (v) {
    case BEALACH_VEHICLE_UNIDENTIFIED:            return "UNIDENTIFIED";
    case BEALACH_VEHICLE_SERVED:                  return "SERVED";
    case BEALACH_VEHICLE_REFUSED_NOT_INSTALLED:   return "REFUSED_NOT_INSTALLED";
    case BEALACH_VEHICLE_REFUSED_UNKNOWN_ENGINE:  return "REFUSED_UNKNOWN_ENGINE";
    default:                                    return "?";
    }
}

bool bealach_vin_matches(const char *pattern, const char *vin)
{
    size_t i;
    if (pattern == NULL || vin == NULL) return false;
    if (strlen(pattern) != 17 || strlen(vin) != 17) return false;
    for (i = 0; i < 17; i++) {
        if (pattern[i] != '?' && pattern[i] != vin[i]) return false;
    }
    return true;
}

static const bealach_engine_catalogue_entry_t *cat_find(
    const bealach_engine_catalogue_entry_t *cat, size_t n, const char *id)
{
    size_t i;
    for (i = 0; i < n; i++) {
        if (strcmp(cat[i].id, id) == 0) return &cat[i];
    }
    return NULL;
}

bealach_vehicle_verdict_t bealach_engine_check_vehicle_in(
    const bealach_engine_catalogue_entry_t *cat, size_t n, const char *declared_id,
    const char *vin, const char **engine_id)
{
    const bealach_engine_catalogue_entry_t *hit = NULL;
    size_t i, j;

    if (engine_id != NULL) *engine_id = NULL;

    if (declared_id != NULL && declared_id[0] != '\0') {
        hit = cat_find(cat, n, declared_id);
        if (hit == NULL) return BEALACH_VEHICLE_REFUSED_UNKNOWN_ENGINE;
        if (engine_id != NULL) *engine_id = hit->id;
        return hit->installed ? BEALACH_VEHICLE_SERVED
                              : BEALACH_VEHICLE_REFUSED_NOT_INSTALLED;
    }

    if (vin == NULL || strlen(vin) != 17) return BEALACH_VEHICLE_UNIDENTIFIED;

    for (i = 0; i < n; i++) {
        for (j = 0; j < cat[i].n_vin_patterns; j++) {
            if (bealach_vin_matches(cat[i].vin_patterns[j], vin)) {
                if (hit != NULL && hit != &cat[i]) {
                    /* Two engines claim this VIN. A contradiction is no evidence. */
                    return BEALACH_VEHICLE_UNIDENTIFIED;
                }
                hit = &cat[i];
            }
        }
    }
    if (hit == NULL) return BEALACH_VEHICLE_UNIDENTIFIED;

    if (engine_id != NULL) *engine_id = hit->id;
    return hit->installed ? BEALACH_VEHICLE_SERVED
                          : BEALACH_VEHICLE_REFUSED_NOT_INSTALLED;
}

bealach_vehicle_verdict_t bealach_engine_check_vehicle(const char *declared_id,
                                                   const char *vin,
                                                   const char **engine_id)
{
    return bealach_engine_check_vehicle_in(
        k_engine_catalogue,
        sizeof(k_engine_catalogue) / sizeof(k_engine_catalogue[0]), declared_id, vin,
        engine_id);
}

/* ── VIN engine code extraction ──────────────────────────────────────────── */

bool bealach_vin_extract_code(const char *vin, uint8_t pos, uint8_t len,
                            char *out, size_t out_cap)
{
    size_t vin_len, i;

    if (vin == NULL || out == NULL || out_cap == 0) return false;
    vin_len = strlen(vin);
    if ((size_t)pos + (size_t)len > vin_len) return false;
    if (len >= out_cap) return false; /* need room for NUL */

    for (i = 0; i < (size_t)len; i++) out[i] = vin[pos + i];
    out[len] = '\0';
    return true;
}

const bealach_engine_catalogue_entry_t *bealach_engine_match_code_in(
    const bealach_engine_catalogue_entry_t *cat, size_t n,
    const char *code, uint8_t code_len)
{
    size_t i, j;

    if (cat == NULL || code == NULL || code_len == 0) return NULL;

    for (i = 0; i < n; i++) {
        for (j = 0; j < cat[i].n_engine_codes; j++) {
            const char *ec = cat[i].engine_codes[j];
            if (ec == NULL) continue;
            if ((uint8_t)strlen(ec) == code_len &&
                memcmp(ec, code, code_len) == 0) {
                return &cat[i];
            }
        }
    }
    return NULL;
}

const bealach_engine_catalogue_entry_t *bealach_engine_match_code(
    const bealach_engine_catalogue_entry_t *cat, size_t n, const char *vin)
{
    /*
     * Match VIN positions 4-8 (0-indexed 3-7) against the catalogue's
     * engine_codes entries. Each entry is a short string (typically 4-5 chars)
     * representing the engine variant in the VIN's VDS section.
     */
    size_t i, j;

    if (vin == NULL || strlen(vin) < 8) return NULL;

    for (i = 0; i < n; i++) {
        for (j = 0; j < cat[i].n_engine_codes; j++) {
            const char *ec = cat[i].engine_codes[j];
            if (ec == NULL) continue;
            uint8_t len = (uint8_t)strlen(ec);
            if (len == 0 || (size_t)3 + (size_t)len > strlen(vin)) continue;
            if (memcmp(ec, vin + 3, len) == 0) {
                return &cat[i];
            }
        }
    }
    return NULL;
}

/* ── BLE companion engine declaration ────────────────────────────────────── */

static char s_ble_engine_id[32];

bool bealach_engine_set_ble_declaration(const char *engine_id)
{
    if (engine_id == NULL || engine_id[0] == '\0') {
        s_ble_engine_id[0] = '\0';
        return false;
    }

    /* Validate it is a known engine id. */
    const bealach_engine_catalogue_entry_t *hit = cat_find(
        k_engine_catalogue,
        sizeof(k_engine_catalogue) / sizeof(k_engine_catalogue[0]),
        engine_id);

    snprintf(s_ble_engine_id, sizeof(s_ble_engine_id), "%s", engine_id);
    return hit != NULL;
}

const char *bealach_engine_get_ble_declaration(void)
{
    return s_ble_engine_id[0] != '\0' ? s_ble_engine_id : NULL;
}
