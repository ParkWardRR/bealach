# Mirroring contract — secure resumable BLE transfer to the owner phone

Adapted from Cairn **BLE bundle offload v1**
([`contracts/ble/v1/offload.md`](https://github.com/ParkWardRR/cairn-driving-log-selfhosted/blob/main/contracts/ble/v1/offload.md) @ `7ed8dac`).
Framing and recovery are reused; the **server trust/receipt model is replaced by
device-to-owner-phone trust**. The phone is the final verifier and store, not a
relay: nothing is forwarded anywhere.

## 1. Trust and access

- **Explicit secure enrolment** ([threat-model.md](../threat-model.md) §5): bond
  + application-layer identity verification; the device pins the owner phone's
  public key; the phone records the device identity and pins its manifest key.
  Ownership reset clears both.
- **Encrypted, authenticated access on every session.** All mirror
  characteristics require the bonded link *and* an authenticated session; there
  is **no insecure fallback**, no open read of recording bytes or manifests.
- A peer without the bond and the enrolment pin cannot list, read, or influence
  deletion state. A revoked/previous phone is refused even if its BLE bond still
  exists (bond ≠ ownership).

## 2. Service shape (adapted from offload v1)

Same GATT service family, same LE framing conventions (little-endian, fixed
layouts, MTU-negotiated messages, one operation at a time, `BUSY` otherwise).
Control ops (adapted):

| op | Name | Purpose |
|---:|---|---|
| `0x01` `LIST` | list sealed recordings | `bundle_id ‖ stream_bytes ‖ manifest_len ‖ chunk_count ‖ state` entries; only sealed recordings |
| `0x02` `GET_MANIFEST` | fetch `manifest.cbor ‖ manifest.sig` | total_len = manifest_len + 64 |
| `0x03` `READ` | `bundle_id ‖ offset ‖ length` | byte-range of the bundle stream (member files in canonical order) |
| `0x04` `PUT_ACK` | deliver the owner-phone signed mirror acknowledgement | triggers *bookkeeping*, never an automatic delete |
| `0x05` `ABORT` | cancel | always honoured |

State per listing: `sealed` → `acknowledged`. (Cairn's `receipt-verified /
prune-pending` is gone; see deletion contract.)

Reuse rules from offload v1 unchanged: negotiated MTU ≥ 43 (target 247),
15–30 ms connection interval, expected 10–25 KB/s **[A3, to be measured]**,
`TRIP_ACTIVE` refusal while a capture is in progress (capture never degraded to
serve a transfer), 8 s stall abandonment, transfer-done indication carrying
`bytes_sent` + IEEE CRC-32, per-transfer `seq` framing on the data channel,
`length` ≤ 65 536 per READ.

## 3. Resumable chunk transfer and persistent progress

- The bundle stream is divided into **content-addressed chunks** (SHA-256 per
  chunk; size from the manifest — Cairn's production 8 KiB chunk size is the
  starting point). Chunk digests live in the device-signed manifest.
- The phone keeps **persistent transfer progress** (per bundle: verified chunk
  set) in its encrypted store, surviving app termination and phone reboot.
- Reconnect resumes at the first unverified chunk; verified chunks are never
  re-fetched. Chunks are **deduplicated** by digest.
- **Replay handling:** a chunk whose digest is already verified is acknowledged
  without re-import; manifests are content-named (manifest hash), so a replayed
  old manifest for a claimed-new bundle fails identity checks (`device_counter`
  binding).
- Disconnects, app termination, device resets mid-transfer: nothing partial is
  ever visible as verified; progress is either durable or recomputed from
  verified digests.

## 4. Verification before import (the phone is the verifier)

Validation pipeline, all mandatory, before anything is durably imported:

1. `manifest.sig` verifies under the **enrolled device key**; manifest binds
   device, vehicle, assignment, `boot_id`, `device_counter`, engine profile.
2. `content_root` recomputed from member/chunk digests equals the signed root.
3. Every chunk's SHA-256 matches the manifest.
4. Structural scan of assembled bytes (segment headers, frame CRC chain,
   sequence continuity) succeeds.
5. **AEAD authentication of frames** succeeds under keys derived from the
   escrowed `K_root` (`AUTH_FAILED` distinct from `CORRUPT_FRAME`).
6. Only then: **transactional, durable import** into the iOS mirror store
   (staging + commit). An interrupted import leaves either the previous state or
   the new state, never half.

Sensor-quality and gap semantics are *interpretation* of verified data and are
checked after verification, not instead of it.

## 5. Acknowledgements

After durable import the phone sends a **mirror acknowledgement**:

- Signed by the **owner-phone key** the device pinned at enrolment.
- Names the exact verified content: `bundle_id`, `content_root`, manifest hash,
  device id, and the verified byte/chunk count.
- Device verifies signature against the pinned owner key and content match
  against its own sealed recording; mismatches are stored as *failures*, never
  as acknowledgements.
- Acknowledgement moves listing state to `acknowledged` and is **bookkeeping**:
  it is a precondition for user-approved SD reclaim ([deletion.md](deletion.md)),
  never a delete command.
- Outcomes on the device: `verified` / `rejected-malformed` /
  `rejected-wrong-content` / `no-owner-key-pinned` (nothing stored). Rejections
  are surfaced in the UI; no blind retry.

## 6. Failure matrix (required behaviour)

| Event | Behaviour |
|---|---|
| BLE disconnect mid-READ | Progress retained; resume at first unverified chunk |
| App terminated / phone reboot | Persistent progress restored on next session; nothing marked verified unless committed |
| Device reset mid-transfer | Recording intact on SD; transfer restarts from verified progress |
| Trip starts mid-transfer | `TRIP_ACTIVE` ends the transfer; retry after seal |
| Corrupt chunk (CRC/digest mismatch) | That chunk refetched; repeated failure flags the bundle `corrupt` on the phone and reports it |
| Manifest signature failure | Import refused entirely; bundle quarantined as suspect; user notified |
| Storage full on phone | Transfer paused with explicit reason; dongle retains everything |
| Storage full on dongle | Recording continues per recording contract degradation policy; mirror unaffected |
| Stale bond (phone restored) | Re-pair path (blesec recovery); ownership pins re-verified; no silent fallback |

## 7. Battery and batching

Batch transfers (multiple chunks per connection window), bound scan/reconnect
attempts with exponential backoff, cache summaries and map previews, process
incrementally. Preserve raw recordings; downsample only display data.
Background windows follow iOS limits (`bluetooth-central` wake ≈ 10 s work
windows; state restoration for pending connections).

## 8. Conformance

- Carried vectors: `contracts/ble/v1/vectors/offload/` incl. negative cases
  (`read_bad_arguments`, `unknown_bundle`, `trip_active`, `mtu_too_small`,
  ack-path equivalents of `put_receipt_*`) — renamed to the ack semantics.
- Firmware (C) and iOS (Swift) must agree against these vectors before milestone
  1 acceptance.
