# Selective Cairn migration and provenance

Bealach is a **new project**, not a Cairn component. It is independently buildable
and usable, and it requires no Cairn service at runtime. This document records
where the reused material comes from, what is reused/adapted/excluded and why,
which tests and dependencies travel with it, the licensing position, and the
architectural changes that remove Cairn's server assumptions.

Nothing listed as “reuse” has been migrated yet. This is the plan of record; the
first migration happens at [implementation-plan.md](implementation-plan.md)
milestone 1.

## Source repositories (pinned)

All four are ParkWardRR GitHub repositories, Blue Oak Model License 1.0.0,
extracted from the Cairn monorepo (tag `monorepo-final`,
`b3ada35e78414e0ed179b95f356231da877f80a9`) and pinned here at the commit
inspected for this plan (2026-10-10/11):

| Repository | Pinned commit | Role |
|---|---|---|
| [cairn-driving-log-selfhosted](https://github.com/ParkWardRR/cairn-driving-log-selfhosted) | `7ed8dac3212c504375427bf5690f0efa1349b18d` | Protocol contracts, test vectors, contract tooling |
| [cairn-esp32-device-firmware](https://github.com/ParkWardRR/cairn-esp32-device-firmware) | `ead3532202f7a85e4bcb63a401fdf0f662131566` | Freematics ONE+ Model B firmware (ESP-IDF, C) |
| [cairn-ios-companion-app](https://github.com/ParkWardRR/cairn-ios-companion-app) | `52f134eba85d45122fbd4e0aa252e00f5e52d9b7` | iOS companion (Swift/SwiftUI) |
| [cairn-modules](https://github.com/ParkWardRR/cairn-modules) | `10f4d784a76e761b152a78eb2e12854039993a05` | Interpretation modules (mostly excluded) |

The shared contracts release pinned by all of them is **contracts-v0.7.0**.
Cairn status is itself in motion (open blockers below), so the pins above are the
basis for migration decisions, and any code carried over must be re-verified
against Bealach's own contracts, not Cairn's roadmap.

Secondary sources inspected for context only (not migration sources):
`cairn-vehicle-server`, `cairn-vehicle-web-dashboard`,
`cairn-original-monorepo-archive` (archived).

## Known Cairn problems that Bealach inherits *lessons* from (not code)

From the firmware and app issue trackers at the pinned commits — these shaped
Bealach's contracts and acceptance tests:

| Cairn issue | Lesson carried into Bealach |
|---|---|
| firmware [#37](https://github.com/ParkWardRR/cairn-esp32-device-firmware/issues/37) — OBD reads blocked the sensing task (766 s of a 1002 s drive) | OBD must never starve GNSS/IMU/voltage recording; failure isolation is an acceptance test |
| firmware [#38](https://github.com/ParkWardRR/cairn-esp32-device-firmware/issues/38) — every trip dated 1970 (UTC basis lost/anchored wrong) | Time basis is explicit and uncertainty-carrying; ordering truth is `(boot_id, seq)` |
| firmware [#42](https://github.com/ParkWardRR/cairn-esp32-device-firmware/issues/42) — ECU quiet periods ≈ 23 s gaps | “ECU did not answer” is recorded explicitly, never interpolated |
| firmware [#44](https://github.com/ParkWardRR/cairn-esp32-device-firmware/issues/44) — BLE pairing failure blocked all offload | Stale-bond recovery and re-pairing are first-class flows and acceptance tests |
| firmware [#39](https://github.com/ParkWardRR/cairn-esp32-device-firmware/issues/39) — bundle does not record which engine profile produced it | Manifest stamps the engine profile |
| app [#40](https://github.com/ParkWardRR/cairn-ios-companion-app/issues/40) — trips shown per-boot, not per-outing | Trip/leg model is defined in the recording contract before UI |
| contracts [#25](https://github.com/ParkWardRR/cairn-driving-log-selfhosted/issues/25) / firmware [#19](https://github.com/ParkWardRR/cairn-esp32-device-firmware/issues/19) — boot budgets unmeasured | Budgets are proposed-vs-achieved, measured with the instrumented boot record |

## Migration table

Legend: **reuse** = carry over largely as-is (renamed); **adapt** = carry the
structure/algorithms with the listed changes; **exclude** = do not carry.

### A. Recording format and contracts — `cairn-driving-log-selfhosted` @ `7ed8dac`

| Item | Decision | Why | Tests / deps to carry |
|---|---|---|---|
| `contracts/format/v3/spec.md` (bundle format: segment headers, frames, CRC chain, recovery scan, Merkle `content_root`, XChaCha20-Poly1305 per frame, Ed25519 manifest sig, payload schemas `GNSS_SAMPLE`, `IMU_SUMMARY`, `IMU_RAW_WINDOW`, `OBD_SNAPSHOT`, `DEVICE_HEALTH`, `TRIP_EVENT`, `STATE_TRANSITION`, `GNSS_GAP`, …) | **reuse**, with the key-escrow change below | It is exactly Bealach's recording contract: immutable segments, versioned manifests, stable identities, authenticated contents, explicit sequence/gap, raw measurements separate from derived trips | `format/v3/vectors/` test vectors; CRC-32 IEEE convention note |
| `contracts/format/v3/vectors/` | **reuse** | Byte-level conformance fixtures | as-is |
| `contracts/ble/v1/offload.md` (framing: `LIST`, `GET_MANIFEST`, `READ`, `PUT_RECEIPT`, `ABORT`; MTU rules; `TRIP_ACTIVE`; content-addressed chunking; transfer-done CRC) | **adapt** | Framing, resumability and recovery are sound; the receipt gate is server trust and is replaced (below) | `contracts/ble/v1/vectors/offload/` + negative cases (`read_bad_arguments`, `unknown_bundle`, `trip_active`, `mtu_too_small`, …) |
| `contracts/ble/v1/device-info.md` | **reuse/adapt** | Device identity, firmware build, boot timing over BLE is needed on the Device screen | `vectors/device-info/` (draft vectors — verify before trusting) |
| `contracts/ble/v1/spec.md` (phone-GPS-in companion protocol) | **exclude** | Bealach's sensor source is the dongle; no phone-GPS assist stream | — |
| `contracts/ble/v1/checkin.md` (server-signed instruction channel) | **exclude** (settings come from the owner phone directly, authenticated) | No server exists to sign instructions | — |
| `contracts/enrolment/`, `contracts/sync/`, `contracts/store/`, `contracts/uplink/`, `contracts/share/` | **exclude** | Server APIs; replaced by device↔phone enrolment and local mirror semantics | — |
| `contracts/engine/v1` (per-engine YAML profiles) + `tools/enginegen` (firmware repo) | **reuse/adapt** | The allowlisted read-only PID set and formulas must be data-driven and reviewable | profile validation vectors; `enginegen` as dev tooling |
| `contracts/module/v1` + `cairn-modules` @ `10f4d78` | **exclude** | Interpretation modules for server/web stack; Bealach derives summaries on-device/iOS only | — |
| `tools/blevectors`, `tools/contractcheck`, `tools/uplinkvectors` | **reuse** (dev tooling only) | Vector generation and contract checking keep firmware/iOS honest | Go toolchain; kept out of product scope |

**Licensing/attribution:** all sources are Blue Oak Model License 1.0.0 (verified
in each repository's `LICENSE`). Reuse requires the license text or link travels
with the code (Blue Oak §Notices). A `THIRD-PARTY-NOTICES`-style section in the
eventual firmware/app trees must name the source repository, pinned commit and
license for every carried file.

### B. Firmware — `cairn-esp32-device-firmware` @ `ead3532`

| Item | Decision | Why | Tests / deps |
|---|---|---|---|
| `lib/cairn_bundle/`, `lib/cairn_fs/`, `lib/cairn_store/` (segment writer, sealing, recovery scan, journaling) | **reuse** | The SD-is-source-of-truth core: append-only segments, atomic seal, torn-tail recovery at boot | `test/host/bundle_test.c`, recovery/fault tests |
| `lib/cairn_offload/` (BLE offload protocol device side) | **adapt** | Keep framing/chunking; replace receipt verification against a *server* key with verification of a *phone* ack against the owner key pinned at enrolment; default **no prune** (see deletion contract) | `test/host/offload_test.c`, `offload_sim.c`, interop vs Go reader |
| `lib/cairn_blesec/` (bond fingerprint, stale-bond clearing, passkey pairing) | **reuse/adapt** | Hard-won pairing recovery (Cairn #44) is directly applicable | `test/host/blesec_test.c` |
| `lib/cairn_boottime/` + `src/boot_timing.*` (monotonic stage marks, budget check) | **reuse** | Bealach must instrument boot from day one | `test/host/boottime_test.c` (32 host rows) |
| `lib/cairn_engine/` + `engines/*.yaml` + `tools/enginegen/` | **reuse/adapt** | Allowlisted read-only OBD definitions, host-tested formulas | `test/host/engine_test.c` (exhaustive per-byte), enginegen tests |
| `lib/cairn_power/` (standby/wake policy, drive confirmation) | **reuse/adapt** | Vehicle-safety/parked-drain policy start point; re-tune with measurements | host tests + parked-drain measurement procedure |
| `lib/cairn_devinfo/` | **reuse/adapt** | Device screen: firmware build, capabilities, boot timing | `test/host/devinfo_test.c` |
| `lib/cairn_prov/` (provisioning store) | **adapt** | Becomes owner-phone enrolment: pin phone key, ownership reset | `test/host/prov_test.c` |
| `lib/cairn_log/`, `lib/cairn_format/`, `lib/cairn_config/` | **reuse/adapt** | Logging and binary format helpers; config becomes phone-provisioned settings (sealed to device key) instead of server-issued config arriving via iOS over BLE or the uplink | `test/host/config_test.c`, `log_host.c` |
| `lib/cairn_intake/`, `test/host/intake_test.c` | **adapt** | Cairn's “authorise a bundle before decrypting” checks (assignment, counter) map to mirror-import validation on the phone and on-device sanity checks | intake tests |
| `lib/cairn_digest/`, `lib/cairn_usage/`, `lib/cairn_uplink/`, `lib/cairn_modem/`, `lib/cairn_ota/` | **exclude** | LTE/Wi-Fi/server paths. No cellular, no uplink, no server-enrolled OTA in Bealach's scope | — |
| `src/` capture path (sensor tasks, OBD polling, trip policy, sealing) | **adapt** | Keep structure; must fix Cairn #37-class blocking (OBD on its own task with bounded time), stamp engine profile (#39), keep UTC basis (#38) | `test/host/` suite + hardware validation |
| `test/host/*` (host-side C tests: digest, faults, mutate, conformance, interop) | **reuse** (minus LTE/modem tests) | The cheapest regression net for carried code | `test/host/Makefile`, `engine.mk` |
| `emulator/` (Rust Freematics emulator) | **reuse/adapt** | CI without hardware | emulator tests |
| `third_party/freematics-base/` (vendored FreematicsPlus pieces) | **reuse** | Required for co-processor protocol (OBD + GNSS decode on the Model B) | upstream [Freematics](https://github.com/stanleyhuangyc/Freematics) (BSD-style; verify per-file headers and record in notices) |
| `research/` notes (parked drain BMW F32, N20 PID support, current draw, deep sleep) | **reuse** (as reference docs) | Real measurement provenance for power/OBD policy | — |
| `docs/esp32-hardening.md`, `docs/boot-timing.md` | **reuse/adapt** | Security limits and measurement procedure baselines | — |

### C. iOS app — `cairn-ios-companion-app` @ `52f134e`

| Item | Decision | Why | Tests / deps |
|---|---|---|---|
| `CairnCore/BLE/*` (`CairnGATTProfile`, `OffloadClient/Link/Messages/Session/Transfer`, `PayloadDecoder/Encoder`, `ReconnectPolicy`, `DeviceInfo`) | **reuse/adapt** | The BLE mirror client; strip server receipt relay, add phone-side verification + transactional import | `OffloadVectorTests`, `Contracts.swift` golden vectors |
| `CairnCore/Sync/BundleOffloader.swift` | **adapt** | Becomes the mirror engine: pull → verify → durable import (not relay-to-server) | `BundleOffloaderTests` |
| `CairnCore/Sync/SnapshotManifest.swift`, `TarReader.swift`, `SnapshotArchive/Store` | **reuse/adapt** | Manifest/verified-content bookkeeping for the mirror | `SnapshotManifestTests` |
| `CairnCore/History/*` (`DriveSegmenter`, `DriveSession`, `TripSnapshot`, `TripSummary`, `FuelEstimate`, `DriveStore`) | **reuse/adapt** | Trip derivation and summaries; segmenter must follow the trip/leg contract (Cairn app #40) | `DriveLogTests`, `FuelEstimateTests`, `ProbeFailureTests` |
| `CairnCore/Models/Vehicle.swift`, `VehicleStore`, maintenance/odometer models | **adapt** | Explicit vehicle identity with confidence and manual correction; persistent personal + temporary rental separation | `VehicleTests` |
| `CairnRuntime/Store/*` (`CairnDatabase`, GRDB stores, `StoreEncryption`) | **reuse** | Encrypted local store for the mirror and derived data (GRDB dependency) | store tests |
| `CairnRuntime/Auth/KeychainIdentityStore.swift`, `SecureEnclaveIdentity.swift` | **reuse/adapt** | Owner-phone identity (Secure Enclave P-256 or Ed25519) for enrolment and signed mirror acks | `EnrolmentServiceTests` (adapted) |
| `CairnRuntime/Views/*` (TripsView, TripMapThumbnail, TripComponents, design system) | **reuse/adapt** | Lightweight trip UI; MapKit detail screen and Storage & Mirror screen are new | UI tests later |
| `CairnCore/Auth/*` (server request signing), `CairnCore/Server/*`, `CairnRuntime/Server/*`, `Sync/SyncEngine`, `OutboxStore`, `BundleRelayService`, `TripSyncClient` | **exclude** | Server coupling: signed HTTP, bearer tokens, pinned CA, outbox relay | — |
| `CairnCore/Passkey/*`, `CairnRuntime/Passkey/*` (dashboard passkey login, web view) | **exclude** | Web-dashboard auth; no dashboard exists | — |
| `CairnRuntime/Location/*`, `EnrichmentPayloads` (phone GNSS assist) | **exclude** | Dongle sensors are the source; phone GPS/motion off by default (battery) | — |
| `CairnRuntime/CarPlay/*`, `CairnCore/CarPlay/*` | **exclude** (v1) | Optional features must justify energy/complexity cost; out of scope | — |
| App shell (`project.yml` XcodeGen, iOS 18.0 target, `UIBackgroundModes: bluetooth-central`) | **reuse/adapt** | iOS 18 floor enables AccessorySetupKit | XcodeGen toolchain |

**Licensing/attribution:** as above — Blue Oak 1.0.0 in every source repo; carry
the notice requirements with each migrated file. Vendored Freematics code has its
own upstream license; record it separately.

## Architectural changes to remove server assumptions

1. **Trust anchor is the owner phone, not a server.** In Cairn, `K_root` is
   escrowed to the server and deletions are authorised by a server-signed receipt
   verified against a key pinned in firmware. In Bealach the phone is the final
   verifier and store: at enrolment the dongle and phone verify each other's
   identities and pin keys (device Ed25519 manifest key on the phone; owner-phone
   public key on the device). There is no escrow server and no server key.
2. **Receipts become authenticated mirror acknowledgements.** The phone verifies
   the device-signed manifest, the Merkle `content_root`, chunk hashes and frame
   AEAD tags before importing; it then returns a signed acknowledgement naming the
   exact verified content (bundle id, content root, manifest hash). This is
   bookkeeping evidence and a *precondition* for user-approved SD reclaim — it is
   **not** an automatic delete trigger.
3. **SD retention is the default.** Cairn prunes on receipt; Bealach retains SD
   originals and only reclaims space via an explicit, configurable policy limited
   to verified mirrored data ([deletion.md](contracts/deletion.md)).
4. **Enrolment is local.** Cairn enrolment registers app and device with a server
   (P-256 signed requests, bearer tokens). Bealach enrolment is an explicit BLE
   setup flow (AccessorySetupKit-assisted) with identity verification (compare
   fingerprints out of band) and an ownership reset path. No account, no network.
5. **Configuration source.** Cairn gets config from the server (sealed to the
   device key) and via the iOS app over BLE. Bealach gets it from the phone over
   BLE: settings (sampling, retention, transfer) are written by the owner phone
   over the authenticated link, sealed to the device key, and validated against
   the same allowlists — no server issues them.
6. **No uplink stack.** LTE modem, Wi-Fi, uplink manager, digest, usage
   accounting are excluded. This also moots Cairn's residual-credentials finding
   (firmware #6): Bealach never provisions network credentials onto the dongle.
7. **Derived data lives on the phone.** Server-side interpretation modules are
   excluded; trips/summaries are derived from mirrored originals on the phone and
   kept separate from the originals themselves.

## Verification obligations

- Every migrated file is re-licensed under Bealach's LICENSE with a provenance
  note (source repo, pinned commit, path).
- Carried test vectors must pass against the carried implementations before any
  new feature work depends on them.
- Cairn's interop story (firmware C writer vs Go reader) becomes **firmware C
  writer vs iOS Swift reader** under Bealach; the vector suites are the common
  ground.
- No claim of “hardware-validated” is made for any migrated component until it
  has run on the physical ONE+ Model B under Bealach firmware and been recorded
  in [acceptance-tests.md](acceptance-tests.md) results.
