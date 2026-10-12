# engine/v1 vectors

Deterministic and offline. They contain **no keys of any kind** — an engine profile is a
description of an ECU, not a credential — so unlike the `format/v3` vectors there is no
public-test-key warning to carry here.

## `expr.txt` — the formula language

105 vectors. Lines starting with `#` and blank lines are comments; fields are separated by
`;` and trimmed.

```text
E ; nbytes ; expression ; A B C D ; expected ; bytecode-hex
X ; nbytes ; expression ; text the rejection must mention
B ; bytecode-hex ; A B C D ; expected | ERR_*
```

| Kind | Count | Pins |
|---|---|---|
| `E` | 50 | Compilation **and** evaluation: the implementation must emit exactly that bytecode and get exactly that value |
| `X` | 23 | Rejection, by substring, so wording can improve without breaking a vector |
| `B` | 32 | The evaluator alone, on bytecode no compiler emits — the only way to reach the runtime errors |

Input bytes are decimal, space-separated, at most four; absent bytes are 0. An `E` line's
bytecode is exact, so the push-encoding rules and the negated-literal rule in
[`../spec.md` §3](../spec.md#bytecode) are machine-checked rather than merely described.

The `B` lines matter more than their count suggests. A compiler that passes the static
checks can never produce code that divides by zero or overflows, so `ERR_DIV_ZERO` and
`ERR_OVERFLOW` are unreachable from any valid profile. They are reachable from corrupt
flash, and an evaluator that skipped those checks would pass every `E` vector.

### Who runs them

| Implementation | Language | Command |
|---|---|---|
| Generator and compiler | Rust | `make engines-test` (firmware) |
| Evaluator | C | `make -C test/host engine` (firmware) |
| Compiler and evaluator | Go | `go run ./cmd/engine-check` (this repository, from `tools/`) |

Regenerate the bytecode column with the Rust generator's
`enginegen vectors --file ... --update`. The Go implementation deliberately has no
`--update`: a third implementation that can rewrite the vectors it is checked against is
not an independent check.

## `invalid/*.yaml` — acquisition profiles that must be rejected

20 profiles, each headed `# expect-error: <text the rejection must contain>`. They cover
the checks a JSON Schema cannot express, which is most of the ones that matter:

| Case | What it catches |
|---|---|
| `bad-id-mismatch` | `engine_id` not equal to the file name |
| `bad-duplicate-pid`, `bad-duplicate-field`, `bad-cold-slot`, `bad-cold-no-slot` | PID table coherence: unique ids, one PID per field, slots inside `cold_slots`, cold requires a slot |
| `bad-too-many-hot` | more than six hot PIDs for one batched request |
| `bad-pids-no-cadence` | a PID table that never says when to ask |
| `bad-formula-syntax`, `bad-formula-byte`, `bad-formula-overflow`, `bad-div-by-zero` | the static checks of the formula language |
| `bad-empty-range`, `bad-impossible-range` | a declared range a formula cannot satisfy |
| `bad-stub-claims` | a stub that states something |
| `bad-missing-section`, `bad-unknown-field`, `bad-duplicate-key`, `bad-schema-version` | the shape, including a duplicate YAML key, which many parsers accept silently |
| `bad-engine-on`, `bad-vin-pattern` | value-level limits |

A rejection is matched by **substring**, so an implementation may word its errors however
it likes as long as it names the thing that is wrong.

The **valid** acquisition vectors are the shipped profiles themselves, in the firmware
repository. They are not copied here: a second copy of `bmw-n20.yaml` would drift from the
one the car actually runs, and a vector that has drifted from production is worse than no
vector at all.

## `analysis/*.json` — analysis profiles

One file per case. A valid case is a bare profile. An invalid case is wrapped so the
expectation travels with it:

```json
{ "expect_error": "text the rejection must contain", "profile": { ... } }
```

A reader under test loads `profile` and must reject it with a message containing
`expect_error`. A file with no `expect_error` key is a profile that must load.

**These have one implementation, not two.** The schema was reverse-engineered from the
server's `internal/engine` reader, so these vectors currently describe that reader rather
than constraining it. That is recorded as an open item in [`../README.md`](../README.md).
