# Acceptance test matrix

Required coverage for release decisions. Each test names its evidence (log,
screenshot, vector run, meter reading). “Emulator” = CI/host; “HW” = physical
ONE+ Model B + iPhone. Phases refer to
[implementation-plan.md](implementation-plan.md).

## 1. Power and durability

| ID | Test | Expected | Phase |
|---|---|---|---|
| P1 | Power cut mid-segment write | Torn tail discarded and reported (byte count + reason) at next boot; prior frames valid; no uncontrolled bus traffic at reboot | 1 |
| P2 | Power cut during sealing | Bundle recoverable; sealing re-runs; segments never discarded | 1 |
| P3 | Power cut mid-reclaim | Reclaim journal shows intent; state consistent; no half-deleted “verified” | 3 |
| P4 | Rapid ignition cycles | `boot_id`/counter uniqueness holds; no cross-boot confusion; recordings per outing follow trip/leg model | 1–2 |
| P5 | Brownout / undervoltage | Health flags recorded; recording degrades explicitly; vehicle voltage series shows the event | 2 |

## 2. Corruption and integrity

| ID | Test | Expected | Phase |
|---|---|---|---|
| C1 | Bit-flip in a frame (repaired CRC) | `AUTH_FAILED` distinct from `CORRUPT_FRAME`; import refused; quarantine + user notice | 1 |
| C2 | Truncated/torn bundle on SD | Recovery scan outcome recorded; sealed data preserved | 1 |
| C3 | Tampered manifest signature | Import refused entirely | 1 |
| C4 | Chunk replay / wrong-chunk substitution | Digest mismatch; refetch; repeated failure flags `corrupt` | 1 |
| C5 | Moved frame (other segment/bundle/vehicle) | AAD mismatch → refused | 1 |
| C6 | Mutated vector suite (Cairn `mutate.sh` carried) | All mutations detected | 1 |

## 3. BLE pairing, bonds, reconnects

| ID | Test | Expected | Phase |
|---|---|---|---|
| B1 | Fresh pair via AccessorySetupKit flow | Enrolment pins established on both sides; fingerprints verifiable | 1 |
| B2 | Stale bond (phone restored / Bluetooth reset) | Recovery path works; no permanent lockout (Cairn #44 regression) | 1 |
| B3 | Ownership reset then re-enrol | Old pins rejected; new enrolment clean | 1 |
| B4 | Unauthorised phone attempts access | Refused; no metadata beyond advertising | 1 |
| B5 | Disconnect mid-READ / mid-ack | Resume at first unverified chunk; nothing partial marked verified | 1 |
| B6 | Reconnect → authenticated readiness | Within budget ([boot-budgets.md](boot-budgets.md)); session pins checked | 1 |
| B7 | App terminated mid-transfer | Persistent progress restored; resume works | 1 |
| B8 | Device reset mid-transfer | Recording intact; transfer resumes from verified progress | 1 |

## 4. Transfer, import, deletion

| ID | Test | Expected | Phase |
|---|---|---|---|
| T1 | Full trip mirror end-to-end | `verified`: identities + contents agree with the device snapshot | 1 |
| T2 | Interrupted import (crash) | Transactional: previous or new state, never half | 1 |
| T3 | Trip starts mid-transfer | `TRIP_ACTIVE`; retry after seal; capture not degraded | 1 |
| T4 | Delete iOS copy, SD remains | Tombstone; no auto re-download; explicit “fetch again” works | 3 |
| T5 | Reclaim SD (verified only) | iOS mirror survives; unverified never reclaimed; confirmations accurate | 3 |
| T6 | Clear mirror / clear SD / destructive reset | Confirmation language correct; active recording never erased; no silent propagation | 3 |
| T7 | Interrupted deletion | Resumable bookkeeping; `failed` ≠ `deleted` | 3 |
| T8 | Ack replay / forged ack | Rejected; no state change | 1–3 |
| T9 | Mirror acknowledgement naming wrong content | Rejected and surfaced | 1 |

## 5. Storage and reconciliation

| ID | Test | Expected | Phase |
|---|---|---|---|
| S1 | Missing SD at boot | Recording reports missing-card state; other functions continue; clear troubleshooting | 1 |
| S2 | SD full | Explicit degradation + loss reporting; bounded buffers; no silent loss | 2 |
| S3 | Growing recording during reconcile | `pending`, never `mismatched`; snapshot-scoped verdicts | 3 |
| S4 | Dongle unreachable | Stale indicator; last reconciliation shown as last, never as current | 3 |
| S5 | Corrupt local copy detected offline | `corrupt` without dongle (verify-local-mirror) | 3 |
| S6 | Intentional delete vs accidental missing | Tombstone distinguishes; anomalies reported | 3 |

## 6. Recording quality and vehicles

| ID | Test | Expected | Phase |
|---|---|---|---|
| R1 | Absent ECU (bench/emulator) | GNSS/IMU/voltage/health recorded; OBD marked unavailable; no request storm | 2 |
| R2 | Quiet ECU mid-drive (≈20 s gaps) | Gaps recorded explicitly; sensing continues (Cairn #37/#42 regression) | 2 |
| R3 | No GNSS fix | `GNSS_GAP`; no plotted position; UTC uncertainty honest (Cairn #38 regression) | 1–2 |
| R4 | Vehicle change / rental separation | New assignment; never merged silently; confidence + manual correction work | 2 |
| R5 | Ambiguous vehicle identity | Stays ambiguous until human resolves | 2 |

## 7. Boot, background, battery

| ID | Test | Expected | Phase |
|---|---|---|---|
| K1 | Boot cases §4 of boot-budgets (5+ runs each) | Budgets filled (proposed vs achieved); no security bypass to hit numbers | 1 |
| K2 | Reconnect/transfer throughput | ≥ proposed floor, measured and recorded | 1 |
| K3 | Background: app suspended during mirror | State restoration resumes; 10 s wake windows respected | 4 |
| K4 | Background: dongle advertising, app killed | Reconnect on approach via restoration/pending connection; no silent data loss | 4 |
| K5 | Parked 12 h with meter | Current within budget; standby journal pairs consistent with the meter | 2 |
| K6 | Driving battery (iPhone) | No continuous iPhone GPS/motion; measured consumption recorded | 4 |
| K7 | Transfer batching efficiency | Bounded scan/reconnect backoff; no thrash | 4 |

## 8. Privacy and export

| ID | Test | Expected | Phase |
|---|---|---|---|
| X1 | Diagnostic export default | No secrets; no precise location by default | 4 |
| X2 | Export redaction review | Manual review pass recorded | 4 |
| X3 | Settings: privacy toggles | Sampling/retention/transfer settings take effect and are honoured on-device | 4 |

## 9. Enrolment/identity (from threat model)

| ID | Test | Expected | Phase |
|---|---|---|---|
| E1 | Fingerprint verification UX | Out-of-band comparison possible and clear | 1 |
| E2 | Lost-phone scenario | Owner-reset path documented and works; key-backup policy honoured (Q2) | 3–4 |
| E3 | eFuse-sensitive operations | Refused by default; only with explicit approval + tested recovery plan | any |
