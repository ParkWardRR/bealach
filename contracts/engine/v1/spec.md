# engine/v1 — engine profiles

**Draft.** See [README.md](README.md) for the status and the gate it has not yet met.

An engine profile is what the project knows about one engine. It has two halves, which
are written here as one contract because they were two files in two repositories that
shared an engine id and nothing else:

| Half | Identifier | Format | Answers |
|---|---|---|---|
| **Acquisition** (§2, §3) | `cairn.engine/v1-draft` | YAML, [`acquisition.schema.json`](acquisition.schema.json) | How do I read this ECU? PIDs, formulas, cadence, sleep, supply |
| **Analysis** (§4) | `cairn.engine-analysis/v0` | JSON, [`analysis.schema.json`](analysis.schema.json) | What does the reading mean? Labels, axes, warning limits, thresholds |

They share the **engine id** (`bmw-n20`) and the **field and signal vocabulary**. Nothing
else crosses between them: the dongle never reads an analysis profile, and the server
never reads a PID table.

## 1. Rules that hold for both halves

1. **`unknown` is an answer; a missing key is an error.** A section nobody has
   established is written `unknown` (acquisition) or `null` (analysis). The reader treats
   it as "no data" and falls back to its own default — never to another engine's number.
   A gap cannot hide as an omission.
2. **`status` is `stub`, `derived` or `verified`.** `stub` is identity only and claims
   nothing; a validator rejects a stub that states anything. `derived` was extracted from
   behaviour the code already had. `verified` was checked against raw replies from the
   real car.
3. **Every claim has a source.** `sources` is required and non-empty. A limit without a
   source is not reviewable.
4. **An id is lowercase, hyphen-separated, at most 31 characters**, and means the same
   engine in both halves.
5. **Unknown fields are an error, not an extension point.** Both schemas set
   `additionalProperties: false`, and readers reject unknown keys. A profile is not a
   place to stash data; adding a field is a contract change.

## 2. Acquisition: what a profile is

One file per engine, `<engine_id>.yaml`, where the file name equals the `engine_id`
field. [`acquisition.schema.json`](acquisition.schema.json) states the structure. What a
JSON Schema cannot state, and a validator must therefore enforce:

- **`engine_id` equals the file name.** Otherwise a profile can be selected under a name
  that is not in it.
- **One PID per capture-record `field`.** Two PIDs feeding `rpm` would make the stored
  value depend on request order.
- **PID ids are unique within a profile**, and so are `cold_slot` values.
- **At most six `tier: hot` PIDs**, and only Mode 01 (`service: 1`) may be hot: one
  multi-PID request carries at most six, and a manufacturer-specific request cannot be
  batched. Hot PIDs share that request **in file order**, every cycle.
- **`tier: cold` requires `cold_slot`; `tier: hot` forbids it.** Cold PIDs are requested
  one at a time, one slot per cycle, and every slot must be below `cadence.cold_slots`.
- **`pids` present requires `cadence` present.** A PID table with no cadence does not say
  when to ask.
- **Every formula compiles** under §3, and **its result interval lies inside the declared
  `range`**. The validator proves this; it does not sample it.
- **A stub claims nothing** beyond identity, `sources` and `applies_to`.

**A formula yields the value exactly as the capture record stores it**, including any
saturation the firmware applies. So the table is a statement about the bytes on the card,
not about an intermediate nobody can inspect. `range` is the `[min, max]` the formula can
produce, and `scale` is the decimal exponent relating the stored integer to the physical
value (stored × 10^`scale`).

### Identity

- A **profile hash** is SHA-256 of the file's bytes, with CRLF read as LF.
- A **build identity** is SHA-256 of `cairn.engine-build/v1-draft\n` followed, for each
  selected engine in `engine_id` order, by `<engine_id>\n<version>\n<hex hash>\n`.

