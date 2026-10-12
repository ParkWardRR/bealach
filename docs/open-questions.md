# Open questions

Raised at plan time (2026-10-11) from the Cairn scan and external research.
Decisions recorded 2026-10-12.

## Blocking for Phase 1 — resolved

**Q1 — Owner-phone model.**
*Decision (2026-10-12):* **Single owner phone per dongle in v1.** Multiple
pinned client keys are reserved in the contract but unimplemented. Revisit in
Phase 5 after single-owner model has real usage experience.

**Q2 — Key escrow backup.**
*Decision (2026-10-12):* **iCloud Keychain backup.** The wrapped `K_root` is
stored in iCloud Keychain, leveraging Apple's infrastructure for backup and
cross-device availability. This is the user's data-loss safety net: if both the
phone and dongle are lost/reset without iCloud backup, SD originals are
undecryptable.

**Q3 — DTC reads.**
*Decision (2026-10-12):* **Mode 01/09 only in v1.** Read-only DTC reads
(Mode 03) are deferred to Phase 2+. The safety allowlist stays limited to
current data and VIN.

**Q4 — First engine profile.**
*Decision (2026-10-12):* **Phase 1 records GNSS/IMU/voltage/health only;
OBD enters at Phase 2** with at least one profile validated against
pidtest-style raw replies. The Cairn N20 profile is `derived` (not freshly
measured) and is not trusted for Phase 1.

## Non-blocking — resolved

**Q5 — GNSS module variance.**
*Decision (2026-10-12):* Firmware reports observed capabilities. Quality-field
semantics remain module-agnostic. Per-unit GNSS module variance (u-blox M9 vs
M8030) is handled by reporting what the firmware sees, not assuming a specific
module.

**Q6 — App distribution.**
*Decision (2026-10-12):* Deferred — does not change architecture. Personal
sideloading vs App Store affects signing and entitlements but not the design.
Will be decided when Phase 4 polish is underway.

**Q7 — Format naming.**
*Decision (2026-10-12):* **Keep `CRN3` wire-format markers for vector reuse in
v1.** The product layer uses Bealach naming; the wire format retains `CRN3`
magic and `cairn/…` KDF context strings so existing test vectors pass
unchanged. Rename is cosmetic and can wait.

**Q8 — Trip/leg semantics.**
*Decision (2026-10-12):* **Dwell-time threshold segmentation.** A stationary
dwell > 5 minutes ends the current leg; a gap > 30 minutes ends the trip.
Per-boot is not per-trip — consecutive boots with gaps < 30 min are merged.
Manual split/merge on the phone. Details recorded in
[contracts/recording.md](contracts/recording.md) §3.1.

**Q9 — Buzzer / local UX.**
*Decision (2026-10-12):* **Explicitly out of scope** for v1. No buzzer
feedback. GPIO25 remains available but unused.

**Q10 — iOS minimum version.**
*Decision (2026-10-12):* **iOS 18 floor confirmed.** No iOS 17 support.
AccessorySetupKit requires iOS 18.0+, which is the clean path for
discovery/pairing.
