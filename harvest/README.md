# Harvest — staged Cairn code for later migration

A working dump of **useful, reusable code** extracted from the Cairn repositories
so a later agent can harvest it into Bealach's product trees. This is **staging
material, not product code**: nothing here is built, renamed, or validated yet,
and nothing in `harvest/` ships as-is. The selection follows
[../docs/migration-from-cairn.md](../docs/migration-from-cairn.md) — read that
first; it says what to reuse, adapt, or drop and why.

## Provenance (pinned)

| Tree | Source repository | Pinned commit | License |
|---|---|---|---|
| `firmware/` | [ParkWardRR/cairn-esp32-device-firmware](https://github.com/ParkWardRR/cairn-esp32-device-firmware) | `ead3532202f7a85e4bcb63a401fdf0f662131566` | Blue Oak Model License 1.0.0 |
| `contracts/` | [ParkWardRR/cairn-driving-log-selfhosted](https://github.com/ParkWardRR/cairn-driving-log-selfhosted) | `7ed8dac3212c504375427bf5690f0efa1349b18d` | Blue Oak Model License 1.0.0 |
| `ios/` | [ParkWardRR/cairn-ios-companion-app](https://github.com/ParkWardRR/cairn-ios-companion-app) | `52f134eba85d45122fbd4e0aa252e00f5e52d9b7` | Blue Oak Model License 1.0.0 |

Blue Oak 1.0.0 is the same license as Bealach itself (`../LICENSE`). The Notices
obligation applies: any file moved into product trees keeps a provenance note
(source repo, pinned commit, path). Vendored Freematics code under
`firmware/third_party/freematics-base/` retains its upstream license terms —
record those separately when harvesting it.

All commits in the source repositories descend from the Cairn monorepo
(`monorepo-final`, `b3ada35e78414e0ed179b95f356231da877f80a9`).

## Layout

```text
firmware/                  ESP-IDF firmware (C) for the Freematics ONE+ Model B
  lib/                     cairn_* modules minus the excluded ones (below)
  src/                     app: boot, capture tasks, sensors, sealing
  include/                 config.h, board_config.h, secrets.h.example
  engines/                 engine YAML profiles (allowlisted OBD definitions)
  test/host/               host-side C tests + Makefiles
  tools/enginegen/         Rust profile generator
  third_party/freematics-base/   vendored Freematics co-processor protocol
  research/                measurement notes (parked drain, PID support, …)
  docs/                    esp32-hardening, boot-timing, flashing, hardware-roundtrip
  Makefile, contracts.lock
contracts/
  format/v3/               bundle format spec + byte-level vectors  ← core asset
  ble/v1/                  BLE specs + golden/offload/device-info vectors
  engine/                  engine profile schema + vectors (if present)
  tools/                   blevectors, contractcheck, enginelang (Go, dev-only)
  CHANGELOG.md
ios/
  Sources/CairnCore/       BLE (GATT, Offload*), History, Models, Sync (subset), Auth (subset)
  Sources/CairnRuntime/    Store (GRDB, encryption), Auth (Keychain/Secure Enclave),
                           Views (trips), Sync (snapshot store), History
  Tests/CairnCoreTests/    relevant vector/unit tests
  project.yml              XcodeGen config (iOS 18.0)
  ble-protocol.md, decisions.md
```

## Deliberately left behind (do not re-fetch)

| Excluded | Why |
|---|---|
| firmware `lib/cairn_modem`, `cairn_uplink`, `cairn_digest`, `cairn_usage`, `cairn_ota` and their tests | LTE/Wi-Fi/server uplink paths — out of Bealach scope |
| contracts `sync/`, `store/`, `enrolment/`, `uplink/`, `share/`, `module/` | Server APIs; replaced by device↔phone trust and local mirror semantics |
| contracts `ble/v1/spec.md` companion GPS protocol & `checkin.md` | Phone-GPS assist and server-signed instructions |
| ios `Server/`, `Passkey/`, `CarPlay/`, `Location/`, `Sync/SyncEngine|Outbox*|BundleRelay*|SyncApplier|SyncState*`, `TripSyncClient`, `Session/`, `Auth/RequestSigner|SigningString|ConfigureLink|CanonicalJSON` | Server coupling, dashboard auth, CarPlay, phone-GPS |
| Cairn CI/runner, publish, cutover tooling | Infrastructure, not product |

Note: a few test files kept here (e.g. `EnrolmentServiceTests`, `PasskeyTests`)
reference the trimmed Auth/Passkey areas — they are included as behavioural
specs for the harvest, not as buildable targets. Drop or rewrite them when
porting.

## Harvest guidance

1. Work from the pinned commits above; if you need a file that was trimmed,
   fetch it from the source repo at that commit rather than `main`.
2. Rename on landing: `cairn_*` → `bealach_*` (firmware libs), `Cairn*` →
   `Bealach*` (iOS types), keep wire-format markers (`CRN3`, KDF context
   strings) until [open-questions.md](../docs/open-questions.md) Q7 decides.
3. Apply the trust-model deltas before wiring anything up: no server receipts,
   no uplink, owner-phone enrolment pins, SD retention by default
   ([../docs/contracts/](../docs/contracts/)).
4. Bring the vectors with the code (`contracts/format/v3/vectors`,
   `contracts/ble/v1/vectors`) and make them pass **before** feature work.
5. Never claim hardware validation from these files; they carry Cairn's
   history, not Bealach's evidence.
