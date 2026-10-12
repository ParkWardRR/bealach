/* Provenance: cairn-esp32-device-firmware @ ead3532, lib/bealach_bundle/bealach_bundle.h
 * Renamed bealach_* → bealach_* for Bealach. Wire format markers unchanged. */

/*
 * Reading a sealed bundle off the card, for the network transports.
 *
 * lib/bealach_intake needs three things from a bundle: the signed manifest bytes,
 * their signature, and random access into the member byte stream. This provides
 * exactly those, over bealach_fs, as portable C — so the offset arithmetic runs
 * on the host against a real directory rather than only on the device.
 *
 * Why a separate module rather than reusing lib/bealach_offload's reader: that
 * module's stream state is entangled with the BLE protocol's one-operation-at-
 * a-time rules and its MTU-sized framing, it is the proven path that has
 * already carried real trips, and it is under concurrent edit. Lifting a reader
 * out of it would risk the one seam that works to save a little duplication.
 *
 * The important property is that the offsets here mean the same thing as the
 * sealer's. bealach_store chunks the *concatenation of the members in canonical
 * order* (sorted by raw name bytes, spec §6.1), and a chunk may straddle a
 * member boundary. So read_at walks that same concatenation, and the member
 * order comes from the signed manifest rather than from a fresh directory
 * listing — a directory read could return a different order, or pick up a file
 * written since the seal, and either would silently shift every offset.
 */

#ifndef BEALACH_BUNDLE_H
#define BEALACH_BUNDLE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "bealach_format.h"
#include "bealach_intake.h"

#ifdef __cplusplus
extern "C" {
#endif

#define BEALACH_BUNDLE_DIR_MAX 160

typedef struct {
    char dir[BEALACH_BUNDLE_DIR_MAX];      /* .../cairn/bundles/<ULID> */

    /* The signed manifest, verbatim, and its detached signature. Held whole
     * because the signature covers exactly these bytes and the offer sends
     * them unaltered. */
    uint8_t  manifest[BEALACH_MANIFEST_ENCODED_MAX];
    size_t   manifest_len;
    uint8_t  sig[64];

    /* The decoded manifest: the member order and lengths that define the
     * offsets, and the chunk descriptors the transport sends. */
    bealach_manifest_t m;

    /* One open member, kept between calls. Sequential reads are the normal
     * case — a chunk is read twice, once to verify and once to send — and
     * reopening per call would cost two directory lookups per block on a card
     * whose slot is already known to be marginal. */
    void     *open_file;
    size_t    open_index;
    uint64_t  open_pos;
    bool      have_open;
} bealach_bundle_t;

/*
 * Open the sealed bundle in `dir`: read manifest.cbor and manifest.sig, decode
 * and canonically re-verify the manifest, and check the member lengths against
 * the files actually on the card.
 *
 * `scratch` is borrowed, not kept: bealach_manifest_decode re-encodes to prove
 * canonical form, so it needs as much room as the manifest itself
 * (BEALACH_MANIFEST_ENCODED_MAX). It is only used during this call, so the caller
 * can and should lend it the same buffer it streams chunk bytes through —
 * owning a second one here cost 8 KB of static DRAM for nothing.
 *
 * That last check matters. A member shorter than the manifest says is a torn or
 * truncated file, and without the check every offset past it would silently
 * read the wrong bytes — the transport would then hash a chunk, find it does not
 * match its descriptor, and blame the card read rather than the layout.
 */
bool bealach_bundle_open(bealach_bundle_t *b, const char *dir,
                       uint8_t *scratch, size_t scratch_len);

void bealach_bundle_close(bealach_bundle_t *b);

/* Total bytes across the members: the length of the stream read_at indexes. */
uint64_t bealach_bundle_stream_bytes(const bealach_bundle_t *b);

/*
 * Read `len` bytes at `offset` in the concatenated member stream. Returns the
 * count read, which equals `len` on success; anything less is a failure the
 * caller must treat as such, since every offset asked for is covered by a
 * signed descriptor.
 */
size_t bealach_bundle_read_at(bealach_bundle_t *b, uint64_t offset,
                            uint8_t *out, size_t len);

/* Fill in a bealach_intake_bundle_t that reads through `b`. */
void bealach_bundle_as_intake_source(bealach_bundle_t *b, bealach_intake_bundle_t *out);

#ifdef __cplusplus
}
#endif

#endif /* BEALACH_BUNDLE_H */
