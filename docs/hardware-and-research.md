# Hardware capability inventory and external research notes

Scope: the **Freematics ONE+ Model B** dongle, the iPhone client, and the APIs and
documentation consulted for the design. Every external claim cites its source;
every unverified claim is labelled **[assumption]** or **[unverified]**.

## 1. Dongle: Freematics ONE+ Model B

Source: [Freematics ONE+ Model B product page](https://freematics.com/products/freematics-one-plus-model-b/)
(retrieved 2026-10-11), cross-checked against Cairn firmware research notes
(pinned commit `ead3532`, `research/`).

| Capability | Detail | Bealach use |
|---|---|---|
| MCU | Espressif ESP32, 16 MB flash, 8 MB PSRAM, 32 KB RTC | Firmware host (ESP-IDF) |
| Bluetooth | Dual-mode; BLE used for the phone link | Only device↔phone transport |
| GNSS | Integrated u-blox M9 module + active antenna (page also states “M8030 10 Hz” in its comparison table — **[unverified] which module revision a given unit carries; firmware must report what it sees**) | Position, speed, heading, quality fields |
| Motion sensor | Integrated **ICM-42627** (TDK 6-axis accelerometer + gyroscope) | Raw XYZ accel/gyro windows + summaries |
| Cellular | Integrated SIM7670 LTE CAT-1 | **Excluded from Bealach scope** (unused, unpowered) |
| Storage | microSD over SPI | Source of truth for recordings |
| Vehicle voltage | Read through the OBD connection | `DEVICE_HEALTH.battery_mv` |
| OBD protocols | CAN 500K/29-bit, CAN 250K/29-bit, CAN 500K/11-bit, CAN 250K/11-bit, KWP2000 Fast, KWP2000 5Kbps | Constrained standard-PID reads only |
| Co-processor | Vehicle ECU interfacing + GNSS NMEA decode, exposed to ESP32 via Freematics serial protocol | Via vendored `freematics-base` |
| Low power | Vendor states ~10 mA with GPS/cellular/Wi-Fi off **[vendor claim, unmeasured by us]** | Parked-drain target; measure before claiming |
| Buzzer | GPIO25 | Optional status UX (off by default) |
| External I/O | GPIO26, GPIO34, VCC, GND | Out of scope |

### 1.1 Sensor fields actually recorded

The recording contract ([contracts/recording.md](contracts/recording.md)) carries,
per the Cairn bundle format v3 payload schemas (already host-tested):

- **GNSS** (32 B): lat/lon e7, altitude cm, speed, heading, HDOP, horizontal and
  vertical accuracy, fix type, satellites used/visible, constellation source
  flags, UTC offset + UTC accuracy. Quality fields are mandatory and never
  synthesized; unknown accuracy is an explicit sentinel.
- **IMU summary** (20 B per window): accel RMS, per-axis accel peaks, gyro peak,
  variance, sample count, event flags (impact / hard brake / sharp turn / pothole).
- **IMU raw windows** (12 B/sample): `accel_x/y/z_mg`, `gyro_x/y/z_dps_e1`,
  nominal sample interval, trigger reason — persisted around detected events,
  with per-frame timestamps. **[assumption]** Full-scale ranges and maximum
  continuous rate of the ICM-42627 need datasheet confirmation at implementation
  (TDK ICM-42627 datasheet); the format stores milli-g and deci-dps and is range-
  agnostic.
- **OBD snapshot** (24 B): speed, RPM, fuel pressure, throttle, engine load,
  coolant temp, intake temp, timing advance, PID error count, requested/answered
  PID bitmaps, measured poll cadence. Every field has an explicit unavailable
  sentinel; “ECU reported 0” is distinguishable from “ECU did not answer”.
- **Device health** (16 B): vehicle supply mV, SD write errors, SD free MiB,
  device temperature, external sensor slots, degraded-health bitmap, abnormal
  reboot count.
- **Events and journal**: trip start/end, harsh dynamics (with honest
  unattributed-cause variant), capture recovery, state transitions including
  matched standby/wake pairs (what makes parked-drain a measurement).
- **Gaps**: explicit `GNSS_GAP` and missing-sensor reporting — never
  interpolation.

### 1.2 Hardware security limits (honest statement)

- The classic ESP32's eFuse flash-encryption key is not usable as a direct HKDF
  input (Cairn `docs/esp32-hardening.md` finding). Recording confidentiality
  comes from the XChaCha20-Poly1305 frame encryption under device-held keys, not
  from flash encryption.
- **No irreversible eFuse changes** (secure boot / flash encryption enablement)
  will be made without explicit owner approval and a tested recovery/update plan.
  Until then, a determined attacker with physical access and ESP32 tooling may
  extract keys from flash — the threat model says so plainly
  ([threat-model.md](threat-model.md)).
- The SD card is never the security boundary: it holds ciphertext. Physical
  extraction of the card yields blobs, not trips.

## 2. iPhone / iOS

| Topic | Finding | Source |
|---|---|---|
| Deployment floor | iOS 18.0 (matches Cairn app's current target) | Cairn `project.yml` |
| Accessory Setup Kit | iOS/iPadOS **18.0+**; privacy-preserving discovery/picker (`ASAccessorySession`, `ASDiscoveryDescriptor`), accessory renaming and **pairing removal** controls | [Apple — AccessorySetupKit](https://developer.apple.com/documentation/accessorysetupkit) (retrieved 2026-10-11) |
| Core Bluetooth background | `UIBackgroundModes: bluetooth-central` allows wake on BLE events; background scanning coalesces duplicates and slows; a wake gives ~10 s to finish and suspend | [Apple — Core Bluetooth Background Processing](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html) |
| State preservation/restoration | Opt-in via `CBCentralManagerOptionRestoreIdentifierKey`; system relaunches the app to complete pending connection/scan work after termination | same as above |
| Implications | Background mirroring is possible but **bounded**; design must batch, resume and back off. Unrestricted background execution cannot be assumed. AccessorySetupKit can present a pairing-removal affordance, but the app must not assume it can silently erase every system pairing record | — |

**[assumption]** Pairing/bonding uses BLE Just Works/Passkey per the ESP32 NimBLE
stack (as Cairn's `cairn_blesec` does); exact iOS pairing UX with
AccessorySetupKit migration of existing accessories (`ASMigrationDisplayItem`)
needs a device test pass.

## 3. External documentation consulted

1. Freematics ONE+ Model B product page (above) — hardware facts.
2. Apple AccessorySetupKit documentation (above) — setup/pairing APIs.
3. Apple Core Bluetooth background processing guide (above) — background limits,
   restoration.
4. [Blue Oak Model License 1.0.0](https://blueoakcouncil.org/license/1.0.0) —
   license text used verbatim in `LICENSE`.
5. Cairn repository-internal research (as cited): `research/research_notes/
   Freematics parked drain BMW F32/*` (current draw, bus sleep, deep-sleep
   feasibility), `BMW N20 OBD PID support/pid_formulas_and_support.md` (PID
   formulas and support provenance), `docs/boot-timing.md`, `docs/esp32-hardening.md`.

### 3.1 Not yet consulted (implementation-time TODOs)

- TDK ICM-42627 datasheet (ranges, noise, FIFO) — for raw-window rate and units
  validation.
- u-blox M9 integration manual (or M8030, per unit) — for quality-field semantics
  (HDOP/accuracy mapping).
- Espressif ESP-IDF BLE security docs (passkey, bonding, NVS encryption) — for
  the enrolment implementation.
- SAE J1979 / ISO 15031-5 text for the standard PID allowlist — to confirm each
  polled PID is standard, read-only Mode 01/09.

## 4. Assumptions register

| # | Assumption | Status |
|---|---|---|
| A1 | The fitted GNSS is a u-blox M9 (10 Hz capable); Freematics' own page conflicts (M9 vs M8030) | Unverified per unit; firmware reports observed capabilities |
| A2 | ICM-42627 raw streams at useful rates within the SPI/power budget | Unverified; needs datasheet + bench |
| A3 | BLE throughput in the 10–25 KB/s range at MTU 247 / 15–30 ms interval is achievable (Cairn offload doc claim) | Unverified under Bealach; measure in milestone 1 |
| A4 | Vendor ~10 mA parked figure applies with LTE unpowered | Vendor claim; measure (Cairn parked-drain notes are the starting point) |
| A5 | iOS 18 + AccessorySetupKit covers first-pair and re-pair UX for a bonded BLE peripheral | Needs device test |
| A6 | STM32 co-processor protocol from vendored `freematics-base` is sufficient for all standard PID reads needed | Derived from Cairn's working N20 profile; verify on other vehicles |
| A7 | Standard Mode 01/09 reads (incl. VIN) are safe on all target vehicles at the bounded rates defined in the safety policy | Policy-level; per-vehicle validation is ongoing duty |
