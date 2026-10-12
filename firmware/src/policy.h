/* Provenance: cairn-esp32-device-firmware @ ead3532, src/policy.h
 * Renamed bealach_* → bealach_* for Bealach. Wire format markers unchanged. */

/*
 * The active capture policy, and the record that makes a bundle
 * self-describing with respect to it.
 *
 * A version number identifies a policy but does not describe one. Interpreting
 * an old bundle from `policy_version` alone would mean finding the firmware
 * build that defined that version — so the values themselves are written into
 * every bundle (spec §4.9). A trip captured under thresholds nobody remembers
 * stays explainable from the trip.
 *
 * Event-adaptive sampling (§4.9.1) treats the nominal periods as *upper bounds*
 * during a trip: the device may sample faster when the vehicle is doing
 * something worth resolving, never slower. That direction matters. A reader may
 * assume at least one record per nominal period while a trip is active, so a
 * longer gap is still a gap and still recorded as one. Adaptation can only add
 * detail, which keeps a bundle's guarantees independent of what the device
 * decided in the moment.
 */

#ifndef BEALACH_POLICY_H
#define BEALACH_POLICY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "config.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Floors on adaptive rates. Sampling GNSS faster than the receiver produces
 * fixes would manufacture duplicate records, an IMU window shorter than a few
 * samples has no statistics to summarize, and the OBD round trip measured
 * 110..140 ms per request.
 *
 * They are exported, not private to policy.c, because the nominal periods are
 * tuned toward them: once a nominal period reaches its floor, adaptation has no
 * headroom on that axis and an EVENT cannot be finer than CRUISE there. That is
 * a property of the hardware, not a defect, and the tests need the numbers to
 * tell "inert because pinned at the floor" from "inert because broken".
 */
#define BEALACH_FLOOR_GNSS_PERIOD_MS 200
#define BEALACH_FLOOR_IMU_WINDOW_MS  100
#define BEALACH_FLOOR_OBD_PERIOD_MS  250

typedef struct {
    uint8_t  policy_version;

    uint16_t gnss_period_ms;
    uint16_t imu_window_ms;
    uint16_t obd_period_ms;
    uint32_t health_period_ms;

    uint16_t start_score_threshold_e2;
    uint16_t stop_score_threshold_e2;
    uint32_t start_dwell_ms;
    uint32_t stop_dwell_ms;

    uint16_t motion_accel_rms_mg;
    uint16_t motion_speed_cmps;

    uint32_t preroll_window_ms;
    uint16_t preroll_ring_samples;
    uint32_t segment_max_bytes;

    bool     adaptive_sampling;
} bealach_policy_t;

/* The compiled-in defaults from config.h. */
void bealach_policy_defaults(bealach_policy_t *p);

/*
 * Encode as the deterministic CBOR map of §4.9. Keys ascend and are encoded per
 * §5, so identical policy yields byte-identical output — which is what lets a
 * reader group bundles by policy without trusting the version number.
 */
size_t bealach_policy_encode(const bealach_policy_t *p, uint8_t *out, size_t cap);

/*
 * Decode a snapshot. The device never needs this — it writes policy, it does
 * not read it — but the conformance runner does: checking against a committed
 * vector means decoding bytes this implementation did not produce, which is the
 * only way to catch a divergence rather than confirm a round trip.
 *
 * Strict for the same reason the manifest decoder is: an unknown key or a
 * trailing byte means the policy is only partly understood, and reporting a
 * partial policy as complete would be worse than reporting none.
 */
bool bealach_policy_decode(const uint8_t *buf, size_t len, bealach_policy_t *out);

/* ── adaptive sampling ────────────────────────────────────────────────────── */

/*
 * What the vehicle appears to be doing, which is what the rates respond to.
 * Derived from evidence the device already has rather than from a new sensor.
 */
typedef enum {
    BEALACH_DYN_IDLE = 0,   /* no trip; sampling is at its slowest */
    BEALACH_DYN_CRUISE,     /* moving steadily; nominal rates resolve this fine */
    BEALACH_DYN_ACTIVE,     /* accelerating, braking or turning */
    BEALACH_DYN_EVENT,      /* a sharp transient worth resolving in detail */
} bealach_dynamics_t;

const char *bealach_dynamics_name(bealach_dynamics_t d);

/*
 * Sampling periods for a dynamics level. Never longer than the policy's nominal
 * period while a trip is underway, so the floor a reader relies on holds.
 */
typedef struct {
    uint16_t gnss_period_ms;
    uint16_t imu_window_ms;
    uint16_t obd_period_ms;
} bealach_rates_t;

void bealach_policy_rates(const bealach_policy_t *p, bealach_dynamics_t d,
                        bool trip_active, bealach_rates_t *out);

/*
 * Classify dynamics from the evidence to hand. `accel_rms_mg` is the live
 * accelerometer figure; speed and its rate of change come from whichever source
 * answered, with BEALACH_U16_UNKNOWN meaning no opinion.
 */
bealach_dynamics_t bealach_policy_classify(const bealach_policy_t *p,
                                       uint16_t accel_rms_mg,
                                       uint16_t speed_cmps,
                                       int32_t speed_delta_cmps,
                                       bool trip_active);

#ifdef __cplusplus
}
#endif

#endif /* BEALACH_POLICY_H */
