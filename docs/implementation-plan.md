# Phased implementation plan

Each phase ends with the listed acceptance evidence. Security and fast boot are
acceptance criteria from phase 1, not later enhancements. **Nothing is claimed
as done until it is tested here**; this repository currently contains
documentation only.

## Phase 0 — Foundations (this repository)

- Contracts frozen as the four documents in `docs/contracts/`; carried Cairn
  test vectors imported and labelled with provenance.
- Dev tooling scaffold (vector/contract checkers) kept separate from product
  code. No desktop product, no web interface.
- **Accept:** docs reviewed; open questions either resolved or explicitly
  deferred with an owner.

## Phase 1 — First implementation milestone (the headline goal)

**Record a short trip to SD, securely mirror it to iOS, verify exact content
agreement, and display its route, summary, device status, and storage state.**

- Firmware: boot to first sample with boot-time instrumentation; capture GNSS +
  IMU summary/raw windows + voltage + health + journal to SD in the recording
  format; seal a bundle; recovery scan at boot; BLE mirror service with
  `LIST`/`GET_MANIFEST`/`READ` and owner enrolment pins; no OBD required yet
  (Phase 2 adds it) — or minimal allowlisted OBD if the engine profile is ready.
- iOS: enrolment/setup (AccessorySetupKit + bond), mirror client with persistent
  progress, verification pipeline (signature, digests, structure, AEAD),
  transactional import, trip list + trip detail map (MapKit), basic summary,
  Device screen (status, firmware, boot timings), Storage & Mirror screen with
  reconcile-now and the four states.
- **Accept:** one real vehicle trip recorded without a phone present; mirrored
  after the drive; iOS reports `verified` matching `bundle_id`/`content_root`/
  manifest hash; route and summary render; boot budget table filled for the
  cases in [boot-budgets.md](boot-budgets.md) §4; vectors pass on both sides;
  power-cut mid-write and mid-transfer cases in
  [acceptance-tests.md](acceptance-tests.md) exercised at least on the emulator.

## Phase 2 — Diagnostics, vehicle identity, safety hardening

- Allowlisted read-only OBD snapshots via engine profiles (request/answer
  bitmaps, cadence, error counts); failure isolation from sensing proven on
  hardware (quiet-ECU case).
- Vehicle identification with confidence + manual correction; persistent
  personal vehicles and temporary rental separation.
- Parked-standby policy with measured drain; standby journal pairs verified.
- **Accept:** safety gates in [vehicle-safety-and-power.md](vehicle-safety-and-power.md)
  §6 all pass on hardware; parked mA recorded; engine profile stamped in
  manifests.

## Phase 3 — Storage & Mirror completion and deletion flows

- Full reconciliation semantics (snapshot-scoped, stale indicators, discrepancy
  explanations); all destructive actions with the required confirmation
  language; resumable deletion bookkeeping; tombstones and re-download rules.
- Explicit configurable SD reclaim limited to verified mirrored data.
- **Accept:** deletion matrix in [acceptance-tests.md](acceptance-tests.md)
  passes; interrupted-deletion recovery demonstrated.

## Phase 4 — Polish, privacy, background behaviour

- Settings (sampling, retention, summary range, privacy, transfer behaviour);
  diagnostic export with redaction (no secrets, no precise location by
  default); summary date-range selection; cached map previews; incremental
  processing; battery behaviour under background BLE windows and state
  restoration.
- Stage-specific troubleshooting with actionable recovery (stale bonds, low
  storage, missing SD, absent ECU).
- **Accept:** background behaviour matrix pass; battery-consumption numbers
  recorded; export redaction reviewed.

## Phase 5 — Optional, gated

- Multi-phone enrolment; BLE OTA with signed images and a tested recovery plan
  (no eFuse changes without explicit approval + recovery plan); CarPlay or
  widgets **only if** they justify energy cost. Each is its own decision.

## Cross-cutting rules

- Reuse mature, tested components (per
  [migration-from-cairn.md](migration-from-cairn.md)) rather than inventing new
  cryptography. No new cipher suites; XChaCha20-Poly1305 / Ed25519 / SHA-256 /
  HKDF-SHA256 / CRC-32-IEEE as carried.
- Migrated code lands with its provenance note and passing carried vectors.
- Dev tooling never becomes product scope.
