/* Provenance: cairn-esp32-device-firmware @ ead3532, lib/bealach_fs/bealach_nvs_wipe.h
 * Renamed bealach_* → bealach_* for Bealach. Wire format markers unchanged. */

/*
 * Find deleted NVS entries whose bytes are still readable in flash.
 *
 * NVS deletes an entry by clearing two bits in its page's state table; the 32-byte slot
 * itself (key, and for a blob its data) stays exactly as written until the page is
 * garbage-collected, and NVS picks the page with the most deleted entries, so a page that
 * holds long-lived live entries among a few deleted ones can wait indefinitely. The churn in
 * bealach_kv_scrub_freed() cannot reach those pages (measured on the car's dongle: a Wi-Fi
 * password in the stack's own namespace survived it).
 *
 * Flash can have bits cleared without an erase, and NVS never reads a deleted slot (it
 * counts it and moves on: nvs_page.cpp, Page::mLoadEntryTable), so writing zeros over a
 * deleted slot is invisible to NVS and removes the old bytes for good. Live entries, page
 * headers, state tables and unwritten slots are never touched, and no page is erased, so
 * there is no moment at which the device's identity is out of the chip.
 *
 * This file is the pure part: it reads one page image and says which slots to zero. The
 * device wrapper (bealach_kv_zero_erased, bealach_kv_nvs.cpp) reads the partition and writes.
 * Format: ESP-IDF 4.4 NVS (page 4096 bytes: 32-byte header, 32-byte entry state table with
 * two bits per entry, 126 entries of 32 bytes).
 */
#ifndef BEALACH_NVS_WIPE_H
#define BEALACH_NVS_WIPE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define BEALACH_NVS_PAGE_SIZE   4096u
#define BEALACH_NVS_SLOT_SIZE   32u
#define BEALACH_NVS_ENTRY_COUNT 126u

/*
 * Offsets (from the start of the page) of every deleted slot that still holds bytes: not
 * all zero and not all 0xFF. At most `cap` are returned; the return value is how many.
 * Zero for a page that is not in use (uninitialised, corrupt, or any state this does not
 * know), so an unrecognised layout is never written to.
 */
size_t bealach_nvs_dirty_erased_slots(const uint8_t page[BEALACH_NVS_PAGE_SIZE],
                                    uint16_t *offsets, size_t cap);

#ifdef __cplusplus
}
#endif

#endif /* BEALACH_NVS_WIPE_H */
