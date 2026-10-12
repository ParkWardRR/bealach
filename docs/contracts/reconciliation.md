# Reconciliation contract and the Storage & Mirror screen

What it means for the SD card and the iOS mirror to “match”, and what the UI
must show. Principle: **never show stale cached information as a current
successful reconciliation**, and scope every verdict to a snapshot.

## 1. Matching is authenticated identity, not bytes

A recording **matches** across SD and iOS if and only if, for the same snapshot:

1. The **content identities agree**: same `bundle_id`, same `content_root`,
   same manifest hash.
2. The **contents validate**: the iOS copy passes manifest signature, chunk
   digests, structural scan and frame AEAD authentication
   ([mirroring.md](mirroring.md) §4).

Equal byte counts, equal filenames, or equal timestamps are **never** evidence
of a match. A verified copy that disagrees with the device's manifest on any
identity field is `corrupt`/`mismatch`, not `matched`.

## 2. Snapshot scoping

- Every reconciliation is computed **against a specific listing snapshot**
  (the device's `LIST` state at a given moment, with its own sequence/time
  marker). Verdicts name their snapshot.
- A recording **actively growing** (capture in progress) is `pending`, never
  `mismatched`. Only sealed recordings are reconciled.
- If the dongle is unreachable, the last reconciliation is displayed **as the
  last reconciliation** with its timestamp and an explicit stale indicator. The
  Storage & Mirror screen must never render a cached result as “just verified”.

## 3. States

| State | Meaning |
|---|---|
| `pending` | Sealed on SD, not yet fully transferred (includes actively-growing capture) |
| `transferring` | Partially mirrored; verified-chunk progress shown |
| `verified` | Mirrored and validated; content identities agree in the current snapshot |
| `missing` | Known to exist on one side and absent from the other (e.g. on SD, never seen on iOS; or acknowledged on iOS but no longer listed on SD — see deletion bookkeeping) |
| `corrupt` | Present but validation failed (signature, digest, structure, AEAD) |
| `deleted-intentionally` | Removed under [deletion.md](deletion.md); tombstoned to prevent re-download |

## 4. Storage & Mirror screen (native iOS)

Required content:

- **SD card:** capacity, used/free, recording backlog (sealed-not-mirrored bytes
  and count), storage health (write errors, last error, card state).
- **iOS mirror:** mirror size, verified coverage (bytes/recordings verified vs
  known), and pending/transferring/verified/missing/corrupt counts.
- **Reconciliation:** last reconciliation time, the snapshot identity it was
  computed against, and whether the dongle is currently reachable. If stale, say
  so and why.
- **Discrepancy explanations:** every non-verified state links to a plain-language
  explanation (e.g. “this recording is still being recorded”, “transfer
  interrupted at 42%, resumable”, “verification failed at manifest signature —
  this copy will not be trusted”, “removed from iPhone on 3 Oct, kept on SD”).

Required actions (each wired to the contracts):

| Action | Behaviour |
|---|---|
| **Sync / reconcile now** | Fresh `LIST`, recompute states against the new snapshot, persist result with timestamp |
| **Verify local mirror** | Re-run full validation pipeline on iOS-held copies without the dongle; updates trust state only |
| **Delete selected iOS copies** | Preserves SD originals; tombstones so they are not re-downloaded automatically ([deletion.md](deletion.md)) |
| **Delete selected SD originals** | Preferentially offered only for `verified` recordings; heavy confirmation ([deletion.md](deletion.md)) |
| **Clear iOS mirror** | Bulk iOS delete, SD preserved, bulk tombstones |
| **Clear SD recordings** | Explicit destructive format/reset if supported; confirmation states what survives |
| **Destructive reset/format** | Separate, explicit, unsupported-on-some-cards fallback copy; never touches an active recording |

## 5. Confirmation language (normative)

Every destructive action must state, before confirmation:

- **Which copy survives** (usually: the other one).
- **Whether data becomes unrecoverable** (and after which action it is).
- That an **active recording is never erased**.
- That deletion is **not propagated silently** between stores.

## 6. Deletion vs missing (bookkeeping)

Reconciliation distinguishes **intentional deletion** (tombstone present, with
time and actor) from **accidental missing data** (no tombstone): the latter is
reported as an anomaly to investigate, the former is expected state. Resumable
deletion bookkeeping survives app/device restarts mid-deletion
([deletion.md](deletion.md) §5).
