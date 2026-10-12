/* Provenance: cairn-esp32-device-firmware @ ead3532, src/policy.c
 * Renamed bealach_* → bealach_* for Bealach. Wire format markers unchanged. */

#include "policy.h"

#include <string.h>

#include "bealach_format.h"
#include "bealach_engine.h"
#include "bealach_store.h"

/* ── defaults ─────────────────────────────────────────────────────────────── */

void bealach_policy_defaults(bealach_policy_t *p)
{
    memset(p, 0, sizeof(*p));

    p->policy_version = BEALACH_POLICY_VERSION;

    p->gnss_period_ms   = BEALACH_GNSS_PERIOD_MS;
    p->imu_window_ms    = BEALACH_IMU_WINDOW_MS;
    p->obd_period_ms    = bealach_engine_params()->obd_period_ms;
    p->health_period_ms = BEALACH_HEALTH_PERIOD_MS;

    p->start_score_threshold_e2 = BEALACH_START_SCORE_THRESHOLD_E2;
    p->stop_score_threshold_e2  = BEALACH_STOP_SCORE_THRESHOLD_E2;
    p->start_dwell_ms           = BEALACH_START_DWELL_MS;
    p->stop_dwell_ms            = BEALACH_STOP_DWELL_MS;

    p->motion_accel_rms_mg = BEALACH_MOTION_ACCEL_RMS_MG;
    p->motion_speed_cmps   = BEALACH_MOTION_SPEED_CMPS;

    p->preroll_window_ms    = BEALACH_PREROLL_WINDOW_MS;
    p->preroll_ring_samples = BEALACH_PREROLL_RING_SAMPLES;
    p->segment_max_bytes    = BEALACH_SEGMENT_MAX_BYTES;

    p->adaptive_sampling = BEALACH_ADAPTIVE_SAMPLING != 0;
}

/* ── POLICY_SNAPSHOT ──────────────────────────────────────────────────────── */

#define KEY_POLICY_VERSION      1
#define KEY_GNSS_PERIOD         2
#define KEY_IMU_WINDOW          3
#define KEY_OBD_PERIOD          4
#define KEY_HEALTH_PERIOD       5
#define KEY_START_SCORE         6
#define KEY_STOP_SCORE          7
#define KEY_START_DWELL         8
#define KEY_STOP_DWELL          9
#define KEY_MOTION_ACCEL       10
#define KEY_MOTION_SPEED       11
#define KEY_PREROLL_WINDOW     12
#define KEY_PREROLL_SAMPLES    13
#define KEY_SEGMENT_MAX        14
#define KEY_ADAPTIVE           15

#define POLICY_FIELD_COUNT     15

size_t bealach_policy_encode(const bealach_policy_t *p, uint8_t *out, size_t cap)
{
    bealach_cbor_enc_t e;
    bealach_cbor_init(&e, out, cap);

    bealach_cbor_map(&e, POLICY_FIELD_COUNT);

    bealach_cbor_key(&e, KEY_POLICY_VERSION);
    bealach_cbor_uint(&e, p->policy_version);
    bealach_cbor_key(&e, KEY_GNSS_PERIOD);
    bealach_cbor_uint(&e, p->gnss_period_ms);
    bealach_cbor_key(&e, KEY_IMU_WINDOW);
    bealach_cbor_uint(&e, p->imu_window_ms);
    bealach_cbor_key(&e, KEY_OBD_PERIOD);
    bealach_cbor_uint(&e, p->obd_period_ms);
    bealach_cbor_key(&e, KEY_HEALTH_PERIOD);
    bealach_cbor_uint(&e, p->health_period_ms);
    bealach_cbor_key(&e, KEY_START_SCORE);
    bealach_cbor_uint(&e, p->start_score_threshold_e2);
    bealach_cbor_key(&e, KEY_STOP_SCORE);
    bealach_cbor_uint(&e, p->stop_score_threshold_e2);
    bealach_cbor_key(&e, KEY_START_DWELL);
    bealach_cbor_uint(&e, p->start_dwell_ms);
    bealach_cbor_key(&e, KEY_STOP_DWELL);
    bealach_cbor_uint(&e, p->stop_dwell_ms);
    bealach_cbor_key(&e, KEY_MOTION_ACCEL);
    bealach_cbor_uint(&e, p->motion_accel_rms_mg);
    bealach_cbor_key(&e, KEY_MOTION_SPEED);
    bealach_cbor_uint(&e, p->motion_speed_cmps);
    bealach_cbor_key(&e, KEY_PREROLL_WINDOW);
    bealach_cbor_uint(&e, p->preroll_window_ms);
    bealach_cbor_key(&e, KEY_PREROLL_SAMPLES);
    bealach_cbor_uint(&e, p->preroll_ring_samples);
    bealach_cbor_key(&e, KEY_SEGMENT_MAX);
    bealach_cbor_uint(&e, p->segment_max_bytes);
    bealach_cbor_key(&e, KEY_ADAPTIVE);
    bealach_cbor_uint(&e, p->adaptive_sampling ? 1u : 0u);

    /* Overflow also fires on a descending key, which would be a programming
     * error that silently produced a non-canonical map. */
    if (e.overflow) return 0;
    return e.len;
}

