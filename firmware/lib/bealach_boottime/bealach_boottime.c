/* Provenance: cairn-esp32-device-firmware @ ead3532, lib/bealach_boottime/bealach_boottime.c
 * Renamed bealach_* → bealach_* for Bealach. Wire format markers unchanged. */

#include "bealach_boottime.h"

#include <stdio.h>
#include <string.h>

static const char *const STAGE_NAMES[BEALACH_BOOT_STAGE_COUNT] = {
    "app_start", "log_ready", "sd_mounted", "store_ready", "obd_first_answer",
    "gnss_first_fix", "first_sample", "ble_advertising", "first_chunk", "capture_open", "sensors_ready",
};

static const char *const RESET_NAMES[] = {
    "unknown", "power_on", "software", "panic", "watchdog", "brownout",
    "deep_sleep_wake", "external",
};

const char *bealach_boottime_stage_name(bealach_boot_stage_t s)
{
    return ((unsigned)s < BEALACH_BOOT_STAGE_COUNT) ? STAGE_NAMES[s] : "?";
}

const char *bealach_boottime_reset_name(bealach_reset_reason_t r)
{
    return ((unsigned)r < sizeof RESET_NAMES / sizeof RESET_NAMES[0]) ? RESET_NAMES[r] : "?";
}

void bealach_boottime_init(bealach_boottime_t *b, bealach_reset_reason_t reason,
                         uint32_t now_us, uint32_t since_reset_us)
{
    memset(b, 0, sizeof *b);
    for (int i = 0; i < BEALACH_BOOT_STAGE_COUNT; i++) b->at_us[i] = BEALACH_BOOT_NOT_REACHED;
    b->reset_reason = reason;
    b->t0_us        = now_us;
    b->pre_app_us   = since_reset_us;
    b->at_us[BEALACH_BOOT_APP_START] = 0;
}

bool bealach_boottime_mark(bealach_boottime_t *b, bealach_boot_stage_t s, uint32_t now_us)
{
    if ((unsigned)s >= BEALACH_BOOT_STAGE_COUNT) return false;
    if (b->at_us[s] != BEALACH_BOOT_NOT_REACHED) return false;

    /* Modular subtraction: the platform clock is truncated to 32 bits and a boot is
     * seconds long, so a wrap between T0 and a mark still yields the right delta. A
     * delta that lands on the sentinel would read as "not reached"; nudge it down by
     * one microsecond rather than lose the stage. */
    uint32_t d = now_us - b->t0_us;
    if (d == BEALACH_BOOT_NOT_REACHED) d--;
    b->at_us[s] = d;

    if (s == BEALACH_BOOT_SD_MOUNTED) b->sd_present = true;
    return true;
}

bool bealach_boottime_reached(const bealach_boottime_t *b, bealach_boot_stage_t s)
{
    return (unsigned)s < BEALACH_BOOT_STAGE_COUNT && b->at_us[s] != BEALACH_BOOT_NOT_REACHED;
}

uint32_t bealach_boottime_at(const bealach_boottime_t *b, bealach_boot_stage_t s)
{
    return ((unsigned)s < BEALACH_BOOT_STAGE_COUNT) ? b->at_us[s] : BEALACH_BOOT_NOT_REACHED;
}

/* snprintf-style append: `used` counts what the whole text needs, which can exceed `cap`. */
static void append(char *out, size_t cap, size_t *used, const char *line, int n)
{
    if (n <= 0) return;
    if (*used < cap) snprintf(out + *used, cap - *used, "%s", line);
    *used += (size_t)n;
}

size_t bealach_boottime_format(const bealach_boottime_t *b, char *out, size_t cap)
{
    size_t used = 0;
    char   line[96];
    int    n;

    if (cap > 0) out[0] = '\0';

    n = snprintf(line, sizeof line, "boot: reset=%s pre_app=%u us sd=%s\n",
                 bealach_boottime_reset_name(b->reset_reason), (unsigned)b->pre_app_us,
                 b->sd_present ? "yes" : "no");
    append(out, cap, &used, line, n);

    /* Stages are listed in the order they were reached, not enum order: a boot does not
     * reach them in enum order (BLE can advertise before the first sample, or after), and
     * a delta against the wrong neighbour is meaningless. Ties keep enum order. */
    bool done[BEALACH_BOOT_STAGE_COUNT] = { false };
    uint32_t prev = 0;
    for (int printed = 0; printed < BEALACH_BOOT_STAGE_COUNT; printed++) {
        int next = -1;
        for (int i = 0; i < BEALACH_BOOT_STAGE_COUNT; i++) {
            if (done[i] || b->at_us[i] == BEALACH_BOOT_NOT_REACHED) continue;
            if (next < 0 || b->at_us[i] < b->at_us[next]) next = i;
        }
        if (next < 0) break;
        done[next] = true;
        n = snprintf(line, sizeof line, "boot: %-16s %9u us  (+%u)\n", STAGE_NAMES[next],
                     (unsigned)b->at_us[next], (unsigned)(b->at_us[next] - prev));
        append(out, cap, &used, line, n);
        prev = b->at_us[next];
    }
    return used;
}

bool bealach_boottime_check(const bealach_boottime_t *b, const bealach_boot_budget_t *budget,
                          bealach_boot_stage_t *worst)
{
    for (int i = 0; i < BEALACH_BOOT_STAGE_COUNT; i++) {
        if (budget->max_us[i] == 0) continue;
        if (b->at_us[i] == BEALACH_BOOT_NOT_REACHED || b->at_us[i] > budget->max_us[i]) {
            if (worst) *worst = (bealach_boot_stage_t)i;
            return false;
        }
    }
    return true;
}

static void put_le32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

static uint32_t get_le32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

size_t bealach_boottime_encode(const bealach_boottime_t *b, uint8_t *out, size_t cap)
{
    if (cap < BEALACH_BOOTTIME_WIRE_SIZE) return 0;
    out[0] = BEALACH_BOOTTIME_WIRE_VERSION;
    out[1] = (uint8_t)b->reset_reason;
    out[2] = (uint8_t)BEALACH_BOOT_STAGE_COUNT;
    out[3] = b->sd_present ? 1u : 0u;
    put_le32(out + 4, b->pre_app_us);
    for (int i = 0; i < BEALACH_BOOT_STAGE_COUNT; i++) put_le32(out + 8 + 4 * i, b->at_us[i]);
    return BEALACH_BOOTTIME_WIRE_SIZE;
}

bool bealach_boottime_decode(bealach_boottime_t *b, const uint8_t *in, size_t len)
{
    if (len < 8 || in[0] != BEALACH_BOOTTIME_WIRE_VERSION) return false;
    size_t stages = in[2];
    if (len < 8 + 4 * stages) return false;

    bealach_boottime_init(b, (bealach_reset_reason_t)in[1], 0, get_le32(in + 4));
    b->sd_present = (in[3] & 1u) != 0;
    for (size_t i = 0; i < stages && i < BEALACH_BOOT_STAGE_COUNT; i++)
        b->at_us[i] = get_le32(in + 8 + 4 * i);
    return true;
}
