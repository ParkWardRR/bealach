# Cairn Bundle Format v3 — Normative Specification

**Status:** normative. Three independent implementations must agree byte-for-byte:
firmware (C, ESP-IDF), server (Go), emulator (Rust). Where this document and an
implementation disagree, this document is correct and the implementation is a
bug.

**Supersedes:** bundle format v2 (and v1 before it). There is no v2 read path,
no migration and no compatibility requirement: v2 recordings were test data and
v3 tooling does not read them. What changed and why is in §3.6 and
[trust-model-v3.md](../../../docs/trust-model-v3.md); the short version is that **every frame
is now AEAD-encrypted** and every segment and manifest is **bound to a vehicle,
an assignment and a monotonic device counter**.

Sections that did not change from v2 (the payload schemas in §4, the transfer
protocol in §6, the Merkle construction in §1.3) are unchanged on purpose: the
wire protocol keeps its `/api/v2/` path prefix because it did not change.

---

## 1. Design Rules

These follow from the project invariants. Every layout decision below traces to
one of them.

1. **A sealed bundle is never mutated.** Segments are append-only; sealing is a
   one-way transition marked by an atomic rename.
2. **No byte is deleted without a locally verified signed receipt.**
3. **Ordering truth is `(boot_id, seq)`, never wall-clock UTC.** UTC appears
   only as an estimate carrying its own uncertainty.
4. **Honest incompleteness beats fabricated continuity.** Absent data is
   recorded explicitly (`GNSS_GAP`), never interpolated.
5. **The SD card is never the security boundary.** It holds ciphertext; the keys
   live elsewhere (§3.6). Everything structural — torn tails, CRCs, the chain,
   the Merkle root, chunking — works on ciphertext, so integrity can be checked
   by anyone holding the bytes and confidentiality needs a key.
6. **A bundle names its vehicle and the assignment it was captured under**, and
   carries a counter the device increments in non-volatile storage that is not on
   the card. A restored old card therefore cannot be mistaken for new data.

### 1.1 Conventions

- All integers are **little-endian**, matching ESP32 native order.
- All offsets and sizes are in bytes.
- `u8/u16/u32/u64` are unsigned; `i8/i16/i32` signed two's complement.
- Reserved fields are **written as zero** and **ignored on read**. They are not
  a compatibility mechanism; `format_version` is.
- Multi-byte payload fields are 4-byte aligned by construction (§3.1).

### 1.2 Checksum

v3 uses **CRC-32** (reflected, polynomial `0xEDB88320` — the IEEE/zlib variant),
not CRC32C/Castagnoli.

> **Deviation, recorded deliberately.** The architecture review specified
> CRC32C. CRC32C has no meaningful error-detection advantage at these frame
> sizes, and CRC-32 is available in ESP32 ROM as `esp_rom_crc32_le`, so the
> constrained implementation gets an optimized routine for free. Availability on
> the device decides it. Go uses `hash/crc32.ChecksumIEEE`; Rust uses
> `crc32fast`.

ESP ROM uses an inverted convention. The canonical device-side invocation is:

```c
uint32_t cairn_crc32(const uint8_t *buf, size_t len) {
    return ~esp_rom_crc32_le(~0u, buf, len);
}
```

This yields values identical to `crc32.ChecksumIEEE` and `crc32fast`.

### 1.3 Hashing and the Merkle tree

SHA-256 throughout (ESP32 hardware-accelerated on the device side).

The Merkle tree is binary with explicit domain separation, so a leaf can never
be reinterpreted as an internal node:

```
leaf(d)          = SHA256(0x00 || d)
internal(l, r)   = SHA256(0x01 || l || r)
```

Build bottom-up over an ordered leaf list. If a level has an odd node count, the
final node is **promoted unchanged** to the next level — it is *not* duplicated.
Duplicating the last node admits two distinct leaf lists with the same root.

An empty leaf list has root `SHA256(0x02)` — a third distinct domain tag, so an
empty tree is not confusable with any leaf or node.

---

## 2. Bundle Layout on Device Storage

A bundle is a directory. Its name is the `bundle_id` (§5.1).

```
/cairn/bundles/<bundle_id>/
    seg-00000000.seg        capture segments, append-only, rotated by size
    seg-00000001.seg
    journal.seg             lifecycle state-transition journal (same framing)
    manifest.cbor           written once, at seal; absent until then
    manifest.sig            Ed25519 signature over manifest.cbor
```

### 2.1 Sealing is an atomic rename

The directory carries its lifecycle state in its own name:

```
<bundle_id>.open     capture in progress; manifest absent
<bundle_id>.sealed   manifest + signature present and verified
```

Sealing procedure, in this order, with no permitted reordering:

1. Flush and `fsync` every segment.
2. Rescan all segments, verifying every frame CRC (§3.3).
3. Build `manifest.cbor` in a temporary file `manifest.cbor.tmp`.
4. `fsync` the temporary file.
5. Write `manifest.sig.tmp`, `fsync`.
6. Rename both temporaries to their final names.
7. `fsync` the directory.
8. Rename `<bundle_id>.open` → `<bundle_id>.sealed`.

A crash at any step leaves the bundle recoverable: the raw segments are intact
and complete, and the absence of the `.sealed` suffix means sealing is simply
re-run at boot. **Segments are never discarded because sealing failed.**

### 2.2 Receipts live outside the bundle

```
/cairn/receipts/<bundle_id>.cbor
```

Receipts are stored outside the bundle directory so that pruning a payload can
never destroy the proof of its delivery, and are retained **longer** than the
bundles they acknowledge.

---

## 3. Segment File Format

An append-only sequence of framed records behind a fixed header.

### 3.1 Segment header — 128 bytes

| Offset | Size | Field | Notes |
|---:|---:|---|---|
| 0 | 4 | `magic` | ASCII `CRN3` = `43 52 4E 33` |
| 4 | 2 | `format_version` | u16, = `3` |
| 6 | 2 | `header_len` | u16, = `128` |
| 8 | 16 | `device_id` | 16 raw bytes (§5.2) |
| 24 | 16 | `boot_id` | 16 raw bytes, regenerated every power cycle |
| 40 | 16 | `vehicle_id` | 16 raw bytes, the vehicle the device was assigned to |
| 56 | 16 | `assignment_id` | 16 raw bytes, the specific device→vehicle assignment (a device moved between cars gets a new one) |
| 72 | 4 | `segment_index` | u32, 0-based within the bundle; `0xFFFFFFFF` is reserved for `journal.seg` |
| 76 | 4 | `first_seq` | u32, `seq` of the first frame in this segment |
| 80 | 8 | `opened_monotonic_us` | u64, device monotonic microseconds at open |
| 88 | 4 | `storage_key_version` | u32, selects which escrowed root `K_root` the segment key derives from |
| 92 | 8 | `device_counter` | u64, the device's monotonic bundle counter for the bundle this segment belongs to; identical in every segment of a bundle, journal included |
| 100 | 24 | `reserved` | zero |
| 124 | 4 | `header_crc32` | CRC-32 over bytes `[0, 124)` |

