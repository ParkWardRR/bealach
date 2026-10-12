# BLE check-in: instructions and the home trigger (ble/v1, DRAFT)

When the dongle is back on BLE after a Wi-Fi slot, the phone may deliver a **small, closed set of
instructions**. This is a remote-control surface, so it is built to be boring: no code, no free-form
parameters, four message types, every one authenticated by something the phone cannot forge.
Characteristics are in [`device-info.md`](device-info.md) §1. Threats are N7 and N9 in the
[threat model](../../../docs/threat-model.md). Context:
[issue 21](https://github.com/ParkWardRR/cairn-driving-log-selfhosted/issues/21).

> **Draft.** Same status as `device-info.md`: a Go reference and one independent check of the
> signatures; no firmware or app implementation yet.

## 1. Who is trusted with what

| | The phone | The server |
|---|---|---|
| Can issue an instruction | **No.** It **carries** one | **Yes**, by signing it with its instruction key |
| Can forge, alter or replay one | No: the dongle verifies a signature against a key **pinned in firmware** | n/a |
| Can make the dongle delete data, change credentials or raise the data cap | **No instruction does any of those directly** | Only via a signed `CONFIG` (see `config/v1`) |
| Can say "you are home" | Yes (§3), a low-risk hint, not an instruction | n/a |

So a malicious, stolen or revoked phone can at worst **fail to deliver**, **delay**, or **drop** an
instruction. The phone authenticates to the *server* as an enrolled client to obtain a signed
instruction (the server refuses unenrolled and revoked clients); the dongle never learns who
the phone is and needs no list of enrolled clients. The instruction key is a dedicated Ed25519 key,
separate from the receipt key and the TLS pin, pinned in firmware.

## 2. `INSTRUCTION` (phone → device)

A single write (or a long write), **at most 512 bytes**:

| Off | Size | Field | Notes |
|---:|---:|---|---|
| 0 | 1 | `version` | `1` |
| 1 | 1 | `type` | below |
| 2 | 2 | `body_len` | bytes of body |
| 4 | 4 | `counter` | per device, strictly increasing; the dongle stores the highest it has applied (`counter_floor`) |
| 8 | `body_len` | `body` | per type |
| 8 + `body_len` | 64 | `signature` | Ed25519 |

The signature covers `"CAIRN-INSTR-V1" ‖ 0x00 ‖ device_id[16] ‖ frame[0 : 8 + body_len]`, so it
binds the **device** (an instruction signed for another unit is refused) and the **context** (it
cannot be a manifest, a receipt, an uplink request or an enrolment blob: none can begin with those
bytes). Ed25519 is deterministic: signatures are "must equal" in the vectors.

| `type` | Name | `body` | Effect |
|---:|---|---|---|
| `0x01` | `UPLOAD_NOW` | empty | start an uplink attempt on the next opportunity |
| `0x02` | `STOP_TRYING` | `u16 hours`, 1 to 168 | stop **network** uplink attempts for that long; BLE offload is unaffected |
| `0x03` | `CONFIG` | a `config/v1` sealed message, opaque to this layer, 1 to 440 bytes | handed to the configuration verifier; this layer neither reads nor applies it |
| `0x04` | `CLEAR_STOP` | empty | cancel a `STOP_TRYING` |

**The set is closed.** An unknown `type` is refused, however well it is signed. Adding a type is a
new protocol minor version, and an instruction that deletes data, rewrites credentials directly
or raises the LTE ceiling must **never** be added here (only `CONFIG`, which has its own sealing
and bounds, may carry such changes).

### Checks, in this order

1. `version` is 1, total length is between 72 and 512, and equals `8 + body_len + 64`: else `BAD_LENGTH`.
2. The signature verifies over the signed bytes with the pinned key: else `BAD_SIGNATURE`. **Nothing
   after this is looked at before the signature is good**, so an unauthenticated writer learns
   nothing but "rejected".
3. `type` is known and `body_len` is the one the type requires: else `UNKNOWN_TYPE` or `BAD_LENGTH`.
4. `counter` is **greater than** `counter_floor`: else `REPLAY` (equal counts as a replay).
5. The body is in range (`STOP_TRYING` hours 1 to 168): else `OUT_OF_RANGE`.
6. Device conditions: not during a trip (`TRIP_ACTIVE`), and a `CONFIG` that carries a network
   credential is refused with `ENCRYPTION_REQUIRED` until flash and NVS encryption are on.
7. Rate limit: at most **1 instruction per 2 s and 30 per hour**: else `RATE_LIMITED`.
8. Apply, then **persist the counter floor before answering**, so a power cut cannot make the same
   frame valid again.

The floor moves **only** when an instruction is applied; a refused frame never changes it.

### `INSTRUCTION_RESULT` (indicate, 8 bytes)

`u8 status ‖ u8 type ‖ u16 reserved(0) ‖ u32 counter_floor` (the floor after this frame).

| `status` | Name | Phone should |
|---:|---|---|
| 0 | `APPLIED` | mark delivered |
| 1 | `BAD_SIGNATURE` | stop: the server's instruction key and the firmware's pin disagree; surface it, never retry blindly |
| 2 | `REPLAY` | drop it; fetch a fresh instruction (the counter moved on) |
| 3 | `UNKNOWN_TYPE` | drop it; surface (a newer server than this firmware) |
| 4 | `BAD_LENGTH` | drop it; this is a bug |
| 5 | `RATE_LIMITED` | retry after the interval |
| 6 | `TRIP_ACTIVE` | retry after the drive |
| 7 | `ENCRYPTION_REQUIRED` | surface: the unit will not take credentials until its flash is encrypted |
| 8 | `OUT_OF_RANGE` | drop it; this is a bug |

An instruction that arrives while the dongle is busy with offload is queued by the phone, not by
the dongle: **one instruction at a time**, and the dongle answers each.

## 3. `HOME_TRIGGER` (phone → device, 6 bytes)

"You may use Wi-Fi now" for the phone-asserted option. It is a hint, **not** an instruction, and
is deliberately unsigned: all it can do is let the dongle try the networks it was already given.

| Off | Size | Field | Notes |
|---:|---:|---|---|
| 0 | 1 | `flags` | bit 0 = home; all other bits 0 |
| 1 | 1 | `reserved` | 0 |
| 2 | 2 | `valid_seconds` | how long the permission lasts, **at most 900**; 0 with `home` clear |
| 4 | 2 | `seq` | wrapping; a repeat or older value is ignored |

- A frame that is not 6 bytes, sets a reserved bit or has `valid_seconds` above 900 is refused
  with an ATT error and counted.
- It expires on its own after `valid_seconds` (the dongle does not hold it across a reboot),
  and `home` clear withdraws it at once. It is ignored during a trip.
- At most **1 per 10 s**.
- It gives the dongle **no** new network, credential or destination, and changes no stored
  setting. The worst a hostile bonded central can do with it is make the dongle try a known
  network for up to 15 minutes, which the bounded slot already limits
  ([threat model N8, N9](../../../docs/threat-model.md)).
- The dongle stores no coordinates and no list of places for this option: whether the phone is
  "home" is the phone's own decision.

## 4. Vectors

[`vectors/device-info/vectors.json`](vectors/device-info/vectors.json) pins, for the public test
instruction key and test device id:

- three signed frames that apply (`UPLOAD_NOW` counter 7, `STOP_TRYING` 24 h counter 8, `CONFIG`
  with an opaque 100-byte body counter 9), each with its exact bytes and its `INSTRUCTION_RESULT`;
- the **negative** cases, each with the status and the counter floor afterwards: a replayed
  frame, a counter equal to the floor, one signature bit flipped, a body changed after signing, a
  frame signed for another device, a correctly signed **unknown type**, hours 0 and 169, a
  one-byte `STOP_TRYING` body, a truncated frame and a 513-byte frame;
- home triggers: valid, withdrawn, `valid_seconds` 901 and a reserved flag bit (both refused).