A consumer that compiles profiles in carries both and reports them, so a reading can be
traced to the exact profile that produced it. The firmware logs
`engines=<id>@<version>/<hash16>,... build=<hash16>` at boot.

## 3. The formula language

Integer-only, no state, no loops, no calls out: it cannot execute anything and always
terminates. Every value is an **int32**, and **every operation's result must lie in int32
or evaluation fails — nothing wraps**. That is what lets implementations in C, Go, Rust,
Swift and TypeScript agree exactly: a TypeScript double computes any int32 operation
exactly up to the point it leaves the range, and leaving the range is an error either way.

```text
expr     := or
or       := and ( '|' and )*
and      := shift ( '&' shift )*
shift    := add ( ('<<' | '>>') add )*
add      := mul ( ('+' | '-') mul )*
mul      := unary ( ('*' | '/' | '%') unary )*
unary    := '-' unary | primary
primary  := INT | VAR | FUNC '(' expr (',' expr)* ')' | '(' expr ')'
INT      := decimal or 0x-hex literal, at most 2147483647
VAR      := A | B | C | D          the reply's data bytes, 0..255, in order
FUNC     := min(x,y) | max(x,y) | clamp(x,lo,hi)      clamp = min(max(x,lo),hi)
```

Precedence and associativity are C's. Whitespace is ignored. There are no comparisons, no
ternary, no floating point, and no identifiers other than those above. At most **256
characters**, nesting at most **32**.

- `/` truncates **toward zero**; `%` takes the sign of the **dividend** (C99). Division or
  remainder by zero is an error.
- `>>` is **arithmetic** (it floors, so `-9 >> 1` is `-5` while `-9 / 2` is `-4`); `<<`
  multiplies by 2^n and is range-checked. A shift count outside `0..31` is an error.
- `&` and `|` act on the two's-complement int32 values.
- A literal may be written `0x`-hex. A trailing letter, dot or underscore is an error, not
  the end of a number: `1.5`, `10kPa` and `1_000` are rejected rather than silently read
  as `1`, `10` and `1`.
- `A`..`D` are variables only standing alone. `Abs` is an unknown name, not `A` followed
  by something.

### Static checks

From interval analysis over the variables the PID's `bytes` provides (each `0..255`, the
rest unavailable), a validator must reject an expression when:

- it uses a variable beyond `bytes`;
- a divisor or modulus interval includes 0 (write `A / max(B, 1)`);
- a shift count is not a constant in `0..31`;
- any intermediate can leave int32;
- the result interval is not inside the declared `range`.

**So an accepted formula cannot fail at run time on any reply the PID can return.** That
is the language's central claim, and it is what makes `range` trustworthy downstream.
Evaluators check anyway, because bytecode in flash is only as trustworthy as the flash.

### Bytecode

A stack machine, **16 entries** deep, no jumps. The program must leave **exactly one**
value. Compiled code is at most **255 bytes**.

| code | op | | code | op |
|---|---|---|---|---|
| 01 | push u8 (imm8) | | 25 | neg |
| 02 | push u16 (imm16 LE) | | 26 | and |
| 03 | push i32 (imm32 LE) | | 27 | or |
| 04 | push s8 (imm8, sign-extended) | | 28 | shl |
| 10..13 | load A..D | | 29 | shr |
| 20 | add | | 30 | min |
| 21 | sub | | 31 | max |
| 22 | mul | | 32 | clamp (x lo hi) |
| 23 | div | | | |
| 24 | mod | | | |

Binary ops pop `b` then `a` and push `a op b`. `clamp` pops `hi`, `lo`, then `x`.

Runtime errors, by the names the vectors use: `ERR_TRUNC` (an immediate runs off the end),
`ERR_BAD_OP`, `ERR_STACK` (underflow, or deeper than 16), `ERR_DIV_ZERO`, `ERR_OVERFLOW`,
`ERR_SHIFT`, `ERR_RESULT` (not exactly one value left).