Bytes `[0, header_len-4)` — everything except the CRC — are authenticated as
associated data on every frame of the segment (§3.6). In v3 `header_len` is
exactly `128`, so that is `[0, 124)`; a reader must treat any other value as an
unsupported format rather than guess how a longer header would be authenticated, so the identity fields are not merely labels: altering any
of them without the key makes every frame fail its tag. The identity fields are
**readable without any key**, which is deliberate — intake must be able to
authorise a bundle (does this assignment exist, is this counter spent?) before
it ever decrypts anything.

`header_len` permits a reader to skip a longer header from a future version
without misparsing frames. It does not make a future format readable.

### 3.2 Frame — 24 bytes of envelope plus a sealed payload

| Offset | Size | Field | Notes |
|---:|---:|---|---|
| 0 | 2 | `frame_len` | u16, **total** frame bytes including this field, the nonce, the tag and the trailing CRC |
| 2 | 1 | `record_type` | §3.4 |
| 3 | 1 | `schema_version` | payload schema version, independent of `format_version` |
| 4 | 2 | `flags` | §3.5 |
| 6 | 2 | `reserved` | zero |
| 8 | 4 | `seq` | u32, strictly increasing by 1 across a chain (§3.2.1), not per segment |
| 12 | 4 | `monotonic_ms` | u32, milliseconds since the segment header's `opened_monotonic_us` |
| 16 | 4 | `prev_crc32` | u32, the `crc32` field of the preceding frame; `0` for the bundle's first frame |
| 20 | 4 | `reserved2` | zero — aligns the payload to a 4-byte boundary |
| 24 | 24 | `nonce` | 24 random bytes (§3.6) |
| 48 | N | `ciphertext` | the §4 payload, encrypted; same length as the plaintext |
| 48+N | 16 | `tag` | Poly1305 authentication tag |
| 64+N | 4 | `crc32` | CRC-32 over bytes `[0, 64+N)` — **over the ciphertext frame** |

So `frame_len = 68 + N`, where `N` is the plaintext payload length. Minimum valid
`frame_len` is `68` (empty payload); maximum is `4096`, so the largest
plaintext payload is `4028` bytes (v2: 4068).

Because the CRC and the `prev_crc32` chain are computed over the sealed bytes,
**a scanner needs no key to find a torn tail, a corrupt frame, a spliced chain or
a sequence gap.** The key adds one thing — authentication of every frame — and
nothing structural depends on it.

`monotonic_ms` as a 32-bit delta from the segment's open covers 49 days, far
beyond any segment lifetime, and costs 4 bytes instead of 8.

#### 3.2.1 Chains

A bundle contains **two independent chains**, each with its own `seq` space and
its own `prev_crc32` linkage:

| Chain | Files | Starts at |
|---|---|---|
| **Capture** | `seg-00000000.seg`, `seg-00000001.seg`, … in index order | `seq` 0, `prev_crc32` 0 in segment 0 |
| **Journal** | `journal.seg` | `seq` 0, `prev_crc32` 0 |

Capture segments continue one chain across a rotation, so verifying segment
*N+1* requires the final state of segment *N*. The journal is separate because
it records transitions that occur when no capture segment is open at all —
waking, sleeping, connecting, uploading, pruning. Forcing it to share a
sequence space would mean the journal could not be written while capture was
closed, which is precisely when most of its interesting entries happen.

A verifier must therefore scan the journal from a zero state, independently of
the capture segments, and must not treat the two chains' sequence numbers as
comparable.

**`prev_crc32` is the chain.** The review asked for a per-record chain hash;
a 32-byte SHA-256 per record would double the size of a 32-byte GNSS sample. The
4-byte predecessor CRC gives what the chain is actually for — detecting that a
record was removed, reordered or spliced — during a linear scan, without needing
the manifest. Whole-bundle tamper detection is provided by the signed
`content_root` (§5.3), which is strictly stronger than per-record chaining.

### 3.3 Recovery scan

Normative algorithm. Runs **automatically at boot**, not only from a CLI tool.

```
verify segment header: magic, format_version, header_len, header_crc32
  → any failure: segment is unusable; report, do not delete
expected_seq  = header.first_seq
expected_prev = 0 for segment_index 0, else last valid crc32 of the prior segment
offset        = header.header_len

loop:
  if remaining < 68                      → TORN_TAIL, stop
  read frame_len
  if frame_len < 68 or frame_len > 4096  → TORN_TAIL, stop
  if offset + frame_len > file_size      → TORN_TAIL, stop
  compute CRC-32 over [offset, offset+frame_len-4)
  if mismatch with trailing crc32        → CORRUPT_FRAME, stop
  if prev_crc32 != expected_prev         → CHAIN_BREAK, stop
  if seq != expected_seq                 → SEQ_GAP, stop
  if a key is available:
    derive K_seg (§3.6); open the frame with its AAD
    if the tag fails                     → AUTH_FAILED, stop
  accept frame
  expected_seq  += 1
  expected_prev  = this frame's crc32
  offset        += frame_len
```

A scan **without a key** runs every step except the authentication step. That is
the *structural* verdict; a scan with the device's root adds the *keyed* one.
`AUTH_FAILED` is distinct from `CORRUPT_FRAME` on purpose: the frame is
structurally perfect (CRC, chain, sequence all hold) and cryptographically
wrong, which is the signature of tampering with a repaired CRC, a frame moved
from another segment, or the wrong key — never of a power cut.

**Default behaviour is stop-at-first-invalid.** Every frame before the failure
point is valid and retained; everything from the failure point to EOF is
discarded as an incomplete tail. The byte count discarded and the stop reason
are both reported, never silently swallowed.

An optional **salvage mode**, used only by the offline recovery tool and never
on-device, may resynchronize past a damaged region by scanning forward for an
offset where a frame's CRC validates and its `seq` is plausible. Salvage mode
must report the isolated damaged byte range and must mark the resulting bundle
`salvaged`, which makes it ineligible for the normal upload path.

### 3.4 Record types

| Value | Type | Payload |
|---:|---|---|
| `0x01` | `GNSS_SAMPLE` | §4.1 |
| `0x02` | `IMU_SUMMARY` | §4.2 |
| `0x03` | `IMU_RAW_WINDOW` | §4.3 |
| `0x04` | `OBD_SNAPSHOT` | §4.4 |
| `0x05` | `DEVICE_HEALTH` | §4.5 |
| `0x06` | `TRIP_EVENT` | §4.6 |
| `0x07` | `STATE_TRANSITION` | §4.7 |
| `0x08` | `GNSS_GAP` | §4.8 |
| `0x09` | `POLICY_SNAPSHOT` | §4.9 |
| `0x0A` | `OBD_EXTENDED` | §4.11 |
| `0x0B` | `TIME_OBSERVATION` | §4.12 |

Unknown record types encountered by a reader are **skipped using `frame_len`**,
counted, and reported. An unknown type is not an error — it is how a newer
device remains partially readable by an older decoder. The frame CRC still
applies, so a skipped record is still integrity-checked.

### 3.5 Frame flags

| Bit | Name | Meaning |
|---:|---|---|
| 0 | `PRETRIP` | Record came from the pre-roll buffer; it precedes trip confirmation |
| 1 | `DEGRADED` | Captured while a degraded health state was active |
| 2 | `ESTIMATED_UTC` | The UTC basis was an estimate with no valid GNSS fix at write time |
| 3 | `POST_RECOVERY` | Written after a boot recovery, i.e. first record of a resumed capture |
| 4–15 | reserved | zero |

