/* Provenance: cairn-esp32-device-firmware @ ead3532, lib/bealach_log/bealach_log.h
 * Renamed bealach_* → bealach_* for Bealach. Wire format markers unchanged. */

/*
 * Verbose logging to UART and the SD card.
 *
 * Built for bench testing, where the useful log is almost always the one
 * written just before something went wrong. Three consequences shape the
 * design:
 *
 *   - Logging starts before the SD card is mounted. Early lines go to a RAM
 *     ring buffer and are drained to the card once it mounts, so a mount
 *     failure is itself diagnosable rather than silently unlogged.
 *   - WARN and ERROR are flushed immediately. Everything else is flushed on a
 *     timer, because fsyncing every TRACE line would both wear the card and
 *     distort the timing of the thing being measured. A pulled fuse can
 *     therefore cost the last few INFO lines, never a WARN or ERROR.
 *   - The log tree is capped and yields to capture data. A testing aid must not
 *     be able to cost a trip; unsealed capture data cannot be reproduced, and a
 *     log can.
 *
 * Call bealach_log_line() through the BEALACH_LOG* macros so that a level compiled
 * out costs nothing, not even argument evaluation.
 */

#ifndef BEALACH_LOG_H
#define BEALACH_LOG_H

#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    BEALACH_LOG_NONE  = 0,
    BEALACH_LOG_ERROR = 1,
    BEALACH_LOG_WARN  = 2,
    BEALACH_LOG_INFO  = 3,
    BEALACH_LOG_DEBUG = 4,
    BEALACH_LOG_TRACE = 5,
} bealach_log_level_t;

/* Compile-time ceiling, set in platformio.ini. Levels above it are not built. */
#ifndef BEALACH_LOG_LEVEL
#define BEALACH_LOG_LEVEL BEALACH_LOG_DEBUG
#endif

/*
 * Bring up the UART sink and the pre-mount buffer. Safe to call before any
 * peripheral exists; must be called before any BEALACH_LOG* use.
 */
void bealach_log_init(uint32_t baud);

/*
 * Attach the SD sink. Opens a fresh file under BEALACH_DIR_LOGS named from the
 * boot count, enforces the total budget oldest-first, and drains whatever the
 * pre-mount buffer accumulated. Returns false if the card is unusable, in which
 * case UART logging continues unaffected.
 */
bool bealach_log_attach_sd(uint32_t boot_count);

/* Detach cleanly, flushing first. Used before deep sleep and before an OTA. */
void bealach_log_detach_sd(void);

/* Runtime level, independent of the compile-time ceiling. */
void              bealach_log_set_level(bealach_log_level_t level);
bealach_log_level_t bealach_log_get_level(void);

/*
 * Stamp subsequent lines with the active boot id and sequence context. Logs are
 * correlated with bundles by (boot_id, seq), the same ordering truth the format
 * uses — never by wall-clock time, which can jump.
 */
void bealach_log_set_context(const uint8_t boot_id[16]);

/* Emit one line. Prefer the macros. */
void bealach_log_line(bealach_log_level_t level, const char *tag,
                    const char *fmt, ...) __attribute__((format(printf, 3, 4)));

/* Hex dump, 16 bytes per line, for inspecting frames and manifests. */
void bealach_log_hexdump(bealach_log_level_t level, const char *tag,
                       const char *what, const uint8_t *data, size_t len);

/* Force a flush to the card. Called at every durability point. */
void bealach_log_flush(void);

/* Give the timed flush a chance to run; call from the main loop. */
void bealach_log_tick(void);

/* Counters, reported in DEVICE_HEALTH so that a log problem is itself visible
 * in the data rather than only in the logs. */
typedef struct {
    uint32_t lines_emitted;
    uint32_t lines_dropped;   /* buffer full before the SD card was available */
    uint32_t sd_write_errors;
    uint32_t bytes_written;
    bool     sd_attached;
    bool     sd_suspended;    /* free space fell below the floor */
} bealach_log_stats_t;

void bealach_log_get_stats(bealach_log_stats_t *out);

/* ── macros ───────────────────────────────────────────────────────────────── */

#define BEALACH_LOGE(tag, ...) \
    do { if (BEALACH_LOG_LEVEL >= BEALACH_LOG_ERROR) \
        bealach_log_line(BEALACH_LOG_ERROR, tag, __VA_ARGS__); } while (0)

#define BEALACH_LOGW(tag, ...) \
    do { if (BEALACH_LOG_LEVEL >= BEALACH_LOG_WARN) \
        bealach_log_line(BEALACH_LOG_WARN, tag, __VA_ARGS__); } while (0)

#define BEALACH_LOGI(tag, ...) \
    do { if (BEALACH_LOG_LEVEL >= BEALACH_LOG_INFO) \
        bealach_log_line(BEALACH_LOG_INFO, tag, __VA_ARGS__); } while (0)

#define BEALACH_LOGD(tag, ...) \
    do { if (BEALACH_LOG_LEVEL >= BEALACH_LOG_DEBUG) \
        bealach_log_line(BEALACH_LOG_DEBUG, tag, __VA_ARGS__); } while (0)

#define BEALACH_LOGT(tag, ...) \
    do { if (BEALACH_LOG_LEVEL >= BEALACH_LOG_TRACE) \
        bealach_log_line(BEALACH_LOG_TRACE, tag, __VA_ARGS__); } while (0)

#define BEALACH_LOG_HEX(tag, what, data, len) \
    do { if (BEALACH_LOG_LEVEL >= BEALACH_LOG_DEBUG) \
        bealach_log_hexdump(BEALACH_LOG_DEBUG, tag, what, data, len); } while (0)

#ifdef __cplusplus
}
#endif

#endif /* BEALACH_LOG_H */