**The compiler picks the shortest push**: `0..255` → u8, `-128..-1` → s8, `256..65535` →
u16, anything else → i32. **A negated literal is a literal**, so `-127` costs one push and
not a push plus a `neg`. Both choices are observable in the bytes, so they are contract
and the `E` vectors pin them.

## 4. Analysis: what a reading means

[`analysis.schema.json`](analysis.schema.json) states the structure: an engine id, a name,
a status, the engine `codes` the profile answers for, `sources`, a list of `signals` and a
map of named `thresholds`. What a schema cannot state:

- **`min` is below `max`**; `warn_low` is below `warn_high`; `check_high` is not below
  `warn_high` and `check_low` is not above `warn_low`. A check limit tighter than its warn
  limit could never trigger.
- **No signal key is repeated.**
- **A stub states no limit and no threshold.**
- **Two profiles may not claim the same engine code.** Codes match trimmed and
  upper-cased; a code that merely *contains* a known one is not a match.

### `null` means "not known", never "no limit"

This is the rule the whole half exists for. A `warn_high` of `null` says **nobody has
established a limit**, so a reading is never flagged against it. It does not say the
reading is fine. Three consequences a consumer must honour:

1. **Unknown is not "ok".** A metric whose engine states no limit is not called normal on
   its absolute value. It can still be judged against the car's own earlier readings,
   which needs no knowledge of the engine at all, and is otherwise left out.
2. **A thin sample is not a verdict.** A metric needs enough observations in the recent
   window before anything is said about it. An empty finding list means "not enough
   driving yet", not "all fine".
3. **A tune is not a fault.** Where a baseline is compared, it starts at the latest tune:
   fuel trim that moved because the car was retuned is not drift.

A stub profile is therefore useful and honest: the dashboard plots the engine's boost
curve and says nothing about whether the number is normal.

### Generic

An engine with no profile gets **none** — the API says `null` — and the reader falls back
to a `generic` profile carrying only what holds for every engine: the ECU's own fuel-trim
range and a band any engine's trims should stay inside. `generic` is never presented as
*that engine's* profile.

### Thresholds

`thresholds` is a flat map of name to number, read by name with the reader's own default.
A reader asks for `ltft_drift_watch_pct` and supplies what to use when the profile states
none, so adding a threshold never breaks an older reader and removing one is a contract
change.

## 5. Relationship to `module/v1`

A module (`contracts/module/v1`, when it exists) names this contract's
vocabulary in two places, and that is the entire coupling:

| Module manifest | Points at |
|---|---|
| `requires.engine_fields[]` | the `field` enum in `acquisition.schema.json` — the capture-record fields the dongle must be recording for the module to work |
| `metrics[].key` | a `signals[].key` in an analysis profile — how a module's readings find their limits |

Adding a capture field is a change to §2's `field` enum, which is what lets a module ask
for it. A module cannot invent a field, and cannot make a dongle poll a PID the engine
profile does not declare; it can only state a requirement and be told no at build time.

## 6. Vectors

See [`vectors/README.md`](vectors/README.md). In summary:

- **`vectors/expr.txt`** — the formula language: `E` lines (expression, inputs, expected
  value and exact bytecode), `X` lines (expressions a compiler must reject, and what the
  rejection must mention) and `B` lines (raw bytecode and the value or `ERR_*` an evaluator
  must produce, which is the only way to reach the runtime errors).
- **`vectors/invalid/*.yaml`** — acquisition profiles that must be rejected, each headed
  `# expect-error: <text the rejection must contain>`.
- **`vectors/analysis/*.json`** — analysis profiles, valid and invalid, in one file each
  with the same `expect-error` convention carried in a field.

**The valid acquisition vectors are the shipped profiles themselves**, which live with the
firmware rather than being copied here. A second copy of `bmw-n20.yaml` would drift from
the one the car actually runs, and a vector that has drifted from production is worse than
no vector. The firmware's CI validates its profiles against this schema.
