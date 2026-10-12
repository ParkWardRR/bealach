# BLE device information and uplink events (ble/v1)

Lets the phone ask a dongle **what it is** before relying on it, and tells the phone when the
dongle is about to leave BLE for a Wi-Fi slot. It extends [`spec.md`](spec.md) (same service,
same bonding, little-endian, fixed layouts) and sits beside [`offload.md`](offload.md). The
instruction channel the phone uses to talk back is [`checkin.md`](checkin.md).

> **DEVICE_INFO released 2026-10-07.** Three independent implementations agree on the vectors
> in [`vectors/device-info/vectors.json`](vectors/device-info/vectors.json): the Go reference
> (`tools/blevectors`), a Python-on-OpenSSL cross-check, the firmware's C
> ([firmware #14](https://github.com/ParkWardRR/cairn-esp32-device-firmware/issues/14),
> 72/72 host rows), and the app's Swift
> ([iOS #27](https://github.com/ParkWardRR/cairn-ios-companion-app/issues/27), 7/7 vector
> rows). `UPLINK_EVENT`, `INSTRUCTION`, `INSTRUCTION_RESULT` and `HOME_TRIGGER` stay **draft**
> below: no firmware or app implements them yet. Context:
> [front door #21](https://github.com/ParkWardRR/cairn-driving-log-selfhosted/issues/21).

## 1. Characteristics

All require an encrypted, authenticated (bonded) link, like every other characteristic.

| Name | Suffix | Direction | Properties | Size |
|---|---|---|---|---|
| `DEVICE_INFO` | `0040` | device → phone | read (long read allowed) | 8 to 512 B |
| `UPLINK_EVENT` | `0041` | device → phone | notify | 24 B |
| `INSTRUCTION` | `0042` | phone → device | write with response (long write allowed) | see `checkin.md` |
| `INSTRUCTION_RESULT` | `0043` | device → phone | indicate | 8 B |
| `HOME_TRIGGER` | `0044` | phone → device | write with response | 6 B |

`PROTOCOL_VERSION` (`00F0`) byte 1 (capabilities) keeps its meaning (bit 2 = bundle offload) and
gains **bit 3 = device information present**. A phone **must not** read `DEVICE_INFO` unless that
bit is set. Every other capability is read from `DEVICE_INFO` itself (§2), so the one-byte bitmap
does not run out.

## 2. `DEVICE_INFO`

A header, then a list of records. An app reads it once per connection (it may re-read after
`UPLINK_EVENT` kind `RETURNED`, when storage and transport state have changed).

### Header (8 bytes)

| Off | Size | Field | Notes |
|---:|---:|---|---|
| 0 | 1 | `info_version` | `1`. An app **refuses** any other major version and says so |
| 1 | 1 | `info_minor` | `0` now. Raised when records or capability bits are added; an app accepts any minor of a major it knows |
| 2 | 2 | `total_len` | the whole value, header included, at most **512**; must equal the bytes read |
| 4 | 4 | `capabilities` | bitmask, below |

### Capability bits

| Bit | Meaning | Bit | Meaning |
|---:|---|---:|---|
| 0 | phone GNSS companion | 6 | home trigger (`HOME_TRIGGER`) |
| 1 | live OBD | 7 | Wi-Fi uplink hardware and firmware present |
| 2 | bundle offload | 8 | LTE uplink present |
| 3 | device information (this) | 9 | digest ([`digest/v1`](../../README.md)) supported |
| 4 | uplink events | 10 | configuration ([`config/v1`](../../README.md)) supported |
| 5 | instructions | 11-31 | reserved, 0 |

**An absent bit means the dongle cannot do it; an app never infers support from a name or a
version.** A set bit the app does not know is ignored. An app **hides** a feature whose bit is
absent instead of showing an error, and never writes to a characteristic whose bit is absent.

### Records

After the header, records of `u8 type ‖ u8 len ‖ value[len]`, in ascending `type` order. The
repeated types (`0x04`, `0x05`) keep the dongle's own order. **An unknown `type` is skipped** by
`len` and ignored, which is how a minor version adds records without breaking old apps. A
**known** type with a `len` other than the one below is a malformed value: the app discards the
whole `DEVICE_INFO` and treats the dongle as not reporting, rather than half-using a layout it
does not understand.

| Type | Name | Len | Value |
|---:|---|---:|---|
| `0x01` | firmware | 16 | `u8 major, minor, patch`; `u8 flags` (b0 dirty build, b1 release build, b2 secure boot on, b3 flash encryption on); `commit[8]` (first 8 bytes of the git commit); `u32 build_unix` |
| `0x02` | identity | 25 | `device_id[16]`; `fingerprint[4]` (first 4 bytes of SHA-256 of the device public key, the same as `enrolment/v1`'s fingerprint); `u8 enrol_state` (0 not enrolled, 1 enrolled, 2 assigned to a vehicle); `u32 storage_key_version` |
| `0x03` | storage | 8 | `u8 state` (0 no card, 1 ok, 2 read-only, 3 error); `u8 reserved`; `u16 pending_bundles`; `u32 free_mib` (`0xFFFFFFFF` unknown) |
| `0x04` | transport | 4 | one per transport: `u8 kind` (1 BLE, 2 Wi-Fi, 3 LTE); `u8 state` (b0 hardware present, b1 compiled in, b2 configured, b3 enabled, b4 available now); `u16 last_error` (0 none) |
| `0x05` | engine | 11 + `id_len` | one per installed engine profile: `u16 profile_version`; `hash[8]` (first 8 bytes of SHA-256 of the profile's canonical bytes, see `engine/v1`); `u8 id_len` (1 to 32); `engine_id` ASCII |
| `0x06` | boot timing | 16 | `u32 boot_to_ble_ms` (power-on to advertising); `u32 boot_to_ready_ms` (to able to start a capture); `u32 boot_to_first_fix_ms` (`0xFFFFFFFF` = no fix yet); `u8 reset_reason` (the chip's own code); 3 reserved bytes |
| `0x7F` | truncated | 0 | present when the list was cut to fit 512 bytes (below) |

`engine_id` is the one string on this characteristic: a short ASCII identifier such as `bmw-n20`
(the identifier, not display text; the app maps it to a name from its own copy of the profile).
The `hash` lets the app and the server notice that a dongle's compiled-in profile differs from the
one they hold, without reading the profile.

**If the value would exceed 512 bytes**, the dongle drops **engine** records from the end until it
fits and appends the `0x7F` record. An app that sees `0x7F` shows "more engines installed than
can be listed" and does not assume the list is complete. Nothing else is ever dropped.

**A dongle that has not finished booting** may report `0xFFFFFFFF` for a timing it does not yet
know. Timings are best-effort measurements, informational only, and **no decision of consequence
may depend on them**.

### What the app does with it

- Shows every field it understands (the iOS BLE settings page can show each one).
- Uses `transport` records to show which uplinks exist and which are configured, enabled and
  available now. It does **not** choose the path for a bundle: the dongle's uplink manager does.
- Compares each engine's `hash` with the profile it holds for that `engine_id` and flags a
  difference.
- Treats a `storage.state` other than 1, or a non-zero `last_error`, as a thing to surface.
- Does not cache `DEVICE_INFO` across firmware changes: `firmware` is part of it.

## 3. `UPLINK_EVENT` (24 bytes)

Without it the phone cannot tell a deliberate Wi-Fi slot from a lost link. Sent as a notification
**before** the dongle leaves BLE, and again on return.

| Off | Size | Field | Notes |
|---:|---:|---|---|
| 0 | 1 | `kind` | 1 `LEAVING`, 2 `RETURNED`, 3 `ABORTED` |
| 1 | 1 | `path` | 2 Wi-Fi, 3 LTE |
| 2 | 1 | `reason` | 1 scheduled, 2 phone-asserted home, 3 retry, 4 upload-now instruction, 5 trip started (aborted only) |
| 3 | 1 | `outcome` | `RETURNED` only: 0 all done, 1 partial, 2 failed, 3 no network; else 0 |
| 4 | 4 | `slot` | the dongle's count of slots, increasing; the server ledger records it (`uplink/v1` §2.3) |
| 8 | 2 | `max_seconds` | `LEAVING` only: the dongle promises to be back on BLE within this many seconds; else 0 |
| 10 | 2 | `committed` | `RETURNED`: bundles that received a receipt this slot |
| 12 | 2 | `failed` | `RETURNED`: bundles that did not |
| 14 | 2 | `reserved` | 0; a non-zero value makes the frame invalid |
| 16 | 4 | `bytes_sent` | `RETURNED`: bytes the dongle sent |
| 20 | 4 | `duration_ms` | `RETURNED`: how long the slot lasted |

Rules:

- A frame that is not exactly 24 bytes, has `kind` outside 1 to 3 or a non-zero `reserved` is
  ignored by the app and counted.
- After `LEAVING` the app **expects** silence for up to `max_seconds` plus a **10 s** grace and
  does not report the dongle lost, scan aggressively or alert. If neither `RETURNED` nor
  `ABORTED` arrives by then, it treats the link as lost and reconnects normally.
- `ABORTED` ends a slot early (a trip started, a time cap was reached) and carries the same
  `slot`; it is the only way a slot ends without `RETURNED`.
- The numbers in `RETURNED` are **reporting, not evidence**: the receipt on the server and the
  dongle's own state are what is true. An app must never display "uploaded" because of this
  message alone.
- A bounded slot is a security property ([threat model N8](../../../docs/threat-model.md)): a
  dongle sets a hard maximum and cannot be talked into a longer one over BLE.

## 4. `HOME_TRIGGER` and `INSTRUCTION`

Specified in [`checkin.md`](checkin.md).

## 5. Vectors

[`vectors/device-info/vectors.json`](vectors/device-info/vectors.json):

- `DEVICE_INFO`: a full value, a minimal one (header only), one with an **unknown record type**
  that must be skipped, a list too long for 512 bytes that must come back **truncated**, and three
  malformed values (bad `total_len`, unknown major version, a known record of the wrong length)
  that must be **rejected**.
- `UPLINK_EVENT`: leaving, returned (partial), aborted, and a 23-byte frame that must be rejected.
- Home triggers and signed instructions: see `checkin.md`.

Regenerate with `go run ./cmd/ble-vectors` from `tools/`; its test fails if the file drifts.
