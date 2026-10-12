# Contract specs and test vectors

Carried from Cairn ([cairn-driving-log-selfhosted](https://github.com/ParkWardRR/cairn-driving-log-selfhosted)
@ `7ed8dac3212c504375427bf5690f0efa1349b18d`). These are the machine-readable
contract specifications and byte-level conformance vectors that firmware and
iOS must agree on.

Bealach's own contract documents (the four prose contracts with Bealach-specific
deltas) live in [docs/contracts/](../docs/contracts/).

## Provenance

| Path | Source | License |
|---|---|---|
| `format/v3/` | `contracts/format/v3/` @ `7ed8dac` | Blue Oak Model License 1.0.0 |
| `ble/v1/` | `contracts/ble/v1/` @ `7ed8dac` | Blue Oak Model License 1.0.0 |
| `engine/v1/` | `contracts/engine/v1/` @ `7ed8dac` | Blue Oak Model License 1.0.0 |

## Vectors

- `format/v3/vectors/` — ~60 byte-level fixtures for the recording format
  (segment headers, CRC chains, AEAD, Merkle roots, torn tails, mutations)
- `ble/v1/vectors/` — BLE protocol vectors (device-info, golden, offload).
  **Device-info vectors are draft — verify before trusting.**
- `engine/v1/vectors/` — engine profile validation vectors (analysis + invalid
  YAML profiles + expression language)

## Wire-format markers

`CRN3` magic and `cairn/…` KDF context strings are retained for vector
compatibility (Q7 decision). The product layer uses Bealach naming; the wire
format keeps Cairn markers so existing vectors pass unchanged.
