/* Provenance: cairn-esp32-device-firmware @ ead3532, src/preroll.h
 * Renamed bealach_* → bealach_* for Bealach. Wire format markers unchanged. */

/*
 * The pre-trip ring.
 *
 * A trip is only declared after motion has persisted for BEALACH_START_DWELL_MS,
 * which is what stops a door slam or a passing truck from starting one. But the
 * dwell is also the first few seconds of the drive — pulling out of a parking
 * space, the first turn — and writing nothing during it would lose exactly the
 * part of a journey that is hardest to reconstruct later.
 *
 * So samples are captured continuously and held here, then flushed to the
 * bundle when a trip is confirmed. They are written with BEALACH_FLAG_PRETRIP,
 * because they are real observations that were recorded *before* the device had
 * decided a trip was underway, and a reader is entitled to know the difference.
 *
 * If motion does not persist, the ring is simply dropped. Nothing is written,
 * so a parked car does not accumulate bundles.
 */

#ifndef BEALACH_PREROLL_H
#define BEALACH_PREROLL_H

#include <stdbool.h>
#include <stdint.h>

#include "bealach_store.h"
#include "config.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * One buffered record. Payloads are bounded by the largest fixed-size record
 * the firmware emits, which keeps the ring a flat array — no allocation in the
 * capture path, where a failed allocation would mean losing the data it was
 * meant to protect.
 */
#define BEALACH_PREROLL_MAX_PAYLOAD 32

typedef struct {
    uint8_t  record_type;
    uint8_t  schema_version;
    uint16_t flags;
    uint32_t monotonic_ms;
    uint8_t  payload[BEALACH_PREROLL_MAX_PAYLOAD];
    uint8_t  payload_len;
} bealach_preroll_entry_t;

typedef struct {
    bealach_preroll_entry_t entries[BEALACH_PREROLL_RING_SAMPLES];
    uint16_t head;      /* next slot to write */
    uint16_t count;     /* entries currently held, <= capacity */
    uint32_t overwritten; /* dropped because the ring wrapped */
} bealach_preroll_t;

void bealach_preroll_reset(bealach_preroll_t *r);

/*
 * Hold a record. Oldest-first eviction once full: if the ring wraps, the most
 * recent window is the one worth keeping, since it is adjacent to the trip that
 * is about to be confirmed.
 */
bool bealach_preroll_push(bealach_preroll_t *r, uint8_t record_type,
                        uint8_t schema_version, uint16_t flags,
                        uint32_t monotonic_ms, const uint8_t *payload,
                        size_t payload_len);

/*
 * Write everything held to the capture chain in capture order, each frame
 * carrying BEALACH_FLAG_PRETRIP in addition to the flags it was recorded with.
 * Returns the number of frames written and empties the ring.
 */
uint16_t bealach_preroll_flush(bealach_preroll_t *r, bealach_capture_t *cap);

/* Oldest and newest monotonic timestamps held, for logging the span recovered. */
bool bealach_preroll_span(const bealach_preroll_t *r, uint32_t *oldest_ms,
                        uint32_t *newest_ms);

#ifdef __cplusplus
}
#endif

#endif /* BEALACH_PREROLL_H */
