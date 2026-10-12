# Bealach Dev Tooling

Development-only tools for vector generation, contract checking, and engine
profile validation. **Never product scope** — these are build/test tools that
keep firmware and iOS honest.

## Tools

| Tool | Language | Purpose |
|---|---|---|
| `blevectors` | Go | BLE protocol vector generation and validation |
| `contractcheck` | Go | Contract conformance checks against format v3 vectors |
| `enginelang` | Go | Engine profile expression language and validation |
| `enginegen` | Rust | Engine profile firmware code generator |

## Provenance

Go tools from
[cairn-driving-log-selfhosted](https://github.com/ParkWardRR/cairn-driving-log-selfhosted)
@ `7ed8dac`.

Rust enginegen from
[cairn-esp32-device-firmware](https://github.com/ParkWardRR/cairn-esp32-device-firmware)
@ `ead3532`.

See [docs/migration-from-cairn.md](../docs/migration-from-cairn.md).
