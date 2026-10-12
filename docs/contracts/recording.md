# Recording contract

**Status: frozen** (2026-10-12). Changes require a new version.

Adapted from Cairn **bundle format v3**
([`contracts/format/v3/spec.md`](https://github.com/ParkWardRR/cairn-driving-log-selfhosted/blob/main/contracts/format/v3/spec.md) @ `7ed8dac`,
normative there; here the deltas are marked). The SD card is the source of
truth. Originals are immutable; derived trips are separate.

## 1. Design rules (inherited)

1. A sealed recording is **never mutated**. Segments are append-only; sealing is
   a one-way atomic rename.
2. **No byte is deleted** except under [deletion.md](deletion.md).
3. Ordering truth is **`(boot_id, seq)`**, never wall-clock UTC. UTC is an
   estimate carrying its own uncertainty.
4. **Honest incompleteness:** absent data is explicit (`GNSS_GAP`, unavailable
   sentinels), never interpolated.
5. The **SD card is never the security boundary**; it holds ciphertext.
   Structural checks (CRC chain, Merkle root) work without keys; authentication
   needs one.
6. A recording names its **vehicle and assignment** and carries a **device
   counter** in non-volatile storage *off the card*, so a restored old card
   cannot be mistaken for new data.

## 2. Objects and identities

| Object | Identity | Notes |
|---|---|---|
| Recording (bundle) | `bundle_id` (16 B) + `device_id` + `boot_id` | One trip-outing unit, sealed atomically |
| Segment | `segment_index` within the bundle | `seg-NNNNNNNN.seg`, plus `journal.seg` |
| Manifest | `manifest.cbor` + 64 B Ed25519 `manifest.sig` | Written once at seal |
| Content identity | `content_root` (Merkle over member digests) | The name a mirror acknowledges |
| Chunk | SHA-256 over a byte range of the bundle stream | Unit of resumable transfer |
| Vehicle | `vehicle_id` (16 B), assignment `assignment_id` | Explicit, correctable, never inferred from ownership |
| Device | `device_id` + Ed25519 manifest key | Verified at enrolment |

Frame layout, segment headers (128 B, `CRN3` magic), the CRC-32 (IEEE) chain,
recovery scan, per-frame AEAD (**XChaCha20-Poly1305**, random 24 B nonces, AAD =
frame header ‖ segment header), and HKDF key derivation
(`K_seg` = HKDF-SHA256(`K_root`, salt = `vehicle_id`, …)) are **reused verbatim**
from format v3, except §2.3.

## 2.1 Delta: key escrow and acknowledgement authority

| Cairn v3 | Bealach |
|---|---|
| `K_root` escrowed to the server at enrolment | `K_root` escrowed to the **owner phone** at enrolment (and only there) |
| Deletion authorised by a **server-signed receipt** verified against a pinned server key | SD retention is default; optional reclaim is authorised per [deletion.md](deletion.md) by user action + **owner-phone signed mirror acknowledgement** verified against the pinned owner key |
| Bundle can be pruned once receipted | Bundle is retained until explicit reclaim |

## 2.2 Delta: manifest stamps (lessons applied)

- The manifest records **which engine profile produced the OBD data** (Cairn
  firmware #39), the profile version, and the firmware build identity.
- The manifest records the **UTC basis and its uncertainty** and whether frames
  carry `ESTIMATED_UTC` (Cairn firmware #38).
- `recovery_state` marks a recording resumed after interrupted writes.

## 3. Capture requirements

Recording **must not wait** for GNSS lock, ECU identification, stationary
calibration, BLE pairing, or a full-card scan. Fast startup and deferred
recovery are separate phases ([boot-budgets.md](../boot-budgets.md)).

Recorded streams (schemas in format v3 §4, carried over):

- `GNSS_SAMPLE` with quality fields (fix type, sats, HDOP, accuracies,
  constellations, UTC accuracy). `fix_type = 0` ⇒ position fields zero, prefer
  `GNSS_GAP` over fix-less runs.
- `IMU_SUMMARY` per window + `IMU_RAW_WINDOW` event bursts (raw timestamped XYZ
  accelerometer and gyroscope, 12 B/sample).
- `OBD_SNAPSHOT` allowlisted measurements with per-field sentinels,
  requested/answered bitmaps, measured cadence, error counts.
- `DEVICE_HEALTH` (vehicle supply mV, SD write errors, SD free space, device
  temp, degraded-health bitmap, abnormal reboot count).
- `TRIP_EVENT` and `STATE_TRANSITION` (incl. standby/wake pairs), `GNSS_GAP`,
  `POLICY_SNAPSHOT`, `TIME_OBSERVATION`.

**Raw measurements are preserved separately from derived trips and summaries.**
Derived products (trip segmentation, routes, statistics) live in the iOS store
and are recomputable from originals at any time.

## 3.1 Trip and leg segmentation (Q8 decision)

Raw recordings are continuous within a boot; trip and leg boundaries are
**derived on the phone**, not embedded in the recording format.

- **Leg boundary:** a stationary dwell longer than **5 minutes** (no meaningful
  GNSS displacement and vehicle speed below threshold) ends the current leg and
  starts a new one within the same trip. The dwell itself is not part of either
  leg.
- **Trip boundary:** a gap longer than **30 minutes** (engine off / no samples /
  device in standby) ends the current trip. The next recording activity starts a
  new trip.
- **Per-boot is not per-trip.** A device reboot mid-outing (e.g. power brownout
  during cranking) does not force a new trip; consecutive boots with gaps shorter
  than 30 minutes are merged into the same trip by the phone.
- **Manual correction:** the phone allows the user to split or merge trips after
  the fact. These edits are local derived state, never written back to SD.

These thresholds (5 min / 30 min) are initial values; they may be adjustable in
Phase 4 settings. The firmware records continuous data; segmentation is
interpretation.

## 4. Durability and loss

- Torn tail at power loss: recovery scan at boot discards the incomplete tail
  and **reports the byte count and stop reason**. Segments are never discarded
  because sealing failed; unsealed recordings are sealed at next boot.
- Storage exhaustion: recording degrades explicitly (health flags, loss records);
  bounded RAM pre-roll buffers (defined per milestone) cover SD-mount delay and
  are reported as lost if overwritten. Losses are recorded, never hidden.
- Missing sensors: the absent stream is absent and flagged; other streams
  continue.
- Absent phone: irrelevant to recording. The dongle never waits for it.

## 5. Conformance

- Carried vectors: format v3 `vectors/` (byte-level fixtures) must pass against
  the carried writer/reader before milestone 1 acceptance.
- Independent implementations must agree byte-for-byte: firmware (C) writer, iOS
  (Swift) reader/verifier. Where doc and implementation disagree, this contract
  (with its source spec) is correct.
