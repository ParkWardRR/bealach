# Bealach

**Pronounced roughly “BYAL-ukh”** — Scottish Gaelic for a mountain pass, a passage, a
road. A sibling project to [Cairn](https://github.com/ParkWardRR/cairn-driving-log-selfhosted):
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

## Status

**Documentation-first. No code has been migrated yet, and nothing has been
hardware-validated under the Bealach name.** This repository currently holds the
architecture, contracts, threat model, budgets and the phased implementation plan.
Claims below marked *proposed* are targets, not measurements. Migration from Cairn
is planned and itemised in
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

```text
┌──────────────────────────────┐        BLE (bonded, encrypted,        ┌─────────────────────────────┐
│ Freematics ONE+ Model B      │        authenticated)                 │ iPhone (iOS 18+)            │
│                              │◄─────────────────────────────────────►│                             │
│  GNSS · ICM-42627 IMU        │   resumable verified chunk mirror     │  Bealach app                │
│  OBD-II (allowlisted reads)  │                                       │  · final verifier + store   │
│  vehicle voltage · microSD   │        ownership / enrolment          │  · encrypted local mirror   │
│                              │◄─────────────────────────────────────►│  · trips, maps, summaries   │
│  SD card = source of truth   │                                       │  · Storage & Mirror screen  │
│  (immutable sealed segments) │                                       │                             │
└──────────────────────────────┘                                       └─────────────────────────────┘
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

## Repository layout

```text
README.md                          this file
LICENSE                            Blue Oak Model License 1.0.0
docs/
  migration-from-cairn.md          selective migration and provenance
  hardware-and-research.md         hardware capability inventory + external research
  threat-model.md                  trust model, threats, hardware security limits
  vehicle-safety-and-power.md      OBD policy, interference, parked battery drain
  boot-budgets.md                  boot/performance budgets and measurement procedure
  implementation-plan.md           phased plan with acceptance criteria
  acceptance-tests.md              required test matrix
  open-questions.md                unresolved blocking questions
  contracts/
    recording.md                   immutable segments, manifests, identities, gaps
    mirroring.md                   secure resumable BLE mirror to the owner phone
    reconciliation.md              what “matches” means; mirror screen semantics
    deletion.md                    deletion, retention, reset and re-download rules
```

Development tooling (vector generators, contract checkers) will live apart from
product code and is not part of the product scope: there is no desktop product and
no web interface.

## License

[Blue Oak Model License 1.0.0](LICENSE). Components migrated from Cairn are also
Blue Oak Model License 1.0.0; attribution and provenance are recorded in
[docs/migration-from-cairn.md](docs/migration-from-cairn.md).
