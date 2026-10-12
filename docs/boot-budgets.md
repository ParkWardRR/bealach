# Boot and performance budgets — measurement procedure

**Rule of this document: proposed targets and achieved results are labelled
separately.** Nothing on this page is an achieved Bealach result yet. Cairn's
instrumentation and first numbers are cited only as context, from the pinned
repositories, not claimed by Bealach.

## 1. What is measured (normative stages)

Instrumented as a monotonic boot record (adapt Cairn `cairn_boottime` verbatim):
T0 = first line of `setup()`; `pre_app_us` = ROM+bootloader time. Stages:

| Stage | Meaning | Budget family |
|---|---|---|
| `app_start` → `first_sample` | **Reset to first sensor sample** (T_capture) | Recording latency |
| `first_sample` → first **durable SD write** | Recording acceptance | Durability latency |
| `app_start` → `ble_advertising` | **Reset to BLE advertising** (T_ble) | Discoverability |
| (re)connect → **authenticated readiness** | Bond+enrolment verified, mirror ops permitted | Session latency |
| transfer start → verified payload throughput | Chunk mirror rate + verification cost | Transfer throughput |
| reset → `store_ready` | Interrupted seals/prunes recovered | Deferred recovery (not on the critical path) |

Additional marks kept (from the carried implementation): `log_ready`,
`sd_mounted`, `sensors_ready`, `obd_first_answer`, `gnss_first_fix`,
`first_chunk`, reset cause. The record is printed on the console **and** written
to the SD log and exposed in device-info over BLE.

## 2. Proposed targets (NOT achieved results)

Set from engineering judgement pending hardware measurement (milestone 1):

| Metric | Proposed target | Basis |
|---|---|---|
| Reset → first sensor sample | **≤ 3 s** (power-on, warm boot) | Must not wait for GNSS/ECU/calibration/BLE; SD-mount-deferred capture into RAM pre-roll if needed |
| Reset → durable SD write | **≤ 5 s** with card present | Card mount is the big variable |
| Reset → BLE advertising | **≤ 4 s** | Recording and advertising are parallel; neither blocks the other |
| Reconnect → authenticated readiness | **≤ 2 s** from link-up | Bond reused; enrolment pins checked, not renegotiated |
| Verified mirror throughput | **≥ 10 KB/s sustained**, measure ≥ 25 KB/s | Cairn offload doc expectation 10–25 KB/s at MTU 247 / 15–30 ms **[A3]** |
| Parked current (standby) | **≤ 25 mA average** over a 12 h park | Vendor ~10 mA low-power claim + margin **[A4, unmeasured]** |
| OBD poll overhead | ≤ 20 % of sensing task budget | Failure-isolation requirement |

Benchmarks must **never** be improved by bypassing security checks. Enrolment
verification, AEAD authentication and manifest checks stay on their paths; if a
budget conflicts, the budget moves.

## 3. Cairn context (cited, not claimed)

- Cairn's first bench pass: cold start from power-on reduced **55 s → 8.9 s**
  (production image, one unit, with SD). The remaining terms were listed but not
  budgeted (Cairn `docs/boot-timing.md` @ `ead3532`). One run on one unit is not
  a budget — Bealach will not copy 8.9 s as a target without its own runs.
- Cairn's biggest fix was structural (keeping Wi-Fi/LTE off the boot path);
  Bealach never has those stacks at all.

## 4. Measurement procedure

1. **Build:** production image (no debug logging on the hot path), instrumented
   boot record enabled, self-test image available for A/B.
2. **Cases, each ≥ 5 runs,** both power-on ignition and wake-from-sleep: with SD
   (small and large cards), without SD, with ECU answering and with ECU absent
   (bench/emulator), first boot after flash and steady state.
3. **Capture:** serial console `BOOTTIME` lines + SD log; record reset cause.
4. **Transfer runs:** one real trip bundle (≈ 1 MB class), measure wall time to
   verified import on iOS; record MTU, connection interval, chunk size,
   retransmits.
5. **Parked drain:** meter in series with the supply (Cairn firmware #10 shows
   terminal estimates are insufficient), 12 h park, voltage series + standby
   journal pairs cross-checked.
6. **Regression gate:** `boottime_check` against committed budgets in CI (host);
   hardware numbers recorded in this document's results table when measured.

## 5. Results table (to be filled; currently empty)

| Date | Image | Case | T_capture | T_sd_write | T_ble | Auth-ready | Throughput | Parked mA |
|---|---|---|---|---|---|---|---|---|
| — | — | — | **not yet measured** | — | — | — | — | — |

## 6. Buffering and loss limits (declared policy)

- If SD mount is delayed, capture fills a **bounded RAM pre-roll/capture buffer**
  (size fixed per milestone; target ≥ 30 s of mixed GNSS/IMU/health at driving
  rates). Overflow policy: drop-oldest health samples first, **record a loss
  record** with counts and interval; never drop silently.
- Recording never waits for: GNSS lock, ECU identification, stationary
  calibration, BLE pairing, or an unbounded full-card scan (recovery scans are
  incremental and deferred behind first capture).
- Fast startup vs deferred recovery: seal-recovery, prune-recovery, and
  reconciliation scans happen after `first_sample` and after `ble_advertising`,
  never before.
