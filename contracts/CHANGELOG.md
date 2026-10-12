# Changelog

Contract releases are tagged `contracts-vX.Y.Z` and cut by a maintainer; no CI job tags or
publishes. Protocol directories are versioned independently of the collection tag.

## Unreleased

Nothing yet.

## 0.7.0 (2026-10-10)

**A trip is an outing, not a power cycle.** One behavioural change to `sync/v1` and one
additive change to `store/v1`, both from
[485ae9a](https://github.com/ParkWardRR/cairn-driving-log-selfhosted/commit/485ae9a). The
contract had been ahead of its newest tag since 2026-10-09, so every consumer was pinning a
contract older than the server answering it; this tag closes that.

### `sync/v1` — **breaking, and `sync/v1` is still draft**

A `trip_summary` entity's id changes from `<vehicle_id>:<boot_id>` to
`<vehicle_id>:<started_ms>`, and two fields are added: `driving_ms` and `leg_count`.

A boot is an artifact of when the car cut power to the dongle, not a fact about the driving,
and keying on it failed in both directions at once: a shop stop that switches the ignition off
started a new boot, so one errand published as several trips; and two drives inside one boot
published as a single trip whose span covered the stop between them. Measured on a real errand
— home, Trader Joe's, Pavillions, home — that produced two entities, one of which claimed
seven hours.

So a trip is an **outing**: consecutive drives merged across any stop shorter than the
producer's threshold (20 minutes in the reference implementation). `duration_ms` is the
wall-clock span including those stops, `driving_ms` counts only the moving parts, `leg_count`
says how many drives the outing contains, and `boot_id` is still published — it is the boot the
trip started in — but it is no longer the identity.

**Two things a consumer must now handle**, both consequences of a trip being derived rather
than declared:

- **An entity can be re-keyed.** A bundle covering an earlier part of the same outing arriving
  late moves the trip's start earlier, and it is republished under a new id. The old id is
  stale rather than contradicted, so a consumer keeping both shows one trip twice. Reconciling
  by `(vehicle_id, overlapping span)` rather than by id alone is the safe read.
- **A trip can absorb a later one.** If the gap between two published trips turns out to be
  shorter than the threshold once the data falling in it arrives, they become one trip under
  the earlier id.

> **The vectors do not cover `trip_summary`.** `sync/v1/vectors/exchanges.json` exercises the
> exchange mechanics — push, pull, ack, request signing — and contains no `trip_summary`
> payload, so **a consumer that only replays the vectors will not notice this change**. Read
> the spec section, not the vectors, when adopting this tag. Nothing in the vectors
> contradicts the new spec, which is what makes the tag consumable.
>
> This note first named the iOS app as such a consumer. It is not one — it reads trips from a
> store snapshot and never decodes a `trip_summary` entity — so today **no shipped consumer
> reads this entity at all**, and the server is its only implementation. That is worth knowing
> before trusting the re-keying: `sync/v1` cannot leave draft until something independent
> consumes it, and adding `trip_summary` vectors is what would make the next consumer's
> mistake visible.

### `store/v1` — additive, `store/v1.3` → **`store/v1.4`**

Adds the `v_trip_leg` view: one row per leg of a trip, carrying `vehicle_id`, `started_at`,
`closed_at` and `boot_id`, so the boots that make up an outing stay reachable now that
`v_trip_summary` is keyed on the trip. No relation was removed and no column changed type, so a
consumer pinning `contracts-v0.6.0` was still *satisfied* by the running store — it simply
could not see the new view.

Verified on 2026-10-10: `go run ./cmd/dump-schema` in `cairn-vehicle-server`, against the live
code path, produced a file **byte-identical** to the `schema.json` committed here. The contract
and its implementation agree.

### Adopting it

| Consumer | What this tag changes for it |
|---|---|
| server | Already implements both halves (`internal/tsdb.StoreContract = "store/v1.4"`, trip-keyed `trip_summary`). The pin bump records what is already true |
| dashboard | Its `storeContract` test can now see `v_trip_leg`; its own `bootId → tripId` rename is the matching work and is not yet landed |
| iOS | **Nothing.** Corrected 2026-10-10: this row first said to read the `sync/v1` note, on the assumption that the app consumes `trip_summary`. It does not — its trips come from a store snapshot and the only relations it queries are `drive_summary`, `position` and `boost`. It pins v0.7.0. The app showing per-boot drives rather than outings is a product gap, [iOS #40](https://github.com/ParkWardRR/cairn-ios-companion-app/issues/40), not a conformance one |
| firmware | Nothing. It pins `format/v3` and `ble/v1`, neither of which moved |
| modules | Nothing. `module/v1` is byte-identical to v0.6.0 |

## 0.6.0 (2026-10-09)

**A repair release.** It adds no protocol directory and changes no released byte layout, so
every consumer pinning 0.5.0 is still satisfied by this tag and may bump at its own pace.
What it does is make `module/v1` consumable and bring `store/v1`'s machine-readable schema
back level with the store that serves it.

> **`contracts-v0.5.0` could not be consumed by anything that checks the capture-field
> vocabulary, and this release is the fix.** `engine/v1` gained `pedal_pct` in
> [631dad2](https://github.com/ParkWardRR/cairn-driving-log-selfhosted/commit/631dad2),
> which 0.5.0 carries; `module/v1`'s `$defs/engine_field` only gained it in
> [df8a997](https://github.com/ParkWardRR/cairn-driving-log-selfhosted/commit/df8a997),
> which it does not. So `modgen validate` refused the 0.5.0 tree — correctly — and
> `cairn-modules` could not move off `contracts-v0.4.0` at all. The guard working is the
> good news; the tag being unconsumable is why this release exists.

**`module/v1` is still draft**, and the two normative changes below are behavioural: a
consumer that computes module identity must be updated together with its pin. `modgen` in
`cairn-modules` and the server's `internal/modules` both already implement them, so both
have been ahead of every tag until now.

- **`store/v1/schema.json` is regenerated at `store/v1.3`**, which the server has been
  serving since `86e2381` while this file still said `store/v1.2` — the contract was
  behind its own implementation. Purely additive, as a minor must be: the `time_obs`
  table and the `boost.pedal_pct` column. Generated, not written: `go run
  ./cmd/dump-schema` in the server starts the real store and dumps the schema it built
  for itself.
- `store/v1/README.md`: documents both additions. `time_obs` has **no `observed_at`**,
  deliberately — a row whose job is to establish the time cannot be stamped with the time
  it is establishing — and for the same reason it is keyed on the carrying frame rather
  than on `vehicle_id` like every other object. `boost.pedal_pct` is PID 0x49 and is a
  **different signal** from `obd.throttle_pct`, the throttle plate angle, which does not
  reach 100% at wide-open throttle on a drive-by-wire engine.

- `module/v1/spec.md` §4: separates an **introduced** derived column from a **grandfathered** one. The old
  text said a derived column is all-null when its owning module is absent, which is right for a column a
  module adds and wrong for `boost.boost_psi` and `boost.lambda_ratio`: the core computed those before any
  module existed, so nulling them when an operator runs without a module set would break every deployment
  and every query that reads them. The core's definition now explicitly stands until a module takes over.
  Found while writing the loader that applies derivations — the two sentences could not both be obeyed.
  Also states that "the values must not change" means *evaluated* against the reference over every input the
  record can hold, not read and judged equivalent, and cites the defect in this contract's own vector as the
  reason.

- **`module/v1/vectors/valid-boost.json`: the `boost.boost_psi` expression was wrong, and would have silently
  changed the column.** It read `map_kpa < 255 AND baro_kpa > 0`, but the server's reference
  `OBDExtended.BoostPSI()` returns a value whenever **both** readings are present: it does not exclude a
  saturated manifold reading, and does not treat a barometric reading of 0 as absent. Saturation is excluded
  by the views that read the column (`v_boost_curve`, `v_pulls`), not by the column itself — so the vector
  would have turned every saturated sample's boost into `NULL`.
  Found by building §4's own gate rather than by review: the server's new
  `TestBoostPSIDerivationReproducesTheReference` evaluates the expression in DuckDB against the Go reference
  over 2,056 `(map, baro)` combinations, and `TestTheRejectedExpressionReallyDiffers` pins the defect so it
  cannot come back believed equivalent. `lambda_ratio` was checked the same way over all 65,536 values and
  was already right.

- **`module/v1/spec.md` §7: a module's hash now covers its manifest and every file the manifest names, not
  its whole directory.** The old rule made a `README.md` edit change the module's digest, the module-set
  identity and therefore the store contract digest — so a prose fix would make a rebuilt store look like a
  different store. That is a false mismatch, and invariant 5 is worth less every time it cries wolf. The new
  rule covers what can change a module's output and nothing else; it needs no "except documentation"
  carve-out and extends by itself to any later key whose value is a path.
  **Normative and behavioural**, so a consumer computing identity must be updated together with its pin.
  Both consumers that compute identity are: `modgen` in `cairn-modules`, and the server's
  `internal/modules`. Each had been ahead of every tag on this point until this release.

- `module/v1/module.schema.json`: adds `pedal_pct` to `$defs/engine_field`, so the capture-field vocabulary
  matches `engine/v1`'s `$defs/field` again after
  [631dad2](https://github.com/ParkWardRR/cairn-driving-log-selfhosted/commit/631dad2) added it there.
  Additive, and `module/v1` is draft. **Caught by machine, not by review:** `tools/modulecheck`'s
  `CheckVocabulary` compares the two enums and failed CI, which is the first real exercise of the guard
  `engine/v1` was created to need — the two files had drifted by exactly one field.
- `module/v1/README.md`: records a defect in §7 (a module's hash covers its `README.md`, so a prose edit
  changes the module-set identity) and marks the two release-gate items `cairn-modules` and the second
  implementation as met.

## 0.5.0 (2026-10-08)

Cut without an entry at the time; written up here from the tag. **Additive to `format/v3`**, whose
byte layouts are stable, so it adds fields and a record type and changes nothing existing.

- **`format/v3` manifest key 29, `engine_profile`**: `[id, version, sha256]`, optional and
  independent of key 23, so a manifest has **27 to 29** fields. The digest and not just the name,
  because a profile edited without a version bump is a different profile and only the digest says
  so. A reader must not require the key. Readers should prefer it over parsing the profile out of
  `firmware_version`, where devices had been carrying it as a suffix with 31 of 32 bytes used.
- **`format/v3` record type `0x0B`, `TIME_OBSERVATION`**: one wall-clock reading from one source,
  recorded as evidence rather than as a decision. The monotonic half is the **frame's**
  `monotonic_ms`, not a payload field, and that pairing is the point — `utc_ms` minus it is the UTC
  of monotonic zero that source implies, so sources are directly comparable and drift within one
  source is visible across a trip. An unknown source number is kept and rendered, never rejected.
- **`format/v3` `OBD_EXTENDED` gains `pedal_pct`** (PID 0x49), and `engine/v1`'s `$defs/field`
  gains it as a capture field.

> **This release is internally inconsistent and 0.6.0 is the fix.** `pedal_pct` went into
> `engine/v1` here and not into `module/v1`'s `$defs/engine_field`, so the vocabulary guard
> refuses this tree and `cairn-modules` cannot pin this tag. Consumers that do not check the two
> enums against each other — the firmware, the server, the app, the dashboard — are unaffected and
> several pin it today.

## 0.4.0 (2026-10-08)

**Two new protocol directories, both draft: `engine/v1` and `module/v1`.** Nothing existing is renamed,
renumbered or retyped and no vector changed, so every consumer pinning 0.3.0 is still satisfied by this tag
and may bump at its own pace. `ble/v1`'s `DEVICE_INFO` leaves draft here rather than in the separate
`0.3.1` its entry below suggested.

Both new contracts keep their in-document identifiers (`cairn.engine/v1-draft`, `cairn.engine-analysis/v0`,
`cairn.module/v1-draft`), so **no producer or consumer has to change to adopt this tag**. Promoting a
directory makes a contract findable and citable; promoting an identifier says the bytes are settled, and
only the first is true of either. Each carries its own release gate, in its README.

- **`module/v1` is new, as a draft.** Modules: interpretation separated from the GPS-logging core, where one
  module is a package carrying its dongle, server, web and app parts together. It is the delivery mechanism
  for an acceptance test the project has carried since the rebuild and never met -- "a new vehicle, a new
  place kind or a new metric can be added by configuration or a documented extension point, not by editing
  core code". Design: [docs/module-system-plan.md](../docs/module-system-plan.md).
  - **`module.schema.json`** (the manifest: identity, `requires`, `derives`, `metrics`, `views`, `queries`,
    `ui`, `ios`) and **`queries.schema.json`** (named, parameterised queries). 39 vectors: 4 valid manifests
    including the manifest-only case, 23 invalid, 1 valid query file, 11 invalid, plus one YAML-only
    duplicate-key case.
  - **It is not the plugin system retired on 2026-10-05.** A module ships declarations, never executable
    code; it cannot see a bundle byte, hold a key, influence a receipt or a prune, add a listener, or write
    to the store. That is structural -- `additionalProperties: false` throughout means no such request can
    be spelled. Derived values are SQL expressions evaluated by DuckDB, so no new interpreter is added on
    any host.
  - **`tools/modulecheck`** is the first implementation. Two of its checks need the whole contracts tree and
    so can only live here: `requires.store` is resolved against `store/v1`'s `schema.json`, and the
    capture-field enum is compared with `engine/v1`'s. The second matters most -- `engine/v1` exists because
    two copies of one vocabulary drifted, and this is the guard against repeating it with three.
  - **Nothing implements it yet**, so it cannot leave draft. Five items remain, listed in its README; the
    one that must not slip is folding module-set identity into the store digest and `v_reproducibility`,
    because a derived store whose contents depend on an unrecorded module set cannot prove it reproduces.
  - **Released in this tag** as a draft directory. It constrains nothing yet, because nothing implements it.
- **`engine/v1` is new, as a draft.** It ends a split: engine profiles were two files in two
  repositories under two schema identifiers, and the server's own `internal/engine` doc comment said
  they "share an engine id (`bmw-n20`) and nothing else". The acquisition half (`cairn.engine/v1-draft`,
  how to read an ECU) came from the firmware's `engines/engine.schema.draft.json` and
  `engines/SPEC.draft.md`; the analysis half (`cairn.engine-analysis/v0`, what a reading means) was an
  undocumented Go struct and now has a schema. Closes the substance of
  [#20](https://github.com/ParkWardRR/cairn-driving-log-selfhosted/issues/20).
  - **The in-document identifiers are unchanged** — a profile still says `schema: cairn.engine/v1-draft` —
    so no producer or consumer has to change for this to land. Promoting the directory makes the contract
    citable; promoting the identifiers says the bytes are settled, and only the first is true yet.
  - **Vectors:** `vectors/expr.txt` (105 formula-language vectors: 50 evaluate, 23 reject, 32 raw
    bytecode), `vectors/invalid/` (20 acquisition profiles that must be rejected) and
    `vectors/analysis/` (19 analysis profiles, 4 valid and 15 invalid — new, and checked against the
    server's reader while they were written).
  - **A third implementation now exists.** `tools/enginelang` implements the formula language, compiler
    and bytecode evaluator in Go, written from the spec rather than ported from the Rust, and run by
    `tools/cmd/engine-check` in the Contracts workflow. It passed all 105 vectors on its first complete
    run, so the Rust generator and the C evaluator do match the normative text. This was the release gate
    named in the draft spec; the items remaining before `engine/v1` leaves draft are listed in its README.
  - **Released in this tag** as a draft directory: a minor, since it adds a protocol and touches no
    existing one.
- `uplink/v1/spec.md` §8: fixes the relative link to `docs/lte-cellular-design.md`, which pointed one
  directory too high and so resolved nowhere. **Would have released nothing on its own** — no normative
  text, byte layout or vector is touched; it is listed here only because the file sits under `contracts/`.
- `ble/v1/device-info.md`: `DEVICE_INFO` (characteristic `0040`) is **out of draft**. Three independent
  implementations now agree on `vectors/device-info/vectors.json`: the Go reference (`tools/blevectors`),
  a Python-on-OpenSSL cross-check, the firmware's C
  ([ParkWardRR/cairn-esp32-device-firmware#14](https://github.com/ParkWardRR/cairn-esp32-device-firmware/issues/14),
  72/72 host rows), and the app's Swift
  ([ParkWardRR/cairn-ios-companion-app#27](https://github.com/ParkWardRR/cairn-ios-companion-app/issues/27),
  7/7 vector rows). The `UPLINK_EVENT`, `INSTRUCTION`, `INSTRUCTION_RESULT` and `HOME_TRIGGER`
  characteristics in the same file stay **draft** until they also have cross-implementation agreement.
  **Released in this tag** instead of the suggested `contracts-v0.3.1`: a status change with no vector or
  byte changed, folded into the minor rather than tagged separately.

## 0.3.0 (2026-10-06)

The store schema moves from `store/v1.0` to `store/v1.2` (additive; a server pinning 0.2.0's `store/v1.0` file is
still satisfied), and `ble/v1` documents the `ENGINE_DECLARATION` characteristic. The `sync/v1` and `store/v1`
documentation changes below ship in this tag too. No vector changed.

- `ble/v1/spec.md` (draft, additive): documents `ENGINE_DECLARATION` (suffix `0004`, phone to device, write without
  response, 1-31 byte UTF-8 engine profile id such as `bmw-n20`), the companion app's declaration in the firmware's
  engine-discovery chain; and notes that the firmware's 2026-10-06 dev build drops `AUTHEN` while the spec still
  describes the shipping target.
- `sync/v1/spec.md`: adds `429 too_many_offers` to the relay's Errors list: a retryable refusal when a client has the
  server's limit of offered-but-uncommitted bundles (per client, re-offers and receipted bundles never count; the
  limit's value is not part of the contract). Additive on an existing endpoint, so `sync/v1` stays compatible; a
  documentation change to the spec, no vector changed.
- `store/v1.2` (additive). `schema.json` moves from `store/v1.0` to `store/v1.2`;
  `store/v1.1` was never released on its own, so this release carries both minors.
  - `store/v1.1`: the `bundles` columns `path`, `size_bytes`, `duration_ms` and `received_at`; the `tune` table; the
    views `v_boot_start`, `v_metric_samples`, `v_tune_effect` and `v_health_stats`.
  - `store/v1.2`: the period views. `v_trip_period` (one row per trip with its week, month, quarter and year start) and
    the table macro `period_summary(from_day, to_day)` (per-vehicle trips, duration, distance and maximum speeds over a
    half-open date range). A trip belongs to the UTC period it started in. `schema.json` gains an optional `macros`
    object, which the server's compatible-range check reads (a pinned macro must exist with the same parameters and
    columns); a `store/v1.0` file is still satisfied. Nothing existing changed. See `store/v1/README.md`. Refs
    ParkWardRR/cairn-vehicle-server#14.
- `store/v1/README.md`: documents the `GET /healthz` JSON (`status`, `build`, `store_contract`), the
  `GET /capabilities` response (tables, views, columns, endpoints) and the minor-version rule (a minor
  increments on any additive change; removing, renaming or repurposing is `store/v2`), taken from the
  server implementation. Documentation only; `schema.json` and every vector are unchanged.
- `format/v3/spec.md`: a link to the firmware hardening notes now points at the firmware
  repository. Documentation only; no protocol or vector changed.

## 0.2.0 (2026-10-05)

New vectors and a machine-readable store schema, plus the `ble/v1` and `uplink/v1` drafts. A
manifest with `valid: false` must now be refused at parse by every implementation, so a
runner pinning this release needs the new expectation fields (see below).

- `ble/v1` (**draft**, additive): `device-info.md` (a read-only `DEVICE_INFO` value: capabilities, firmware, identity,
  storage, transports, installed engines, boot timing, as unknown-skipping records; `UPLINK_EVENT` slot
  announcements) and `checkin.md` (four server-signed instruction types with a replay counter, and an unsigned,
  bounded `HOME_TRIGGER`). `PROTOCOL_VERSION` capability bit 3 = device information. 29 vectors including
  negatives. No existing byte or vector changed.
- `uplink/v1` (**draft**, new): the device uplink protocol for direct Wi-Fi and LTE upload. Per-request Ed25519
  signatures by the enrolled device key (`CAIRN-UPLINK-V1`, eight-line signing string), a server key pinned in
  firmware, the relay's offer, chunk, commit and receipt under `/v1/uplink/bundles/`, and 15 deterministic
  vectors including negative cases. Additive: no existing protocol or vector changed.
- `store/v1/schema.json`: the first machine-readable store contract, 8 tables and 10 views
  generated from the server's own native schema (`store/v1.0`). Read as a compatible range
  (see `store/v1/README.md`). Content change: needs a tagged release before a server can pin it.
- `sync/v1/vectors/exchanges.json` (added, with `vectors/README.md`): 83 request/response
  exchanges generated from the server, covering signed and bearer push, pull, ack, vehicle
  scoping, the bundle relay, and negatives (bad signature, replay, wrong scope, expired token,
  unknown vehicle, clock skew, revocation). New vectors, no change to any existing byte;
  `sync/v1` stays `draft` until the iOS app passes them. A release must be tagged for the
  server's CI to check against them.
- `sync/v1/spec.md`: clarified, not changed: a bearer token on a signed-only route is
  `401 signature_required` (what the server has always sent; §2.5 said every 401 is
  `unauthenticated`), and the relay's stable error codes are named (§13).
- `format/v3`: 26 negative vectors (now 59): header magic / version / short, frame header tamper, manifest
  tamper / wrong key / unsupported version / non-canonical / missing mandatory field, one vector per
  manifest binding rule, receipt bad signature / wrong signer / tampered root / unsupported version /
  non-canonical / truncated / trailing bytes, update descriptor tamper / wrong key. New expectation
  fields: `receipt.parse_error`, and `header.parse_error` values `bad_magic`, `short_header`,
  `unsupported_format_version`. A manifest with `valid: false` must now be refused at parse by every
  implementation. Existing vectors are byte-identical.
- `enrolment/v1`: `vectors/negative.json` (32 blobs, 5 stateful sequences).
- Each protocol README lists its negative cases (`sync/v1`'s are in `exchanges.json`).
- A runner that has not learned the new fields fails loudly, so the firmware runners need
  updating before they pin this release.

## 0.1.0 (2026-10-05)

The first release: the contracts move out of the monorepo into their own repository, and
the component repositories build against this tag instead of a local path.

- Collected into one place from the monorepo: `format/v3`, `enrolment/v1`, `sync/v1`,
  `ble/v1` (companion and offload), with their vectors. No byte changed in the move.
- Added `store/v1` and `share/v1` as drafts.
- Byte-level independence check: the `format/v3` vectors (33) pass unchanged in the Go reference,
  the C firmware implementation and the Rust emulator, and the generator reproduces them with no
  diff. `ble/v1` offload vectors are generated from the firmware module and match.
