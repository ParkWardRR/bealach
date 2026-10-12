# Decisions and design review

## Decisions

| # | Decision | Alternative rejected | Reason |
|---|---|---|---|
| 1 | Record both GNSS sources as separate `GNSS_SAMPLE` frames | Pick best fix per tick; phone-only when connected | Preserves evidence to compare receivers offline; recording stays source-neutral |
| 2 | Static passkey in gitignored `secrets.h`, enforced on every characteristic | Just Works | Blocks drive-by connections; no display on the dongle |
| 3 | Phase 1 has no live dashboard | OBD gauges, full telemetry | Scope: phone feeds GPS, nothing more |
| 4 | Separate repo for the iOS app | Monorepo `ios/` | Independent App Store / CI lifecycle. Cost: protocol drift, mitigated by shared spec and golden vectors |
| 5 | Typed GATT characteristics | Serial-style BLE UART | One message type per characteristic; no framing or reassembly on a small-stack target |
| 6 | NimBLE | Bluedroid | Smaller flash/RAM footprint |
| 7 | Locked-screen driving session in Phase 1 | Foreground-only MVP | A mounted phone is routinely locked or running Maps; foreground-only would not be a dependable driving companion |
| 8 | `DEGRADED_GNSS` = internal receiver health | Clear when any source has a fix | Otherwise the phone masks an internal hardware fault |
| 9 | Swift + SwiftUI + Observation + async/await | Combine, UIKit | Preferred stack; iOS 17 minimum |
| 10 | Session follows the BLE link (auto-connect, no Start button) | Explicit Start / Stop | The dongle powering on is the signal; nobody taps a phone while driving. Cost: needs Always location authorization and on-device validation of background wake. Supersedes the explicit-start part of #7 |
| 11 | P-256 / Secure Enclave for the app client key | Ed25519 | The Secure Enclave only holds P-256 keys; Ed25519 would require a software keychain, losing the hardware-bound non-exportability guarantee |
| 12 | Per-request signatures, not mTLS | mTLS with client certificates | `tailscale serve` terminates TLS on the server host; the app never sees raw TLS, so client certs cannot be presented. Per-request ECDSA signatures travel inside the HTTP body/headers and work over any transport |
| 13 | Vehicle-scoped data model (every bundle names a vehicle) | Single-vehicle / implicit | Two cars (2017 M240i B58, N20 428i) share one dongle pool; data must be attributable to a vehicle, not just a device |
| 14 | `.completeUntilFirstUserAuthentication` protection class | `.afterFirstUnlock` / no protection | Background writes (outbox, cache) need the store while the phone is locked; `.complete` blocks access after lock. `.completeUntilFirstUserAuthentication` is available after the first unlock per boot and survives lock |
| 15 | No data migration from v2 | Migration script | Local data is disposable (server is authoritative); a breaking change is cheaper than a migration path that must handle every intermediate schema |
| 16 | Probe-only LAN detection (no SSID matching) | `NEHotspotNetwork` SSID check | Avoids the `NEHotspotNetwork` entitlement (requires Apple approval) and the location-permission dependency it brings. A lightweight HTTP probe to the LAN endpoint is sufficient and works on any network |

## Design review: what changed

An external review of the first draft produced these changes, all folded into the docs.

| Priority | Gap | Resolution |
|---|---|---|
| Critical | No measurement timestamp in `GNSS_FIX` | Added `sample_age_ms`, `seq`, `validity_flags`; payload 20 → 28 B; firmware back-dates `monotonic_ms` |
| Critical | "No source selection" contradicted lifecycle behavior | Explicit operational policy; independent per-source state |
| Critical | Foreground-only undermines driving use | `CLBackgroundActivitySession` + background modes in Phase 1 |
| High | CLLocation validity underspecified | Negative accuracy/speed/course handling, staleness gates, clamped overflow, `fix_type` mapping |
| High | "Streaming" only proved attempted transmission | `COMPANION_STATUS` acceptance feedback |
| High | Static passkey treated as sufficient | Characteristic-level encryption + auth, bond limit, bond reset, unbonded-injection test |
| High | Dual-source storage compatibility assumed | Key / dedup / trajectory-query tests |
| Medium | Resource and power numbers asserted | Reframed as validation targets |

## Platform corrections applied

| Earlier claim | Now |
|---|---|
| iPhone "sub-meter accuracy" | "Potentially better positioning with reported accuracy"; unproven in this vehicle |
| Phone is a "GNSS antenna" | It supplies Core Location estimates, not raw observations |
| `fix_type = 3` because altitude present | Mapped from horizontal/vertical validity independently; Core Location has no 3D/DGPS flag |
| Satellite count / constellation on screen | Removed; not exposed by Core Location |
| "1 Hz" and "10 Hz" Core Location | Transmit cadence is separate from system-managed arrival cadence |
| `liveUpdates` + `kCLLocationAccuracyBestForNavigation` | Use `LiveConfiguration` (`.automotiveNavigation`) only |
| "CoreBluetooth auto-reconnects" | App-level reconnect plus state restoration; no blanket guarantee |
| GATT gives "type safety" | GATT gives boundaries; decoders still validate length, range, version, semantics |
| BLE SPP needs MFi | Classic SPP and BLE serial-over-GATT are different; framing is a design choice |
| "NTP-disciplined clock" | Phone wall clock, unless sync is implemented and validated |
| Placeholder `CAIRN001-…` UUID | Not valid hex; real 128-bit base assigned |

## Open questions

1. **NimBLE host stack depth.** GATT write callbacks run on NimBLE's host task. Measure whether the default depth holds under sustained traffic.
2. **Cadence filtering.** System-managed update rate vs the ~1 Hz transmit target; confirm drop/tolerate behavior on a drive.
3. **Advertising.** Advertise when disconnected, stop on connect (~1 mA on 12 V). Confirm reconnect latency.
4. **Frozen layouts.** `GNSS_QUALITY` and `COMPANION_STATUS` offsets are proposed, not frozen.
5. **UUID registration.** Final 16-bit suffixes and base assigned when the spec lands in the firmware repo.