bool bealach_policy_decode(const uint8_t *buf, size_t len, bealach_policy_t *out)
{
    bealach_cbor_dec_t d;
    bealach_cbor_dec_init(&d, buf, len);

    size_t n = 0;
    if (bealach_cbor_map_header(&d, &n) != BEALACH_OK) return false;
    if (n != POLICY_FIELD_COUNT) return false;

    memset(out, 0, sizeof(*out));

    for (size_t i = 0; i < n; i++) {
        uint64_t key = 0, v = 0;
        if (bealach_cbor_uint_read(&d, &key) != BEALACH_OK) return false;
        if (bealach_cbor_uint_read(&d, &v) != BEALACH_OK) return false;

        switch (key) {
        case KEY_POLICY_VERSION:   out->policy_version = (uint8_t)v; break;
        case KEY_GNSS_PERIOD:      out->gnss_period_ms = (uint16_t)v; break;
        case KEY_IMU_WINDOW:       out->imu_window_ms = (uint16_t)v; break;
        case KEY_OBD_PERIOD:       out->obd_period_ms = (uint16_t)v; break;
        case KEY_HEALTH_PERIOD:    out->health_period_ms = (uint32_t)v; break;
        case KEY_START_SCORE:      out->start_score_threshold_e2 = (uint16_t)v; break;
        case KEY_STOP_SCORE:       out->stop_score_threshold_e2 = (uint16_t)v; break;
        case KEY_START_DWELL:      out->start_dwell_ms = (uint32_t)v; break;
        case KEY_STOP_DWELL:       out->stop_dwell_ms = (uint32_t)v; break;
        case KEY_MOTION_ACCEL:     out->motion_accel_rms_mg = (uint16_t)v; break;
        case KEY_MOTION_SPEED:     out->motion_speed_cmps = (uint16_t)v; break;
        case KEY_PREROLL_WINDOW:   out->preroll_window_ms = (uint32_t)v; break;
        case KEY_PREROLL_SAMPLES:  out->preroll_ring_samples = (uint16_t)v; break;
        case KEY_SEGMENT_MAX:      out->segment_max_bytes = (uint32_t)v; break;
        case KEY_ADAPTIVE:         out->adaptive_sampling = (v != 0); break;
        default:
            /* Newer firmware signed this policy. Refuse rather than report a
             * partial one as complete. */
            return false;
        }
    }

    /* Trailing bytes carry something unaccounted for — the same hazard as an
     * unknown key. */
    return d.pos == len;
}

/* ── adaptive sampling ────────────────────────────────────────────────────── */

const char *bealach_dynamics_name(bealach_dynamics_t d)
{
    switch (d) {
    case BEALACH_DYN_IDLE:   return "IDLE";
    case BEALACH_DYN_CRUISE: return "CRUISE";
    case BEALACH_DYN_ACTIVE: return "ACTIVE";
    case BEALACH_DYN_EVENT:  return "EVENT";
    default:               return "?";
    }
}

