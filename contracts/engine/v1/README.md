# Engine profiles v1 (draft)

What the project knows about one engine: how to read its ECU, and what the readings mean
once they are stored. [`spec.md`](spec.md) is the normative text.

This contract exists to end a split. The two halves were two files in two repositories
under two schema identifiers, and the server's own code said they "share an engine id
(`bmw-n20`) and nothing else":

| Half | Identifier | Format | Was |
|---|---|---|---|
| **Acquisition** | `cairn.engine/v1-draft` | YAML, [`acquisition.schema.json`](acquisition.schema.json) | `engines/engine.schema.draft.json` + `engines/SPEC.draft.md` in the firmware repository |
| **Analysis** | `cairn.engine-analysis/v0` | JSON, [`analysis.schema.json`](analysis.schema.json) | an undocumented Go struct in `internal/engine` in the server repository |

- **Status:** draft. The schemas and the normative text are here; the release gate below
  is not met.
- **Producers:** a maintainer writes profiles by hand, from measurements or from code that
  already worked.
- **Consumers:** the firmware's generator compiles acquisition profiles into C tables; the
  server reads analysis profiles to turn store statistics into sentences; a module
  (`contracts/module/v1`, when it exists) names this contract's field and signal
  vocabulary.

## Why the identifiers still say `-draft` and `v0`

Deliberately. Promoting the directory to `contracts/engine/v1` is what makes the contract
*findable and citable*; promoting the in-document identifiers is what tells a consumer the
bytes are settled. Those are different claims, and only the first is true today.

A profile written now carries `schema: cairn.engine/v1-draft`, exactly as the shipped
profiles do, so **nothing has to change on either side for this contract to land**. The
identifiers lose their `-draft` and become `v1` in one release, when the gate is met.

## The release gate

Per [the contracts README](../../README.md#how-a-contract-changes), a byte-level change
needs at least one **independent** consumer to validate the candidate vectors before
tagging, because "a generator reproducing its own output proves determinism, not
correctness".

| Implementation | Language | Where | Status |
|---|---|---|---|
| Generator and compiler | Rust | firmware `tools/enginegen` | passes |
| Evaluator | C | firmware `test/host` | passes |
| **Compiler and evaluator** | **Go** | **this repository, [`tools/enginelang`](https://github.com/ParkWardRR/cairn-driving-log-selfhosted/tree/main/tools/enginelang)** | **passes — all 105 `expr.txt` vectors** |

The third implementation now exists and was written from [`spec.md`](spec.md) rather than
from the Rust, which is the point: two implementations written together agree on the
mistakes they were written with. It passed all 105 expression vectors on its first
complete run, so the Rust and the C do match the normative text.

What is still missing before this leaves draft:

- [ ] **The firmware reads the schema from here** rather than from its own copy. Until it
      does there are two copies of the acquisition schema and they can drift. This is the
      one remaining item that is purely mechanical.
- [ ] **The server validates analysis profiles against
      [`analysis.schema.json`](analysis.schema.json)**, and its `internal/engine` reader
      agrees with `vectors/analysis/`. The schema was reverse-engineered from that reader,
      so it has one implementation, not two.
- [ ] **An acquisition profile with `status: verified`.** Both shipped profiles are
      `derived` or `stub`; nothing has been checked against raw ECU replies. A contract
      whose every instance is provisional should not claim to be stable.
- [ ] **A decision on `probes`.** It describes what a validation *build* asks of an ECU,
      which is tooling rather than protocol. It may not belong in a released contract.

## Support window

Not applicable while draft: a draft protocol may change in place. Once released, the
acquisition half follows the firmware rule — it stays until no supported firmware produces
it, because devices in cars update slowly. The analysis half is server-side only and can
move faster.

## Files

| File | What it is |
|---|---|
| [`spec.md`](spec.md) | Normative. Both halves, the formula language, the bytecode, and the relationship to `module/v1` |
| [`acquisition.schema.json`](acquisition.schema.json) | JSON Schema for the YAML acquisition profile. Carries the `field` enum, the vocabulary a module requires against |
| [`analysis.schema.json`](analysis.schema.json) | JSON Schema for the JSON analysis profile |
| [`vectors/`](vectors/) | The formula-language vectors, the invalid acquisition profiles and the analysis profiles |

The valid acquisition vectors are the **shipped profiles themselves** and are not copied
here; see [`spec.md` §6](spec.md#6-vectors) for why.
