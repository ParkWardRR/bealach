# Open questions (blocking or near-blocking)

Raised at plan time (2026-10-11) from the Cairn scan and external research.
Answers will be recorded here as decisions.

## Blocking for Phase 1

**Q1 — Owner-phone model.** Confirm v1 is **one owner phone per dongle**
(multiple pinned client keys reserved in the contract but unimplemented). Cairn
issue firmware#9 (multiple phones) shows the cost of deferring arbitration.
*Proposed: single owner phone in v1.*

**Q2 — Key escrow backup.** If the phone is the only `K_root` escrow and it is
lost/erased **and** the dongle is reset, SD originals are undecryptable. Options:
(a) explicit manual export of the escrow to a user-held file (redacted from
diagnostic export), (b) iCloud Keychain backup of the wrapped root, (c) neither —
document the loss. *This is a data-loss-semantics decision the owner must make.*
Cairn's answer (server keystore) does not exist here.

**Q3 — DTC reads.** The safety policy forbids clearing codes outright. Are
**read-only** diagnostic trouble-code reads (Mode 03) in scope for v1, or does
the allowlist stay to Mode 01/09 until Phase 2+? *Proposed: Mode 01/09 only in
v1; DTC read is a later, explicit decision.*

**Q4 — First engine profile.** Bealach needs at least one validated vehicle
profile to show OBD in milestone 1. The Cairn N20 profile is `derived` (not
freshly measured) and the B58 is a stub. *Proposal: Phase 1 records with
GNSS/IMU/voltage/health only; OBD enters at Phase 2 with at least one profile
validated against pidtest-style raw replies.*

## Non-blocking but open

**Q5 — GNSS module variance.** Freematics' own page is inconsistent (u-blox M9
vs M8030 10 Hz). Firmware will report observed capabilities; keep quality-field
semantics module-agnostic until confirmed per unit.

**Q6 — App distribution.** Personal sideloading vs App Store affects signing,
entitlements and the AccessorySetupKit migration story (`ASMigrationDisplayItem`
for existing pairings). Does not change architecture.

**Q7 — Format naming.** Carried format says `CRN3` / `cairn/…` KDF context
strings. Keep wire-compat markers for vector reuse and rename only the product
layer, or re-version the magic? *Proposed: keep `CRN3` frame wire format for
vector reuse in v1; rename is cosmetic and can wait — document the marker's
origin.*

**Q8 — Trip/leg semantics.** Cairn app#40 (per-boot vs per-outing trips) needs a
final rule for outing segmentation (dwell threshold, multi-leg parking). To be
fixed in the recording contract before Phase 1 UI freeze.

**Q9 — Buzzer / local UX.** Optional status feedback on the dongle (recording,
faults) — included or explicitly out?

**Q10 — iOS minimum version.** iOS 18 floor enables AccessorySetupKit cleanly.
Confirm no iOS 17 support requirement (would force a CoreBluetooth-only setup
path).