bealach_dynamics_t bealach_policy_classify(const bealach_policy_t *p,
                                       uint16_t accel_rms_mg,
                                       uint16_t speed_cmps,
                                       int32_t speed_delta_cmps,
                                       bool trip_active)
{
    if (!trip_active) return BEALACH_DYN_IDLE;

    /*
     * A sharp transient. Three times the motion threshold is a decisive
     * manoeuvre rather than road noise, and this is the case where extra
     * resolution is worth the write load.
     */
    if (accel_rms_mg >= (uint16_t)(p->motion_accel_rms_mg * 3)) {
        return BEALACH_DYN_EVENT;
    }

    /*
     * A large speed change between OBD samples is the other decisive signal,
     * and it catches braking that the accelerometer's RMS smooths away. 500
     * cm/s over one OBD period is roughly 18 km/h, which no gentle driving
     * produces.
     */
    if (speed_delta_cmps > 500 || speed_delta_cmps < -500) {
        return BEALACH_DYN_EVENT;
    }

    if (accel_rms_mg >= (uint16_t)(p->motion_accel_rms_mg + (p->motion_accel_rms_mg / 2))) {
        return BEALACH_DYN_ACTIVE;
    }

    /*
     * Moving but smooth. Nominal rates already resolve a straight line well,
     * so there is nothing to gain by sampling harder — and the card and the
     * battery both prefer not to.
     */
    if (speed_cmps != BEALACH_U16_UNKNOWN && speed_cmps >= p->motion_speed_cmps) {
        return BEALACH_DYN_CRUISE;
    }

    return BEALACH_DYN_ACTIVE;
}

void bealach_policy_rates(const bealach_policy_t *p, bealach_dynamics_t d,
                        bool trip_active, bealach_rates_t *out)
{
    /* Nominal, which is also the slowest permitted during a trip. */
    out->gnss_period_ms = p->gnss_period_ms;
    out->imu_window_ms  = p->imu_window_ms;
    out->obd_period_ms  = p->obd_period_ms;

    if (!p->adaptive_sampling) return;

    switch (d) {
    case BEALACH_DYN_IDLE:
        /*
         * The only case that samples *slower* than nominal, and it is safe
         * because no trip is underway: these records go to the pre-roll ring,
         * where the guarantee is a window of history rather than a rate. A
         * parked car has nothing to resolve and every reason to save power.
         */
        if (!trip_active) {
            out->gnss_period_ms = (uint16_t)(p->gnss_period_ms * 4);
            out->obd_period_ms  = (uint16_t)(p->obd_period_ms * 4);
        }
        break;

    case BEALACH_DYN_CRUISE:
        /* Nominal. A straight line does not reward more samples. */
        break;

    case BEALACH_DYN_ACTIVE:
        out->gnss_period_ms = (uint16_t)(p->gnss_period_ms / 2);
        out->imu_window_ms  = (uint16_t)(p->imu_window_ms / 2);
        break;

    case BEALACH_DYN_EVENT:
        /*
         * As fast as the sources usefully go. The IMU window shrinks furthest
         * because peak and RMS over a quarter second describe a hard stop,
         * while over a full second they average it away.
         */
        out->gnss_period_ms = (uint16_t)(p->gnss_period_ms / 4);
        out->imu_window_ms  = (uint16_t)(p->imu_window_ms / 4);
        out->obd_period_ms  = (uint16_t)(p->obd_period_ms / 2);
        break;
    }

    /* Floors. Sampling GNSS faster than the receiver produces fixes would
     * manufacture duplicate records, and an IMU window shorter than a few
     * samples has no statistics to summarize. */
    if (out->gnss_period_ms < BEALACH_FLOOR_GNSS_PERIOD_MS) out->gnss_period_ms = BEALACH_FLOOR_GNSS_PERIOD_MS;
    if (out->imu_window_ms < BEALACH_FLOOR_IMU_WINDOW_MS) out->imu_window_ms = BEALACH_FLOOR_IMU_WINDOW_MS;
    if (out->obd_period_ms < BEALACH_FLOOR_OBD_PERIOD_MS) out->obd_period_ms = BEALACH_FLOOR_OBD_PERIOD_MS;
}
