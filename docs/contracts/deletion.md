# Deletion, retention and reset contract

Default: **SD originals are retained.** Transfer never deletes. Deletion is an
explicit, informed, separately-confirmed human action on each store.

## 1. Retention rules (normative)

1. **No automatic deletion of SD originals because they were transferred.**
   Mirroring to iOS is not a reason to lose the source of truth.
2. Optional **space reclamation** on the dongle is:
   - **explicit** — a named setting/action the owner turns on,
   - **configurable** — e.g. “keep the most recent N days/GiB on SD”, or
     “reclaim verified recordings older than X”,
   - **limited to verified mirrored data** — a recording is eligible only when a
     signed owner-phone acknowledgement naming its exact content is stored and
     the phone-side copy is verified (tombstone-safe), **and**
   - **user-visible** — every reclaimed recording is listed in history before
     and after the fact.
3. iOS copies may be deleted freely **without** affecting SD.
4. Deleting an **active recording is forbidden**; the action is refused while
   capture is in progress.

## 2. The two stores' delete actions

| Action | Effect | Confirmation must state |
|---|---|---|
| Delete iOS copy(ies) | iOS data removed + tombstone | SD original survives; the iPhone copy becomes unrecoverable; it will not re-download automatically (tombstone); if you later want it again, it must be re-fetched deliberately from SD |
| Delete SD original(ies) | SD data removed (eligible-for-reclaim rule above applies when done in bulk-reclaim mode) | The verified iOS mirror survives; the SD original becomes unrecoverable; this cannot be undone even if the iPhone copy is later deleted |
| Clear iOS mirror | All iOS copies + tombstones | All SD originals survive |
| Clear SD recordings | All eligible SD data | Verified iOS mirrors survive; anything `pending`/`transferring`/`corrupt` on iOS **and** on SD becomes unrecoverable — the confirmation names the count and bytes at risk |
| Destructive reset/format | Device-side format of the card (if supported) + recording-state reset | Everything not yet verified-mirrored is unrecoverable; never runs while recording; requires the most explicit confirmation in the product |

Never **silently propagate** deletion between stores: deleting on iOS does not
delete on SD and vice versa, except the explicitly-configured reclaim policy,
which is itself surfaced.

## 3. Mirror acknowledgement vs delete authority

The mirror acknowledgement ([mirroring.md](mirroring.md) §5) is evidence that
the owner phone verified exact content. It:

- **does not** delete anything by itself;
- **does** make the named recording *eligible* for the reclaim policy;
- is useless without the enrolment pins (a non-owner's ack is rejected).

This is the deliberate replacement for Cairn's server-signed receipt-as-delete-
authority: in Bealach the delete authority is the **human owner**, constrained
by verified evidence, not an automatic gate.

## 4. Re-download semantics (the subtle case)

If deleted iOS data still exists on SD and is still listed by the device:

- The **tombstone** (recording id + content root + deletion time + actor) is
  authoritative for the mirror: automatic sync **must not** re-download it.
- The Storage & Mirror screen may show it as `deleted-intentionally` with an
  explicit “fetch again” affordance, which is a deliberate user action that
  clears the tombstone for that recording and treats it as `pending`.
- Reconciliation reports these as intentional, not as `missing` anomalies.

## 5. Resumable deletion bookkeeping

- Deletions are recorded as durable intents (`to-delete` → `deleting` →
  `deleted`/`failed`) in the store that owns the data, so an app crash or device
  reset mid-deletion leaves a consistent, explainable state.
- Partial deletes (e.g. iOS pruned some files of a recording) are never shown
  as complete; the recording stays `deleting` until verified gone or restored.
- `failed` deletions (file busy, device unreachable for SD ops) are retryable
  and reported; they never silently resolve into `deleted`.
- Device-side reclaim journal entries are written before and after each removal,
  so a power cut mid-reclaim is recoverable and auditable.

## 6. Ownership reset and full teardown

- **Ownership reset** (device → new owner / sale): clears enrolment pins and
  bonds. Recording deletion is a *separate* explicit choice on that path.
- **Factory destructive reset**: format/reset support is hardware-dependent
  (some cards/hosts); if unsupported, the UI says so and offers the closest
  supported action rather than pretending.

## 7. Acceptance hooks

Interrupted transfer/import/**deletion**, deleted-iOS-still-on-SD re-download
rules, and “never erase active recording” are all in
[acceptance-tests.md](acceptance-tests.md).