### 3.6 Encryption

Every frame is sealed with **XChaCha20-Poly1305**. The suite is named in the
signed manifest (`encryption_suite`, §5.1) as `xchacha20poly1305+hkdf-sha256/v1`,
so a future suite is an explicit, detectable change.

#### Key hierarchy

```text
K_root  32 random bytes, generated on the device with the hardware RNG, held in
        flash-encrypted NVS, escrowed to the server at enrolment, versioned by
        storage_key_version
  └─ K_seg = HKDF-SHA256( ikm  = K_root,
                          salt = vehicle_id,
                          info = "cairn/segment/v3" ‖ device_id ‖ assignment_id
                                 ‖ boot_id ‖ segment_index_u32le,
                          L    = 32 )
```

The vehicle id is the salt rather than part of `info` because it is the
identifier that must never be shared between keys: a thief who obtains one
vehicle's derived keys learns nothing about another's, even under one device
root. `storage_key_version` selects the root and `device_counter` is bound
through the AAD; neither is a KDF input, so advancing a counter never changes a
key.

#### Per-frame sealing

| Input | Value |
|---|---|
| key | `K_seg` |
| nonce | **24 random bytes per frame**, carried in the frame |
| plaintext | the §4 payload |
| AAD | the 24-byte frame header exactly as written (including `frame_len`, `seq`, `prev_crc32`) ‖ the segment header bytes `[0, header_len-4)` |

**The nonce is random, never derived from `seq`.** After a torn-tail truncation
the same `seq` is legitimately written again with *different* plaintext; a
seq-derived nonce would then encrypt two plaintexts under one `(key, nonce)`
pair, which leaks their XOR and, with Poly1305, the authenticator key. A 192-bit
random nonce makes a collision negligible without any state that a power cut
could lose. Generators in test mode draw nonces from a fixed stream so vectors
are reproducible; real writers use the hardware RNG.

#### What the AAD buys

| Attack | Result |
|---|---|
| Flip a ciphertext bit, repair the CRC | Tag fails → `AUTH_FAILED` |
| Move a valid frame to another segment, bundle, vehicle or device | AAD differs → `AUTH_FAILED` |
| Reorder or splice frames | `prev_crc32` chain breaks; the header is in the AAD |
| Edit any identity field in the segment header | Every frame of the segment fails |
| Decrypt with another vehicle's key | Wrong salt → wrong key → `AUTH_FAILED` |
| Decrypt with the wrong key version | Refused up front (`KEY_VERSION_MISMATCH`) rather than reported as tampering |

#### Where keys live

