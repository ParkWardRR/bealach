# Vehicle safety and power policy

Two duties: **do not disturb the vehicle** (diagnostic safety, electrical load)
and **do not drain its battery while parked**. Both are policy *and* acceptance
criteria. Nothing here claims literal zero operational risk: a device that polls
a diagnostic bus transmits on it, and any device that draws current can drain a
battery. The goal is bounded, reviewed, measurable behaviour.

## 1. Passive reception vs diagnostic reads

| Activity | Transmits on vehicle bus? | Classification |
|---|---|---|
| GNSS reception | No | Passive |
| IMU (accelerometer/gyroscope) | No | Passive |
| Vehicle supply voltage (measured on the OBD connector supply) | No | Passive |
| Timing/recorder health, SD housekeeping | No | Local |
| **OBD-II Mode 01/09 standard PID requests** | **Yes — every poll is a request frame** | **Diagnostic read** |

Bealach treats diagnostic reads as a *constrained privilege*. The distinction is
stated in the UI and in every doc because “the dongle listens” and “the dongle
asks questions” are different risk profiles.

## 2. OBD policy (normative)

1. **Allowlist.** Only standard, read-only SAE J1979 / ISO 15031 Mode 01 (live
   data) and Mode 09 (vehicle metadata, e.g. VIN) requests defined in the
   engine profiles (`contracts` engine YAML) are ever sent. The allowlist is
   data, reviewable in the repository, compiled into firmware.
2. **Forbidden outright:** arbitrary CAN command tunnels; DTC reading as a
   default behaviour is allowed only if read-only and allowlisted **[decide in
   open questions]**; DTC *clearing*; coding/programming; actuator commands;
   security access / seed-key; freeze-frame dumps beyond the allowlist;
   manufacturer-specific probing; any write service (Mode 03/04/07/0A etc. are
   not sent except explicitly allowlisted read-only ones; Mode 04 is never).
3. **Bounded rates.** Poll cadence is declared per engine profile (e.g. 100–1000
   ms class), with a hard ceiling in firmware independent of profile settings.
   No configuration — from the phone or anywhere — can exceed the ceiling.
4. **Timeouts and retries.** Every request has a timeout; a non-response counts
   as `pid_error_count` and is *recorded*, never guessed. Retries are limited
   (e.g. 2) with **exponential backoff**; a quiet ECU produces silence, not a
   retry storm (Cairn firmware #42: DME quiet periods ≈ 23 s are normal).
5. **Fail-safe on any anomaly.** Parse errors, unexpected lengths, bus errors, or
   repeated timeouts put the OBD task into backoff and raise a degraded-health
   flag. **Failures must never create uncontrolled diagnostic traffic.**
6. **Failure isolation.** OBD trouble must not prevent GNSS/IMU/voltage/health
   recording. OBD runs on its own task with its own bounded time budget (Cairn
   firmware #37: blocking the sensing task on OBD cost 766 s of a 1002 s drive).
   Sensing and SD writing are higher priority than diagnostics.
7. **Per-vehicle honesty.** The engine profile records what was requested and
   what was answered (`pids_requested`/`pids_answered` bitmaps, cadence).
   “Unavailable” is data.

## 3. Vehicle identification

- Where the vehicle identifies itself (standard VIN via allowlisted Mode 09, or
  supported OBD headers), Bealach records the identification **with an explicit
  confidence level** and offers **manual correction** in the UI.
- Recognition **never** infers ownership. A recognised vehicle is a guess about
  hardware identity, not about who owns it.
- Ambiguous identities are never silently combined: two candidate matches stay
  two candidate matches until a human resolves them.
- **Persistent personal vehicles** and **temporary rentals** are distinct
  categories. Rental associations expire per policy and are kept separate in
  storage, summaries and export; data from different vehicles is never merged
  without an explicit human action.

## 4. Parked battery drain

- **Recording continues from the vehicle supply**, but the device sleeps between
  events. Policy (adapted from Cairn `cairn_power`, to be re-measured):
  - **Drive states:** engine-running detection via supply voltage + motion/OBD
    evidence; full sensing while driving.
  - **Standby:** light sleep with motion (and voltage) wake; GNSS/LTE/Wi-Fi
    powered down; periodic health/voltage sample on a slow cadence.
  - **Standby windows are recorded** as matched journal pairs so parked current
    is attributable per state (Cairn format v3 §4.7.1 design).
- Wake sources are bounded: motion, voltage threshold crossing, slow periodic
  health tick. BLE advertising in standby is duty-cycled and bounded.
- Budgets ([boot-budgets.md](boot-budgets.md) §5) are **proposed** until measured
  on hardware with a meter (Cairn firmware #10: parked current draw is unmeasured
  even there; the vendor ~10 mA figure is a vendor claim).
- Space reclamation, logging verbosity, and transfer batching must not change
  parked duty cycles without re-measurement.

## 5. What Bealach will not claim

- Zero risk of vehicle interference: a diagnostic request is still a request.
  The claim is **bounded, standard, read-only, rate-limited, fail-isolated**.
- Zero battery drain: the claim is **measured drain within a stated budget**,
  with wake/standby accounting recorded in every trip's journal.
- That all vehicles behave alike: profiles are per-engine, explicit about
  unknowns, and validated per vehicle.

## 6. Safety-related acceptance gates (summary)

Full matrix in [acceptance-tests.md](acceptance-tests.md). Gate items:

- Quiet ECU ⇒ sensing continues; OBD errors recorded; no request storm.
- Missing/failed SD ⇒ sensors keep sampling into bounded RAM buffer; loss is
  reported, never hidden.
- Power loss mid-write ⇒ torn tail handled at next boot; no uncontrolled bus
  traffic at reboot.
- Absent ECU (bench, emulator) ⇒ device still records GNSS/IMU/voltage/health.
- Vehicle change mid-lifecycle ⇒ new assignment, never merged silently.
