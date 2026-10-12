# BLE protocol v1

Custom GATT service between the iPhone (central) and the Cairn ESP32 dongle (peripheral). Typed characteristics, fixed binary layouts, little-endian, no CBOR/JSON/strings on the wire.

The authoritative copy of this spec is [contracts/ble/v1/spec.md](https://github.com/ParkWardRR/cairn-driving-log-selfhosted/blob/main/contracts/ble/v1/spec.md) in the Cairn front door; the firmware implements it in [cairn-esp32-device-firmware](https://github.com/ParkWardRR/cairn-esp32-device-firmware). Protocol changes start there, and this document follows.

The golden byte vectors are [contracts/ble/v1/vectors/golden/golden-vectors.json](https://github.com/ParkWardRR/cairn-driving-log-selfhosted/blob/contracts-v0.2.0/contracts/ble/v1/vectors/golden/golden-vectors.json). Nothing is vendored here: `contracts.lock` pins the release (tag and commit) and `scripts/fetch-contracts.sh` fetches it into `.contracts/`. They come from an independent Python implementation of the spec, and the iOS tests replay them.

## Discovery

| Item | Value |
|---|---|
| Service UUID | `A8E3xxxx-4F5B-11EF-A017-325096B39F47` (base; 16-bit suffix per characteristic below. Final values assigned when the spec lands in the firmware repo) |
| Scan filter | Service UUID only. Advertised name `Cairn` is display-only |
| Security | All characteristics require encrypted + authenticated access (`READ_ENC`/`WRITE_ENC` + `AUTHEN`). Unbonded phones can discover but not read, write, or subscribe |
| Bonding | Static 6-digit passkey from gitignored `secrets.h`. Bond limit 1; new bond replaces old. Bond reset via boot-time button or firmware command |

## Characteristics

| Name | Suffix | Dir | Size | Cadence | Phase |
|---|---|---|---|---|---|
| `GNSS_FIX` | `0001` | phone → device, write w/o response | 28 B | ~1 Hz | 1 |
| `GNSS_QUALITY` | `0010` | device → phone, notify | 8 B | 1 Hz | 1 |
| `COMPANION_STATUS` | `0011` | device → phone, notify | 8 B | 1 Hz | 1 |
| `PROTOCOL_VERSION` | `00F0` | read | 2 B | once | 1 |
| `BARO_ALT` | `0002` | phone → device | 4 B | ~1 Hz | 2 |
| `UTC_SYNC` | `0003` | phone → device | 8 B | connect + 1/min | 2 |
| `OBD_LIVE` | `0020` | device → phone | 48 B | ~1 Hz | 2 |
| `DEVICE_STATUS` | `0021` | device → phone | 12 B | 1 Hz | 2 |

`PROTOCOL_VERSION`: `u8 version` + `u8 capabilities bitmap`. The app refuses to stream to unknown major versions.

## `GNSS_FIX` (28 bytes)

| Off | Size | Field | Type | Units / sentinel |
|---:|---:|---|---|---|
| 0 | 4 | `lat_e7` | i32 | deg × 10⁷; 0 when position invalid |
| 4 | 4 | `lon_e7` | i32 | deg × 10⁷; 0 when position invalid |
| 8 | 4 | `alt_cm` | i32 | cm above WGS-84 ellipsoid; `0x7FFFFFFF` = invalid |
| 12 | 2 | `speed_cmps` | u16 | cm/s; `0xFFFF` = unavailable (CLLocation.speed < 0) |
| 14 | 2 | `heading_cdeg` | u16 | course over ground, centideg; `0xFFFF` = unavailable (CLLocation.course < 0) |
| 16 | 2 | `h_acc_cm` | u16 | cm; `0xFFFF` = invalid; clamped to 65534 on overflow, never wrapped |
| 18 | 2 | `v_acc_cm` | u16 | cm; `0xFFFF` = invalid; clamped to 65534 |
| 20 | 1 | `fix_type` | u8 | 0 none, 1 2D, 2 3D (mapping below) |
| 21 | 1 | `validity_flags` | u8 | b0 position, b1 altitude, b2 speed, b3 course |
| 22 | 2 | `sample_age_ms` | u16 | `now − CLLocation.timestamp` at write time |
| 24 | 2 | `seq` | u16 | monotonic, wrapping; duplicate detection + ack |
| 26 | 2 | `reserved` | u16 | 0 |

### `fix_type` mapping

| CLLocation | `fix_type` |
|---|---|
| `horizontalAccuracy < 0` | 0 |
| `horizontalAccuracy ≥ 0`, `verticalAccuracy < 0` | 1 (2D) |
| both ≥ 0 | 2 (3D) |

Core Location exposes no DGPS/RTK state, DOP, satellite count, or constellations. `sats_used`, `sats_visible` → `0xFF`; `hdop_e2` → `0xFFFF` in the stored sample.

### Reference systems

- Position: WGS-84 (matches bundle format v2).
- Altitude: height above the WGS-84 ellipsoid, as the bundle format specifies, not MSL.
- `heading_cdeg`: course over ground, not compass heading. `CLHeading` is a Phase 2 enrichment.

## `BARO_ALT` (4 bytes, Phase 2, phone → device)

| Off | Size | Field | Type | Units / sentinel |
|---:|---:|---|---|---|
| 0 | 4 | `rel_alt_cm` | i32 | cm relative to where `CMAltimeter` updates started; `0x7FFFFFFF` = invalid; clamped to `0x7FFFFFFE` |

Relative barometric altitude, not MSL and not the GNSS ellipsoid. The dongle should not mix it with `alt_cm` without a reference.

## `UTC_SYNC` (8 bytes, Phase 2, phone → device)

| Off | Size | Field | Type | Units / sentinel |
|---:|---:|---|---|---|
| 0 | 8 | `unix_ms` | u64 | phone wall clock, Unix milliseconds; sent on connect and about once a minute |

The app sends both only when the dongle exposes the characteristic, using write-without-response when offered, otherwise a confirmed write.

## `OBD_LIVE` (48 bytes, Phase 2, device → phone)

| Off | Size | Field | Type | Units / sentinel |
|---:|---:|---|---|---|
| 0 | 2 | `rpm` | u16 | RPM; `0xFFFF` = unavailable |
| 2 | 2 | `speed_kph_e1` | u16 | km/h × 10; `0xFFFF` = unavailable |
| 4 | 1 | `throttle_pct` | u8 | 0–100; `0xFF` = unavailable |
| 5 | 1 | `engine_load_pct` | u8 | 0–100; `0xFF` = unavailable |
| 6 | 2 | `coolant_temp_c` | i16 | °C; `0x7FFF` = unavailable |
| 8 | 2 | `intake_temp_c` | i16 | °C; `0x7FFF` = unavailable |
| 10 | 2 | `boost_kpa_e1` | i16 | kPa × 10 (signed, negative = vacuum); `0x7FFF` = unavailable |
| 12 | 2 | `maf_e2` | u16 | g/s × 100; `0xFFFF` = unavailable |
| 14 | 2 | `fuel_pressure_kpa` | u16 | kPa; `0xFFFF` = unavailable |
| 16 | 2 | `timing_adv_e2` | i16 | degrees × 100; `0x7FFF` = unavailable |
| 18 | 2 | `stft1_e2` | i16 | short-term fuel trim bank 1, % × 100; `0x7FFF` = unavailable |
| 20 | 2 | `ltft1_e2` | i16 | long-term fuel trim bank 1, % × 100; `0x7FFF` = unavailable |
| 22 | 2 | `stft2_e2` | i16 | short-term fuel trim bank 2, % × 100; `0x7FFF` = unavailable |
| 24 | 2 | `ltft2_e2` | i16 | long-term fuel trim bank 2, % × 100; `0x7FFF` = unavailable |
| 26 | 2 | `oil_temp_c` | i16 | °C; `0x7FFF` = unavailable |
| 28 | 2 | `voltage_mv` | u16 | system voltage in mV; `0xFFFF` = unavailable |
| 30 | 2 | `pid_bitmap` | u16 | which PIDs have valid data |
| 32 | 4 | `age_ms` | u32 | age of this OBD reading in ms |
| 36 | 12 | `reserved` | — | 0 |

## `DEVICE_STATUS` (12 bytes, Phase 2, device → phone)

| Off | Size | Field | Type | Units / sentinel |
|---:|---:|---|---|---|
| 0 | 1 | `trip_state` | u8 | 0 idle, 1 driving, 2 paused |
| 1 | 1 | `flags` | u8 | reserved |
| 2 | 2 | `health_bitmap` | u16 | b0 OBD ok, b1 GNSS ok, b2 SD ok, b3 IMU ok |
| 4 | 2 | `battery_mv` | u16 | device battery/system voltage in mV; `0xFFFF` = unknown |
| 6 | 2 | `sd_free_mb` | u16 | SD card free space in MB; `0xFFFF` = unknown |
| 8 | 4 | `uptime_s` | u32 | seconds since last boot |

## Staleness and timing

| Rule | Where | Value |
|---|---|---|
| Discard cached/old locations before encoding | iOS | `abs(now − location.timestamp) > 2 s` |
| Reject late arrivals | firmware | `sample_age_ms > CAIRN_PHONE_GNSS_STALE_MS` (3000) |
| Timestamp mapping | firmware | `fact.monotonic_ms = millis() − sample_age_ms` |
| Mapping error bound | | BLE latency (~10–30 ms) + phone measurement-to-send delay |

BLE receipt time is not measurement time. A cached fix arriving after reconnect must not become `last_gnss`, clear `DEGRADED_GNSS`, or influence trip scoring.

## `GNSS_QUALITY` (8 bytes, internal receiver)

Proposed layout (fields are fixed by the plan; offsets are not yet frozen): `fix_type` u8, `sats_used` u8, `hdop_e2` u16, `fix_age_ms` u32. Lets the app show both receivers side by side.

## `COMPANION_STATUS` (8 bytes, firmware acceptance feedback)

Proposed layout: `last_accepted_seq` u16, `accepted_count` u16, `rejected_count` u16, `queue_drop_count` u16.

The app's "Streaming" indicator means *the device recently acknowledged acceptance*, not that the phone called `write`.

## Firmware rejection rules

Reject and count when: payload ≠ 28 B, `sample_age_ms` over threshold, `validity_flags` b0 clear, duplicate `seq`, or fact queue full (counted as drop). Callbacks are bounded: validate, copy, non-blocking `xQueueSend`, return.

## Session semantics

- On disconnect: firmware clears all phone GNSS state (last fix, seq, counters). No replay.
- On reconnect: device accepts the phone's new `seq` without continuity from the prior session.
- Unknown protocol versions, characteristics, and flag bits: ignore flags, refuse unknown major versions.

## iOS write flow control

Use `canSendWriteWithoutResponse` and `peripheralIsReady(toSendWriteWithoutResponse:)`. Check `maximumWriteValueLength(for: .withoutResponse) ≥ 28` at connect. Flow control does not prove the firmware queue accepted the sample; `COMPANION_STATUS` does.