The device holds `K_root` and derives `K_seg` itself. The server holds the
escrowed root and derives the same keys from the segment header alone — the
header, not the caller, says which key applies. A copied card has ciphertext and
no root. Details, threat table and the ESP32 specifics (the eFuse flash key is
not usable as an HKDF input on a classic ESP32) are in
[trust-model-v3.md](../../../docs/trust-model-v3.md) §3 and [esp32-hardening.md](https://github.com/ParkWardRR/cairn-esp32-device-firmware/blob/main/docs/esp32-hardening.md).

---

## 4. Payload Schemas

All at `schema_version = 1` unless stated.

### 4.1 `GNSS_SAMPLE` — 32 bytes

| Offset | Size | Field | Units |
|---:|---:|---|---|
| 0 | 4 | `lat_e7` | i32, degrees × 10⁷ |
| 4 | 4 | `lon_e7` | i32, degrees × 10⁷ |
| 8 | 4 | `alt_cm` | i32, cm above WGS84 ellipsoid |
| 12 | 2 | `speed_cmps` | u16, cm/s |
| 14 | 2 | `heading_cdeg` | u16, centidegrees, 0–35999 |
| 16 | 2 | `hdop_e2` | u16, HDOP × 100 |
| 18 | 2 | `h_acc_cm` | u16, horizontal accuracy, cm |
| 20 | 2 | `v_acc_cm` | u16, vertical accuracy, cm |
| 22 | 1 | `fix_type` | 0 none, 1 2D, 2 3D, 3 DGPS, 4 RTK-float, 5 RTK-fixed |
| 23 | 1 | `sats_used` | u8 |
| 24 | 1 | `sats_visible` | u8 |
| 25 | 1 | `source_flags` | bit 0 GPS, 1 GLONASS, 2 Galileo, 3 BeiDou, 4 dead-reckoned, 5 external source (phone) |
| 26 | 4 | `utc_offset_ms` | i32, signed delta from `utc_basis_ms` (§5.1) |
| 30 | 2 | `utc_acc_ms` | u16, uncertainty of that UTC estimate; `0xFFFF` = unknown |

Quality fields are **mandatory and never synthesized**. A reader must not infer
a precision the receiver did not report: where the receiver supplies no accuracy
estimate, `h_acc_cm`/`v_acc_cm` are `0xFFFF` (unknown), not a plausible guess.

A sample with `fix_type = 0` carries no valid position. `lat_e7`/`lon_e7` must be
written as zero and must not be plotted. Prefer a `GNSS_GAP` record (§4.8) over
a run of fix-less samples.

### 4.2 `IMU_SUMMARY` — 20 bytes

| Offset | Size | Field | Units |
|---:|---:|---|---|
| 0 | 2 | `window_ms` | u16, window duration |
| 2 | 2 | `accel_rms_mg` | u16, RMS magnitude, milli-g |
| 4 | 2 | `accel_peak_x_mg` | i16 |
| 6 | 2 | `accel_peak_y_mg` | i16 |
| 8 | 2 | `accel_peak_z_mg` | i16 |
| 10 | 2 | `gyro_peak_dps_e1` | i16, deg/s × 10 |
| 12 | 2 | `variance` | u16, motion-intensity metric |
| 14 | 2 | `sample_count` | u16, raw samples in the window |
| 16 | 1 | `event_flags` | bit 0 impact, 1 hard brake, 2 sharp turn, 3 pothole |
| 17 | 3 | `reserved` | zero |

### 4.3 `IMU_RAW_WINDOW` — variable

A triggered burst, persisted around a detected event rather than continuously.

| Offset | Size | Field |
|---:|---:|---|
| 0 | 2 | `sample_count` u16 |
| 2 | 2 | `interval_us` u16, nominal spacing |
| 4 | 1 | `trigger_reason` u8, mirrors `IMU_SUMMARY.event_flags` bit index |
| 5 | 3 | `reserved`, zero |
| 8 | 12 × `sample_count` | samples |

Each sample is 12 bytes: `accel_x/y/z_mg` (i16 ×3), `gyro_x/y/z_dps_e1` (i16 ×3).

### 4.4 `OBD_SNAPSHOT` — 24 bytes

| Offset | Size | Field | Units |
|---:|---:|---|---|
| 0 | 2 | `speed_kph` | i16, `0x8000` = unavailable |
| 2 | 2 | `rpm` | i16, `0x8000` = unavailable |
| 4 | 2 | `fuel_pressure_kpa` | u16, `0xFFFF` = unavailable |
| 6 | 1 | `throttle_pct` | u8, `0xFF` = unavailable |
| 7 | 1 | `engine_load_pct` | u8, `0xFF` = unavailable |
| 8 | 1 | `coolant_temp_c` | i8, `0x80` = unavailable |
| 9 | 1 | `intake_temp_c` | i8, `0x80` = unavailable |
| 10 | 1 | `timing_advance_deg` | i8, `0x80` = unavailable |
| 11 | 1 | `pid_error_count` | u8, ECU non-responses since the last snapshot |
| 12 | 4 | `pids_requested` | u32 bitmap |
| 16 | 4 | `pids_answered` | u32 bitmap |
| 20 | 2 | `poll_cadence_ms` | u16, **actual** measured cadence, not the target |
| 22 | 2 | `reserved` | zero |

Every field has an explicit unavailable sentinel, and the requested/answered
bitmaps record PID availability per the review. A decoder must distinguish "the
ECU reported 0 kph" from "the ECU did not answer".

### 4.5 `DEVICE_HEALTH` — 16 bytes

| Offset | Size | Field | Units |
|---:|---:|---|---|
| 0 | 2 | `battery_mv` | u16, vehicle supply |
| 2 | 2 | `sd_write_errors` | u16, cumulative this boot |
| 4 | 2 | `sd_free_mib` | u16 |
| 6 | 1 | `device_temp_c` | i8 |
| 7 | 1 | `rssi_dbm` | i8. Always the unknown sentinel (`-128`) from firmware that has no Wi-Fi; the field is kept for format stability |
| 8 | 2 | `ext_sensor_1` | u16 |
| 10 | 2 | `ext_sensor_2` | u16 |
| 12 | 1 | `health_state` | bitmap of active degraded states (§4.10) |
| 13 | 1 | `reboot_count` | u8, consecutive abnormal reboots |
| 14 | 2 | `reserved` | zero |

### 4.6 `TRIP_EVENT` — variable

| Offset | Size | Field |
|---:|---:|---|
| 0 | 1 | `event_type` u8 |
| 1 | 1 | `detail_len` u8 |
| 2 | 2 | `reserved`, zero |
| 4 | 4 | `lat_e7` i32 |
| 8 | 4 | `lon_e7` i32 |
| 12 | `detail_len` | UTF-8 detail, not NUL-terminated |

`lat_e7`/`lon_e7` are zero when no valid fix was available; position validity is
carried by the nearest `GNSS_SAMPLE`, never assumed.

| `event_type` | Name | Meaning |
|---:|---|---|
| 1 | `TRIP_START` | A trip was confirmed. Written once, after `POLICY_SNAPSHOT` |
| 2 | `TRIP_END` | The stop dwell expired and the bundle is being sealed |
| 3 | `HARSH_BRAKE` | Decisive deceleration, attributed from a large negative speed change |
| 4 | `HARSH_ACCELERATION` | Decisive acceleration, attributed from a large positive speed change |
| 5 | `HARSH_CORNERING` | High lateral acceleration with little speed change |
| 6 | `IMPACT` | Acceleration far beyond any driving manoeuvre |
| 7 | `HARSH_MOTION` | Decisive dynamics that could **not** be attributed to a cause |
| 8 | `CAPTURE_RECOVERED` | This bundle resumed after an interrupted write; see the manifest's `recovery_state` |

Type 7 exists because attribution requires evidence the device may not have.
Distinguishing braking from cornering needs either the mounting orientation —
which is unknown without calibration — or a speed signal, which requires the
ECU to be answering. When neither is available the dynamics are still real and
still worth recording, so they are recorded as what they are: decisive motion
of unattributed cause. Guessing between brake and corner would produce a label
indistinguishable from a measured one.

A decoder must treat an unknown `event_type` as an event it does not understand
rather than discarding the record, so a newer device's events still appear in
an older decoder's output with their position and timing intact.

### 4.7 `STATE_TRANSITION` — 20 bytes

The lifecycle journal record. Written to `journal.seg`, and additionally in-band
in the capture segment for transitions occurring during capture.

| Offset | Size | Field |
|---:|---:|---|
| 0 | 1 | `region` u8 — 1 capture, 2 bundle, 3 connectivity, 4 health |
| 1 | 1 | `from_state` u8 |
| 2 | 1 | `to_state` u8 |
| 3 | 1 | `trigger_event` u8 |
| 4 | 1 | `reason_code` u8 |
| 5 | 1 | `policy_version` u8 |
| 6 | 2 | `reserved`, zero |
| 8 | 2 | `start_score_e2` u16 — evidence score × 100 at decision time |
| 10 | 2 | `stop_score_e2` u16 |
| 12 | 4 | `wake_cause` u32 — raw `esp_sleep_get_wakeup_cause()` |
| 16 | 4 | `reserved2`, zero |

Recording both evidence scores and the `policy_version` at every transition is
what makes a retune attributable and lets a replay tool prove *why* a trip
started, continued, split, finalized, retried or was retained.

#### 4.7.1 Power transitions in the health region

Standby is journalled in the health region as a **matched pair** of transitions
with `trigger_event = 4`:

| | `from_state` | `to_state` | `reason_code` |
|---|---:|---:|---|
| entering standby | 0 (awake) | 1 (standby) | 0 |
| leaving standby | 1 (standby) | 0 (awake) | wake reason |

Wake reasons: `0` none, `1` motion, `2` engine voltage, `3` periodic health.

The duration of a standby window is the difference between the two frames'
`monotonic_ms`, and carries no field of its own. On the ESP32 standby is light
sleep rather than deep sleep, so the millisecond clock runs straight through it —
that continuity is what makes the subtraction valid, and it is the reason a
reader must not substitute UTC here.

**Both records are required to measure parked power consumption.** A supply
voltage series from `DEVICE_HEALTH` cannot on its own distinguish a device that
slept for six hours from one that sat awake for six hours, and those differ by
roughly an order of magnitude in current. With the windows recorded, each voltage
sample is attributable to the state the device was actually in, and the decay
slope across a long park becomes a measurement rather than an estimate.

An unmatched entry — a device that announced standby and never recorded a
return — is itself meaningful: it means the device lost power while asleep, or
reset instead of waking. It must be reported, not repaired by assuming a wake.

### 4.8 `GNSS_GAP` — 12 bytes

| Offset | Size | Field |
|---:|---:|---|
| 0 | 4 | `duration_ms` u32 |
| 4 | 2 | `expected_samples` u16 — samples that would have been written |
| 6 | 1 | `cause` u8 — 1 no fix, 2 receiver reset, 3 powered down, 4 tunnel/obstruction, 5 time jump |
| 7 | 1 | `reserved`, zero |
| 8 | 4 | `reserved2`, zero |

This record is the mechanism for invariant 4. A decoder renders a gap as a
discontinuity; it must never join the route across it.

### 4.9 `POLICY_SNAPSHOT` — variable

A deterministic CBOR map (§5) of the active detection thresholds, written once
per bundle at `CONFIRMING_TRIP`. Makes every bundle self-describing with respect
to the policy that produced it, so a retune is reconstructable after the fact.

`policy_version` alone is not enough. It identifies a policy but does not
describe it, so interpreting an old bundle would mean finding the firmware build
that defined that version. Recording the values themselves means a bundle
captured under thresholds nobody remembers is still explainable from the bundle.

| Key | Field | Units |
|---:|---|---|
| 1 | `policy_version` | u8, matches `STATE_TRANSITION.policy_version` and the manifest |
| 2 | `gnss_period_ms` | nominal GNSS sampling period |
| 3 | `imu_window_ms` | IMU summary window |
| 4 | `obd_period_ms` | nominal OBD polling period |
| 5 | `health_period_ms` | health record period |
| 6 | `start_score_threshold_e2` | evidence score × 100 required to suspect motion |
| 7 | `stop_score_threshold_e2` | evidence score × 100 required to suspect rest |
| 8 | `start_dwell_ms` | how long motion must persist before a trip is declared |
| 9 | `stop_dwell_ms` | how long rest must persist before a trip is sealed |
| 10 | `motion_accel_rms_mg` | accelerometer RMS treated as motion |
| 11 | `motion_speed_cmps` | speed treated as motion |
| 12 | `preroll_window_ms` | pre-trip retention window |
| 13 | `preroll_ring_samples` | pre-trip ring capacity, in records |
| 14 | `segment_max_bytes` | segment rotation size |
| 15 | `adaptive_sampling` | u8, 1 when event-adaptive rates are active (§4.9.1) |

Keys ascend and are encoded per §5, so the map is byte-identical for identical
policy — which is what lets a reader group bundles by policy without trusting
the version number.

#### 4.9.1 Event-adaptive sampling

When `adaptive_sampling` is 1, the nominal periods above are upper bounds rather
than fixed rates: the device may sample *faster* when the vehicle is doing
something worth resolving, and no slower than nominal while a trip is active.

The direction is deliberate. A reader may assume a record every
`gnss_period_ms` at worst during a trip, so a gap longer than that is still a
gap and still recorded as one (§4.8). Adaptation can only add detail, never
remove it, which keeps the guarantee a bundle makes independent of what the
device decided at the time.

Rates are not themselves recorded per sample. The frames carry their own
monotonic timestamps, so the achieved rate is recoverable from the data rather
than needing to be asserted alongside it.


### 4.11 `OBD_EXTENDED` — 24 bytes

The boosted-engine and mixture signals. A separate record from `OBD_SNAPSHOT`
rather than more fields on it, for two reasons: that record has only two
reserved bytes left, and support for these PIDs varies far more between vehicles
— so a car answering the basic set but not these still produces clean snapshots
instead of one record half full of sentinels.

| Offset | Size | Field | Units |
|---:|---:|---|---|
| 0 | 2 | `map_kpa` | u16, intake manifold **absolute** pressure, PID `0x0B`, `0xFFFF` = unavailable |
| 2 | 2 | `maf_cgps` | u16, mass air flow in centigrams/s, PID `0x10`, `0xFFFF` = unavailable |
| 4 | 2 | `lambda_e4` | u16, equivalence ratio × 10000, from raw `((A*256)+B) ÷ 32768`, PID `0x44`, `0xFFFF` = unavailable |
| 6 | 2 | `abs_load_raw` | u16, **raw** `((A*256)+B)` from PID `0x43`; percent is `raw × 100 ÷ 255`, `0xFFFF` = unavailable |
| 8 | 1 | `baro_kpa` | u8, barometric, PID `0x33`, `0xFF` = unavailable |
| 9 | 1 | `ambient_temp_c` | i8, PID `0x46`, `0x80` = unavailable |
| 10 | 1 | `fuel_trim_short_pct` | i8, PID `0x06`, `0x80` = unavailable |
| 11 | 1 | `fuel_trim_long_pct` | i8, PID `0x07`, `0x80` = unavailable |
| 12 | 4 | `pids_requested` | u32 bitmap |
| 16 | 4 | `pids_answered` | u32 bitmap |
| 20 | 2 | `poll_cadence_ms` | u16, actual measured cadence |
| 22 | 1 | `fuel_level_pct` | u8, PID `0x2F`, `0xFF` = unavailable |
| 23 | 1 | `pedal_pct` | u8, accelerator pedal position, PID `0x49`, `0xFF` = unavailable (§4.11.2) |

**Pressures are absolute, as the ECU reports them.** Gauge pressure — what a
boost gauge shows — is `map_kpa − baro_kpa`, and PSI is that times 0.1450377. It
is computed at decode and never stored, because storing gauge would bake one
barometric reading permanently into the record. The same drive re-examined at a
different elevation, or with a corrected barometric source, must still yield the
raw measurement the ECU actually gave.

A reader that has `map_kpa` but not `baro_kpa` **must report boost as unknown
rather than assuming 101 kPa.** Sea level is an assumption, not a measurement,
and a plausible wrong number is worse here than an admitted absence.

**Two PIDs are stored raw, not converted.** `0x43` and `0x44` are both two-byte
values, and converting on the device would discard information the standard
formulas need: `abs_load_raw × 100 ÷ 255` spans 0–25700%, and
`lambda = raw ÷ 32768` has fifteen bits of resolution. Storing raw also means a
conversion error is fixable by re-decoding rather than by reflashing — which
mattered here, because the first implementation trusted a vendor library that
reads `0x43` as a single byte through an `A × 100 ÷ 255` helper. On a true 150%
load, raw `0x017F`, that yields 0.39%, and because byte A advances once per
100% of load the result sawtooths instead of saturating: the entire range of
interest on a boosted engine rendered as noise near zero.

`maf_cgps` is in centigrams so a u16 spans a turbocharged engine's range
without losing idle resolution. Note that a library which pre-divides to whole
grams defeats this; the field has the resolution regardless of whether a given
implementation supplies it.

### 4.11.1 `map_kpa` saturates, and where it saturates matters

PID `0x0B` carries a single byte, so manifold pressure hard-stops at 255 kPa
absolute — roughly **22.3 psi** of gauge boost at sea level. That ceiling falls
inside the range a modified car operates in: a stock N20 peaks near 221 kPa, a
Stage 2 map around 253, and some targets exceed 260.

Past the limit the log shows a **flat plateau at exactly 255**, not a rollover —
which reads precisely like a boost controller holding steady. A reader must
therefore flag saturation rather than present it as a measurement, because the
difference between "the tune is flat-lining" and "the instrument is" is not
recoverable from the number alone.

PID `0x4F` byte D declares the vehicle's own maximum manifold pressure as
`D × 10` kPa and is the standard-defined way to learn the real ceiling instead
of assuming 255. PID `0x87` is also defined as intake manifold absolute
pressure with a wider range, though its scaling could not be sourced with
confidence and it is not yet read.

### 4.11.2 `pedal_pct` is the driver, `throttle_pct` is the engine

These two are not interchangeable and the difference decides whether a log can be
read at all.

`throttle_pct` (`OBD_SNAPSHOT`, PID `0x11`) is the throttle **plate** angle. On a
drive-by-wire engine the ECU opens the plate as far as *it* decides, not as far as
the pedal travelled, so it does not reach 100% at wide-open throttle and its
reading at WOT is vehicle-specific. Measured on an N20 over a 1002 s drive: 77%
was the highest value anywhere in the trip, and during the one sample that caught
8.6 psi of boost at 4142 rpm it read **32%**.

`pedal_pct` (PID `0x49`) is the driver's demand. It is what identifies a pull as
wide open, and without it a reader cannot separate "the driver asked for
everything" from "the engine chose to give this much" — which is the first
question asked of any performance log.

**This field took the record's last reserved byte.** Bundles sealed before it was
defined carry `0x00` there, which is indistinguishable from a genuine 0% pedal by
value alone. A reader must therefore consult the `pids_requested` bitmap: a field
that was never requested carries no measurement regardless of the byte's value.
That bitmap already existed for exactly this purpose, which is what makes
reclaiming the byte safe rather than ambiguous.

Unlike `OBD_SNAPSHOT`, this record **is written even when no PID answered**.
Which of these an ECU supports is only discoverable by asking, so one record of
sentinels with `pids_answered = 0` is the evidence that it supports none —
better recorded once than re-inferred from an absence on every analysis.

### 4.12 `TIME_OBSERVATION` — 16 bytes

One wall-clock reading from one source, recorded as evidence rather than as a
decision. Written whenever a source yields a time, including when it merely
confirms what another source already said.

| Offset | Size | Field | Units |
|---:|---:|---|---|
| 0 | 8 | `utc_ms` | u64, Unix epoch milliseconds as the source reported them |
| 8 | 4 | `acc_ms` | u32, the source's own uncertainty; `0xFFFFFFFF` = not stated |
| 12 | 1 | `source` | u8, §4.12.1 |
| 13 | 1 | `flags` | u8, bit 0 = this observation was adopted as the manifest's `utc_basis_ms` |
| 14 | 2 | `reserved` | zero |

The monotonic reading of the same instant is the **frame's** `monotonic_ms`, not a
field here. That pairing is the whole value of the record: `utc_ms − monotonic_ms`
is the UTC of monotonic zero implied by this source, so two observations from
different sources can be compared directly, and drift within one source is
visible across a trip.

#### 4.12.1 Sources

| Value | Source | Notes |
|---:|---|---|
| `1` | `GNSS` | The receiver's date and time. Needs a fix, so it can be minutes into a drive or never. |
| `2` | `PHONE` | A paired phone's clock, over the BLE link. Network-synchronised in practice, and available before any fix. |
| `3` | `MODEM_NETWORK` | The cellular network's time, from the modem. Available whenever the modem attaches. |
| `4` | `RTC` | A battery-backed real-time clock. Reserved: no current hardware fits one. |

Server ingest time is deliberately **not** a source here. The server stamps its
own clock on arrival and has no reason to round-trip it through a device record.

### 4.12.2 Why observations and not just a basis

The manifest's `utc_basis_ms` (§5.1) stays exactly as specified: one basis, chosen
on the device, which every reader can already use. These records do not replace it
— they make it checkable, and they make a bundle useful when it is absent.

Three things forced this:

- **A single basis cannot be revised.** It is taken once, from the first source to
  produce a date, and a later and better source cannot improve it without moving
  the time reference under samples already written against the original. Keeping
  the observations separate means the basis stays stable while the evidence
  accumulates.
- **A drive with no GNSS fix was undated entirely.** Measured: every trip on one
  deployment carried `utc_basis_ms = 0` and decoded to 1970-01-01. The phone and
  the cellular network both had the time throughout; nothing could record it.
- **Sources disagree, and the disagreement is data.** A phone clock, a GNSS
  receiver and a network each have different accuracy and different failure modes.
  Choosing between them is a policy question that belongs where policy can change
  without reflashing, so the device records what each said and the consumer
  decides.

A reader that wants one answer should prefer the lowest `acc_ms`, break ties by
source order above, and treat a source whose implied basis drifts across a trip as
suspect. A reader that only wants the device's own choice reads the manifest and
ignores these records entirely — which is what makes the addition safe.

### 4.10 Degraded-state bitmap

`DEVICE_HEALTH.health_state` is a bitmap, not an enum.

That choice is the point of the field. Degradation is not ordered: a vehicle
can be low on battery *and* without a GNSS fix *and* out of card space at the
same time, and these have different causes and different fixes. A scalar
severity would force a priority between them and silently discard the rest —
reporting "critical" for the battery while losing the fact that position was
also unavailable. Every active condition is therefore its own bit, and a reader
can recover the full set.

| Bit | Value | Name | Meaning |
|---:|---:|---|---|
| 0 | `0x01` | `DEGRADED_GNSS` | No usable position: the receiver is absent, unresponsive, or has reported no fix for longer than one sample period |
| 1 | `0x02` | `DEGRADED_STORAGE` | Writes are failing, or free space has fallen below the floor reserved for capture |
| 2 | `0x04` | `DEGRADED_TIME` | No UTC basis has been established, so sample times are monotonic-only |
| 3 | `0x08` | `DEGRADED_NETWORK` | Bundles are awaiting a receipt and the server could not be reached |
| 4 | `0x10` | `LOW_POWER` | Supply voltage is below the threshold at which capture is still trusted |
| 5 | `0x20` | `RECOVERY_REQUIRED` | The open capture could not be safely extended and must be sealed as-is |
| 6 | `0x40` | `DEGRADED_SENSING` | A sensor other than GNSS is unavailable, or sensor readings were dropped before being recorded |
| 7 | `0x80` | — | Reserved, zero |

`0x00` means no degraded condition is active. It is not the same as "healthy in
every respect this device could measure" — it means nothing on this list is
true, which is the only claim the device is in a position to make.

Two rules follow for writers:

1. A bit is set from *observed* conditions, never from inference. `DEGRADED_GNSS`
   means no fix arrived, not that one seems unlikely.
2. `DEGRADED_TIME` is set whenever the UTC basis is absent, including before the
   first fix of a trip. This is normal rather than exceptional, and saying so is
   what stops a reader treating monotonic-only timestamps as if they were UTC.

A decoder must preserve unknown bits rather than masking them off, so a bundle
from newer firmware stays interpretable for the conditions an older decoder does
understand.

---

## 5. Manifest

`manifest.cbor` is **deterministically encoded CBOR**, RFC 8949 §4.2.1 core
deterministic encoding:

- definite-length maps and arrays only;
- integer map keys, sorted ascending;
- smallest-width integer encoding;
- no indefinite-length strings, no tags, no floats.

Integer keys and a specified encoding together mean the signed byte sequence is
reproducible across implementations and firmware versions. An ad hoc
serialization that varies between versions would invalidate historical
signatures.

### 5.1 Fields

| Key | Name | Type |
|---:|---|---|
| 1 | `manifest_version` | u8, = 3 |
| 2 | `bundle_id` | 16 bytes, ULID |
| 3 | `device_id` | 16 bytes |
| 4 | `device_key_id` | 8 bytes, truncated SHA-256 of the device public key |
| 5 | `boot_id` | 16 bytes |
| 6 | `firmware_version` | text |
| 7 | `schema_version` | u8 |
| 8 | `capture_started_monotonic_us` | u64 |
| 9 | `capture_ended_monotonic_us` | u64 |
| 10 | `utc_basis_ms` | u64, the UTC basis GNSS deltas are relative to |
| 11 | `utc_basis_acc_ms` | u32, uncertainty of that basis |
| 12 | `first_seq` | u32 |
| 13 | `last_seq` | u32 |
| 14 | `record_counts` | map of `record_type` → count |
| 15 | `members` | array of `[name, length, sha256]`, sorted by name |
| 16 | `chunk_descriptors` | array of `[chunk_index, byte_length, sha256]` |
| 17 | `content_root` | 32 bytes (§5.3) |
| 18 | `previous_bundle_root` | 32 bytes, or null for the first bundle |
| 19 | `policy_version` | u8 |
| 20 | `recovery_state` | u8 — 0 clean, 1 recovered tail, 2 salvaged |
| 21 | `discarded_tail_bytes` | u32 |
| 22 | `signature_algorithm` | text, `"ed25519"` |
| 23 | `trip_seq` | u32, optional — ties the capture to the sequence of drives, not just the boot |
| 24 | `vehicle_id` | 16 bytes — must equal every segment header's |
| 25 | `assignment_id` | 16 bytes — must equal every segment header's |
| 26 | `device_counter` | u64 — must equal every segment header's; starts at 1 |
| 27 | `storage_key_version` | u32 — must equal every segment header's |
| 28 | `encryption_suite` | text, `"xchacha20poly1305+hkdf-sha256/v1"` |
| 29 | `engine_profile` | array `[id (text), version (u8), sha256 (32 bytes)]`, optional (§5.1.1) |

Keys 24–28 are **mandatory**. Keys 23 and 29 are optional and sort into their
numeric positions, so a manifest has 27 to 29 fields.

#### 5.1.1 `engine_profile`, and why a bundle has to name it

The engine profile decides the multi-PID request, every value conversion, the
hot/cold tiering and cold rotation, the polling cadences, and the engine-on and
drive-confirmation thresholds. A bundle that does not name it leaves a reader
unable to say whether a timing figure came through `clamp(A/2-64, -127, 127)` or
something else — in a format whose purpose is being checkable years later, that is
a hole rather than an omission.

The **digest, not just the name**, because a profile edited without a version bump
is a different profile and only the digest says so. It is the SHA-256 of the
profile document as `contracts/engine/v1` defines it, which is the same value the
generator reports.

Optional, following key 23: a bundle produced by a device with no profile — or by
one built before this key existed — is still valid and still signed over whatever
keys are present. A reader must not require it.

Readers should prefer this over parsing `firmware_version`. Devices have carried
the profile there as a suffix (`cairn-v2.0.0-dev+bmw-n20@400cbc`) because that
field already existed, but it is a 32-byte text field with no room to spare and no
structure, so the suffix is dropped rather than truncated when a version string
grows. The suffix is a stopgap; this key is the contract.

The signature covers the deterministic CBOR encoding of every present key. It is stored
separately in `manifest.sig`, so the signed bytes are exactly the file bytes with
nothing to strip or re-encode.

`previous_bundle_root` is **populated but not enforced** in v3. It enables
detecting deleted historical bundles later, which is a different threat model
from detecting corruption within one bundle.

### 5.2 Identities, and why there are three

The review is right that a content hash makes a poor operational handle. v3
keeps three distinct identifiers with non-overlapping jobs:

| Identifier | Job | Stability |
|---|---|---|
| `bundle_id` | ULID. Retries, receipts, support, directory naming, log correlation | Assigned at bundle open; never changes |
| `content_root` | Identity of the *data*. Deduplication, idempotency, the signed commitment | A function of content; identical data yields an identical root |
| `transfer_hash` | SHA-256 of a transferred byte stream. Transport integrity only | Per transfer; not an identity |

`device_id` is 16 raw bytes rather than a string, keeping the segment header
fixed-width. It is the truncated SHA-256 of the device's enrollment certificate
public key.

### 5.3 `content_root`

Merkle root (§1.3) over one leaf per bundle member, members sorted by raw name
bytes ascending:

```
leaf_input = len(name) as u16 LE || name bytes || sha256(member contents)
leaf       = SHA256(0x00 || leaf_input)
```

`manifest.cbor` and `manifest.sig` are **not** members — the root is an input to
the manifest, so it cannot cover it.

Defining identity over members rather than over an archive's bytes keeps it
independent of archive framing. Hashing a tar stream would make identity depend
on mtime, uid and padding, so re-packing identical data would produce a
different identity.

### 5.4 Binding rules

A verifier that has both the manifest and its members must reject the bundle
unless, for **every** segment header (journal included):

- `device_id`, `boot_id`, `vehicle_id`, `assignment_id`, `device_counter` and
  `storage_key_version` equal the manifest's. This includes `journal.seg`: a
  bundle resumed after a reboot keeps the boot, vehicle, assignment and counter
  it was opened under, in every segment, because the manifest can state only one;
- for a capture segment, `segment_index` equals the index in its member name
  (`seg-%08d.seg`), and the capture segments are named contiguously from 0; for
  `journal.seg`, `segment_index` is the reserved `0xFFFFFFFF`. Without this a
  segment could be renamed into another position while keeping the inputs to its
  own key derivation.

The server additionally applies rules that need state (see
[trust-model-v3.md](../../../docs/trust-model-v3.md) §2): the assignment must be one it issued
for that device and vehicle and must not have been superseded by a newer
assignment seen at a lower counter; the counter must not already be bound to
different content (the same pair is an idempotent duplicate, a different content
root under a spent counter is **quarantined**); and an escrowed root must exist
for `storage_key_version`, so the server never accepts what it cannot decode.
Assignment validity is judged by counter order, **not** the clock (invariant 3).

---

## 6. Transfer Protocol

Manifest-first, content-addressed, resumable by hash.

```
1. OFFER     device → POST /api/v2/bundles/offer      { manifest.cbor, manifest.sig }
             server verifies signature, device enrollment, key id
             server → { bundle_id, missing_chunks: [indices], existing_receipt? }

2. TRANSFER  for each missing chunk:
               device → PUT /api/v2/bundles/{bundle_id}/chunks/{sha256}
               server verifies the chunk hash against chunk_descriptors
               server → { accepted, remaining: [indices] }

3. COMMIT    device → POST /api/v2/bundles/{bundle_id}/commit
             server reassembles members, recomputes member digests,
               recomputes content_root, compares to the signed manifest
             server durably commits raw objects + manifest
             server persists the receipt BEFORE responding
             server → { receipt.cbor }

4. VERIFY    device verifies the receipt signature against the pinned server key
             device verifies receipt.content_root == its own manifest's
             device persists the receipt outside the bundle directory
             device marks the bundle RECEIPT_VERIFIED
```

### 6.1 The bundle byte stream, and how chunks map to members

Chunks and members are different partitions of the same bytes, so the mapping
between them must be exact rather than conventional.

The **bundle byte stream** is the concatenation of member contents in canonical
member order — sorted by raw name bytes ascending, the same order the content
root uses:

```
stream = contents(members[0]) || contents(members[1]) || ... || contents(members[n-1])
```

Chunks partition that stream in order and without gaps or overlap.
`chunk_descriptors[i]` covers the stream byte range:

```
start(i) = sum of chunk_descriptors[j].byte_length for j < i
end(i)   = start(i) + chunk_descriptors[i].byte_length
```

Two consistency requirements follow, and a server must check both before
committing:

1. `sum(chunk_descriptors[*].byte_length)` equals `sum(members[*].length)`.
   A mismatch means the manifest is internally inconsistent, whatever its
   signature says.
2. `chunk_descriptors[i].index == i`. Indices are positional, not identifiers.

Member boundaries and chunk boundaries are deliberately independent: a member
may span several chunks and a chunk may span several members. Tying them
together would force a re-chunk whenever a member's size changed.

Reassembly is therefore: concatenate chunks in index order to rebuild the
stream, split the stream at the cumulative member lengths, verify each member's
SHA-256, then recompute `content_root` and compare it to the signed value.

### 6.2 Rules

- **Chunks are addressed by hash, never by byte offset.** This is what makes
  re-chunking safe and deduplication possible. A byte offset cannot survive
  either endpoint changing its chunk size.
- Default chunk size is 256 KiB. The device may choose any size; the manifest's
  `chunk_descriptors` are authoritative for that bundle.
- Idempotency is keyed on `content_root`, not on connection, request ID or
  `bundle_id`. Re-offering identical data returns the existing receipt.
- A chunk acknowledgement is **not** a receipt. It means bytes were accepted,
  not that a reconstructable bundle was committed.
- Every protocol step is journaled on the device before it is attempted, so a
  reboot resumes rather than rediscovers.
- **Transport (amended 2026-10-05).** The dongle has no network. The offer,
  chunks, commit and receipt below are carried by the enrolled phone
  ([app-sync-protocol.md](../../sync/v1/spec.md) §13) and the bytes reach the phone over
  BLE ([ble-offload.md](../../ble/v1/offload.md)). The server authenticates the **phone**
  (signed request) and the **device** (the manifest's Ed25519 signature against the
  enrolled key, plus a denylist). The legacy `:8443` mTLS path, where a device
  certificate's CommonName identified the device, is retired.

### 6.3 Receipt

Deterministic CBOR, same rules as the manifest.

| Key | Name | Type |
|---:|---|---|
| 1 | `receipt_version` | u8, = 2 |
| 2 | `receipt_id` | 16 bytes |
| 3 | `device_id` | 16 bytes |
| 4 | `bundle_id` | 16 bytes |
| 5 | `content_root` | 32 bytes |
| 6 | `server_ingest_utc_ms` | u64 |
| 7 | `server_key_id` | 8 bytes |
| 8 | `ingest_schema_version` | u8 |
| 9 | `stored_object_ids` | array of text |
| 10 | `signature_algorithm` | text, `"ed25519"` |
| 11 | `signature` | 64 bytes over the deterministic encoding of keys 1–10 |

A receipt is only an acknowledgement if **both** its signature verifies against
the pinned server key **and** its `content_root` equals what the device
uploaded. A valid signature over a different bundle is not an acknowledgement of
this one.

---

## 7. Conformance

An implementation is conformant when it passes every vector in
`contracts/format/v3/vectors/` (see its README for the **public test keys**). The vectors
are the executable form of this document. Every segment vector states two
verdicts: *structural* (no key) and *keyed* (with the vector's root).

| Vector | Asserts |
|---|---|
| `valid-minimal` | One frame of each record type, clean seal |
| `valid-multi-segment` | `seq` continuity and `prev_crc32` chaining across a rotation |
| `torn-tail-mid-frame` | Truncation inside a payload → `TORN_TAIL`, preceding frames retained, discarded byte count exact |
| `torn-tail-mid-header` | Truncation inside a frame envelope → `TORN_TAIL` |
| `bad-frame-crc` | Single flipped payload bit → `CORRUPT_FRAME` at that frame, not before |
| `chain-break-spliced` | One frame removed from the middle → `CHAIN_BREAK` |
| `seq-gap` | `seq` skips a value → `SEQ_GAP` |
| `bad-header-crc` | Corrupt segment header → segment unusable, not deleted |
| `unknown-record-type` | Unknown type skipped via `frame_len`, counted, remainder parsed |
| `clock-jump` | UTC estimate jumps backwards mid-segment → ordering unchanged, record retained |
| `gnss-gap` | A gap record is preserved and never interpolated across |
| `empty-segment` | Header only, zero frames → valid, empty |
| `max-frame` | `frame_len = 4096` accepted; 4097 rejected |
| `manifest-valid` | A valid manifest re-encodes to identical bytes across implementations, and its signature verifies |
| `manifest-bad-signature` | Flipped signature bit → rejected |
| `auth-tag-tampered` | Ciphertext bit flipped, CRC repaired → structurally clean, keyed `AUTH_FAILED` |
| `frame-moved-between-segments` | A valid frame transplanted → structurally clean, keyed `AUTH_FAILED` (AAD binds the segment) |
| `wrong-vehicle-key` | Key derived for another vehicle → `AUTH_FAILED` |
| `wrong-key-version` | Provider holds a different version → `KEY_VERSION_MISMATCH`, not tampering |
| `manifest-segment-header-mismatch` | Manifest and a segment header disagree (§5.4) → rejected |
| `manifest-members-match` | Manifest and segment headers agree → accepted |
| `journal-segment` | The journal's reserved `segment_index` and independent chain |
| `health-bitmap` | The degraded-state bitmap and its unknown bits round-trip |
| `obd-extended` | `OBD_EXTENDED` fields, sentinels and `fuel_level_pct` decode |
| `trip-event-types` | Every `TRIP_EVENT` type decodes |
| `policy-snapshot` | `POLICY_SNAPSHOT` encodes and re-encodes identically |
| `receipt-valid` | A genuine receipt verifies against the pinned key |
| `update-descriptor-valid` / `-bad-signature` | A signed update descriptor verifies; a flipped signature is rejected |
| `merkle-odd-leaves` | Odd leaf count promotes rather than duplicates; root matches the reference |
| `merkle-empty` | Empty tree root = `SHA256(0x02)` |
| `content-root-member-order` | Member ordering is by raw name bytes; permuted input yields the same root |
| `receipt-wrong-content-root` | Valid signature over a different root → rejected as an acknowledgement |
| `header-bad-magic` / `header-unsupported-format-version` / `header-short` | A header that is not a v3 header, declares another format version, or is cut short → refused, keyed or not, never read on |
| `frame-header-tampered` | A frame header field edited, CRC repaired → structurally clean, keyed `AUTH_FAILED` |
| `manifest-tampered-body` / `manifest-wrong-device-key` | A manifest edited after signing, or signed by another key → signature rejected |
| `manifest-unsupported-version` / `manifest-non-canonical` / `manifest-missing-mandatory-field` | Correctly signed but unreadable manifests → refused at parse |
| `manifest-device-id-mismatch` … `manifest-segment-gap` (nine vectors with `manifest-segment-header-mismatch`) | Every §5.4 binding rule, one vector each: device, boot, vehicle, assignment, counter, key version, capture index, journal index, contiguous naming |
| `receipt-bad-signature` / `receipt-wrong-server-key` / `receipt-tampered-content-root` | A receipt whose signature does not verify against the pinned key, including one edited to carry the uploaded root → not an acknowledgement |
| `receipt-unsupported-version` / `receipt-non-canonical` / `receipt-truncated` / `receipt-trailing-bytes` | A receipt that cannot be read → refused at parse, before any signature |
| `update-descriptor-tampered-body` / `update-descriptor-wrong-key` | A descriptor edited after signing, or signed by the receipt key → refused |

Each vector directory contains the input bytes, the expected parse verdict and
the expected derived values, so a conformance runner needs no implementation
knowledge beyond this document.
