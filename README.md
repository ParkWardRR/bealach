# Bealach

[![License: Blue Oak 1.0.0](https://img.shields.io/badge/license-Blue%20Oak%201.0.0-2ea44f)](LICENSE)
[![Status: TestFlight](https://img.shields.io/badge/status-TestFlight-34c759)](https://appstoreconnect.apple.com)
[![Phase 1-3: in progress](https://img.shields.io/badge/phase-1--3%20in%20progress-1f6feb)](ROADMAP.md)
[![Validation: simulator tested](https://img.shields.io/badge/validation-simulator%20tested-d4a017)](docs/acceptance-tests.md)
[![CI: local only](https://img.shields.io/badge/CI-local%20only-1f6feb)](ci/README.md)
[![GitHub Actions: not used](https://img.shields.io/badge/GitHub%20Actions-not%20used-6e40c9?logo=githubactions&logoColor=white)](ci/README.md)

[![Hardware: Freematics ONE+ Model B](https://img.shields.io/badge/hardware-Freematics%20ONE%2B%20Model%20B%20(ESP32)-555555)](docs/hardware-and-research.md)
[![App: iOS 18+](https://img.shields.io/badge/app-iOS%2018%2B-000000?logo=apple&logoColor=white)](docs/implementation-plan.md)
[![Transport: BLE only](https://img.shields.io/badge/transport-BLE%20only-0082fc?logo=bluetooth&logoColor=white)](docs/contracts/mirroring.md)
[![Cloud: none](https://img.shields.io/badge/cloud-none-2ea44f)](#what-it-deliberately-is-not)
[![Server: none](https://img.shields.io/badge/server-none-2ea44f)](#what-it-deliberately-is-not)
[![LTE uplink: none](https://img.shields.io/badge/LTE%20uplink-none-2ea44f)](#what-it-deliberately-is-not)
[![Accounts: none](https://img.shields.io/badge/accounts-none-2ea44f)](docs/threat-model.md)

[![Recording format: v3](https://img.shields.io/badge/recording%20format-v3-1f6feb)](docs/contracts/recording.md)
[![Mirror protocol: v1](https://img.shields.io/badge/mirror%20protocol-v1-1f6feb)](docs/contracts/mirroring.md)
[![Engine profiles: v1](https://img.shields.io/badge/engine%20profiles-v1-1f6feb)](harvest/contracts/engine/v1/README.md)
[![Crypto: XChaCha20-Poly1305 + Ed25519](https://img.shields.io/badge/crypto-XChaCha20--Poly1305%20%2B%20Ed25519-e8833a)](docs/threat-model.md)
[![Integrity: Merkle content roots](https://img.shields.io/badge/integrity-Merkle%20content%20roots-e8833a)](docs/contracts/recording.md)

[![Firmware: C / ESP-IDF](https://img.shields.io/badge/firmware-C%20%2F%20ESP--IDF-00599c)](harvest/README.md)
[![iOS: Swift / SwiftUI](https://img.shields.io/badge/iOS-Swift%20%2F%20SwiftUI-f05138)](harvest/README.md)
[![Vectors: golden](https://img.shields.io/badge/vectors-golden-6e40c9)](harvest/contracts/format/v3/vectors/README.md)
[![Dev tools: Rust / Go](https://img.shields.io/badge/dev%20tools-Rust%20%2F%20Go-6e40c9)](ci/README.md)

A sibling project to [Cairn](https://github.com/ParkWardRR/cairn-driving-log-selfhosted):
same landscape, different journey.

Bealach is an **offline driving recorder**: firmware for the
[Freematics ONE+ Model B](https://freematics.com/products/freematics-one-plus-model-b/)
OBD-II dongle plus a lightweight native iOS app. The dongle records drives to its own
microSD card, independently of any phone. The iPhone is the viewer and the verified
mirror: it pulls recordings over Bluetooth Low Energy, verifies them cryptographically,
and shows trips, maps, statistics and device health.

**No backend. No server. No cloud account. No website. No desktop client. No LTE
upload.** BLE is the only device-to-phone transport. The SD card is the source of
truth; the phone holds a verified local mirror and is the final verifier and store.

---

## Screenshots

<p align="center">
  <img src="docs/screenshots/01-drive-tab.png" width="200" alt="Onboarding">&nbsp;&nbsp;
  <img src="docs/screenshots/02-drive-tab.png" width="200" alt="Drive tab">&nbsp;&nbsp;
  <img src="docs/screenshots/03-trips-tab.png" width="200" alt="Trips tab">&nbsp;&nbsp;
  <img src="docs/screenshots/04-garage-tab.png" width="200" alt="Garage tab">&nbsp;&nbsp;
  <img src="docs/screenshots/05-settings-tab.png" width="200" alt="Settings tab">
</p>

*From left: onboarding, Drive (connection + telemetry), Trips, Garage (vehicle management), Settings (dongle enrolment, diagnostics, storage).*

## Status

**Phases 1-3 in progress.** Core firmware libraries (recording format, BLE
framing, crypto) and the full iOS app are migrated and building. The iOS app is
on TestFlight (`app.bealach.ios`, v0.1.0). Contracts are frozen, acceptance tests
cover the software-testable matrix, and dev tooling + CI run against golden
vectors. Hardware validation is pending.

Migration from Cairn is tracked in
[docs/migration-from-cairn.md](docs/migration-from-cairn.md); until a component is
carried over and tested here, it is not part of Bealach.

## What it does

- **Records on the dongle, phone or no phone:** GNSS with quality fields, raw
  timestamped accelerometer/gyroscope samples, vehicle supply voltage, a small
  allowlisted set of read-only standard OBD-II measurements, and recorder health
  (resets, losses, timing).
- **Mirrors to the iPhone securely over BLE:** explicit enrolment and ownership,
  encrypted authenticated access with no insecure fallback, resumable chunked
  transfer, integrity and authenticity checks, transactional import.
- **Shows the drive:** recent-trip summary, chronological trips with mini route
  maps, a zoomable trip detail map, vehicle association with manual correction, a
  Device screen, and a Storage & Mirror screen with real reconciliation state.
- **Keeps both copies honest:** SD originals are retained by default. “Matched”
  means matching authenticated content identities and validated contents — never
  equal byte counts or filenames.

## What it deliberately is not

- No arbitrary CAN tunnel, code clearing, coding, programming, actuator commands,
  security access, or manufacturer-specific probing.
- No continuous iPhone GPS or motion sensing; the dongle's sensors are the source.
- No server dependency of any kind at runtime, including at enrolment.
- Not a claim of zero operational risk — see
  [docs/vehicle-safety-and-power.md](docs/vehicle-safety-and-power.md).

## Architecture

```mermaid
flowchart TB
    subgraph vehicle["Vehicle"]
        obd["OBD-II bus<br/>allowlisted read-only PIDs"]
        power["12 V supply<br/>load dumps · brownouts · crank"]
    end

    subgraph dongle["Freematics ONE+ Model B · ESP32"]
        direction TB
        sensors["Sensors<br/>GNSS · ICM-42627 IMU · battery voltage"]
        capture["Capture pipeline<br/>journal · quality fields · explicit gaps"]
        seal["Seal &amp; sign<br/>Ed25519 manifest → Merkle content_root"]
        sd[("microSD — source of truth<br/>immutable sealed segments<br/>XChaCha20-Poly1305 frames")]
        ble["BLE mirror service<br/>bonded · encrypted · authenticated"]
    end

    subgraph phone["iPhone · iOS 18+"]
        direction TB
        enrol["Enrolment &amp; ownership<br/>Secure Enclave identity<br/>pinned keys · out-of-band fingerprint"]
        verify["Final verifier<br/>signature · digests · structure · AEAD"]
        mirror[("Verified local mirror<br/>encrypted at rest")]
        ui["Trips · maps · summaries<br/>Device · Storage &amp; Mirror"]
    end

    obd --> capture
    power -.->|must survive| capture
    sensors --> capture
    capture --> seal
    seal --> sd
    sd --> ble
    enrol <-->|"explicit local enrolment<br/>no server, no account"| ble
    ble <-->|"resumable verified chunk mirror<br/>LIST · GET_MANIFEST · READ"| verify
    verify --> mirror
    mirror --> ui
    verify -.->|"signed acks gate reclaim<br/>delete only what is verified"| sd

    classDef vehicle fill:#fff4e5,stroke:#f59e0b,color:#6b3f00
    classDef dongle fill:#e8f4ff,stroke:#0082fc,color:#0b3d66
    classDef phone fill:#f3e8ff,stroke:#7c3aed,color:#3b1f6e
    classDef store fill:#e8f8ee,stroke:#16a34a,color:#0b4a22
    class obd,power vehicle
    class sensors,capture,seal,ble dongle
    class enrol,verify,ui phone
    class sd,mirror store
```

- **Firmware** (ESP-IDF, C): capture to SD in immutable, versioned, authenticated
  recording segments; fast boot to first sample; BLE mirror service; owner-phone
  trust.
- **iOS app** (Swift/SwiftUI): AccessorySetupKit + Core Bluetooth for setup and
  connection, verified mirror import, trip browsing and maps (MapKit), settings,
  diagnostic export that excludes secrets and precise location by default.
- **Contracts** in [docs/contracts/](docs/contracts/): recording format, mirroring
  protocol, reconciliation semantics, deletion semantics. Test vectors are carried
  from Cairn where the contract is reused.

Security and fast boot are first-class acceptance criteria from milestone 1, not
later enhancements. See [docs/threat-model.md](docs/threat-model.md) and
[docs/boot-budgets.md](docs/boot-budgets.md).

## Relationship to Cairn

Bealach is related to [Cairn](https://github.com/ParkWardRR/cairn-driving-log-selfhosted)
but **independently buildable and usable**. It selectively migrates mature, tested
components from the Cairn repositories — the recording format, BLE framing, chunk
transfer, recovery and test-vector code — and replaces Cairn's server trust/receipt
model with authenticated device-to-owner-phone trust. No Cairn service is required
or contacted at runtime.

Provenance, pinned commits, and the reuse/adapt/exclude decisions:
[docs/migration-from-cairn.md](docs/migration-from-cairn.md).

## Development & CI

**CI is local only.** This project does not use GitHub Actions (or any hosted CI)
— checks run on your own machine, optionally in a Linux container via
[OrbStack](https://orbstack.dev/). See [ci/README.md](ci/README.md).

```sh
make ci        # run every check natively (macOS or Linux)
make ci-linux  # same checks inside a Linux container (OrbStack / Docker)
```

What runs today: documentation link integrity, a local-only-CI policy check, and
the staged Cairn test suites in `harvest/` (engine-profile generator in Rust,
contract tools in Go) against the pinned contract vectors.

## Repository layout

```text
README.md                          this file
ROADMAP.md                         step-by-step execution roadmap (phases, tracks, gates)
LICENSE                            Blue Oak Model License 1.0.0
Makefile                           make ci — the local CI entry point
app/                               Xcode app target (xcodegen), icons, entitlements
  project.yml                      xcodegen spec → Bealach.xcodeproj
  Sources/BealachApp.swift         app entry point wiring all dependencies
  Resources/                       Info.plist, assets, entitlements
ci/                                local-only check scripts, Linux container
  check.sh                         runs every check
  links.py                         documentation link integrity
  linux.sh                         run checks in a Linux container (OrbStack)
  Dockerfile                       reproducible CI environment
contracts/                         carried contract specs + test vectors (from Cairn)
  format/v3/vectors/               ~60 byte-level recording format fixtures
  ble/v1/vectors/                  BLE protocol vectors (golden, offload, device-info)
  engine/v1/vectors/               engine profile validation vectors
docs/
  migration-from-cairn.md          selective migration and provenance
  hardware-and-research.md         hardware capability inventory + external research
  threat-model.md                  trust model, threats, hardware security limits
  vehicle-safety-and-power.md      OBD policy, interference, parked battery drain
  boot-budgets.md                  boot/performance budgets and measurement procedure
  implementation-plan.md           phased plan with acceptance criteria
  acceptance-tests.md              required test matrix
  open-questions.md                resolved blocking and non-blocking questions
  contracts/
    recording.md                   immutable segments, manifests, identities, gaps (frozen)
    mirroring.md                   secure resumable BLE mirror to the owner phone (frozen)
    reconciliation.md              what “matches” means; mirror screen semantics (frozen)
    deletion.md                    deletion, retention, reset and re-download rules (frozen)
firmware/                          product firmware tree (scaffold; migration in Phase 1)
  THIRD-PARTY-NOTICES              provenance and license attribution
ios/                               product iOS app tree (scaffold; migration in Phase 1)
  THIRD-PARTY-NOTICES              provenance and license attribution
tools/                             dev tooling — never product scope
  blevectors/                      BLE protocol vector generation (Go)
  contractcheck/                   contract conformance checks (Go)
  enginelang/                      engine profile expression language (Go)
harvest/                           staged Cairn code for later migration (not product)
```

Development tooling (vector generators, contract checkers) lives apart from
product code and is not part of the product scope: there is no desktop product and
no web interface.

## License

[Blue Oak Model License 1.0.0](LICENSE). Components migrated from Cairn are also
Blue Oak Model License 1.0.0; attribution and provenance are recorded in
[docs/migration-from-cairn.md](docs/migration-from-cairn.md).
