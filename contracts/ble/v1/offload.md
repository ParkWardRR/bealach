# BLE bundle offload (protocol v1, Phase 3)

Sealed bundles can leave the dongle by more than one path. **This document is the path
through the phone**: the enrolled phone pulls them over BLE, uploads them to the Cairn
server on the dongle's behalf, and hands the server's signed receipt back. A dongle that
also has Wi-Fi or LTE (a planned direction, see the roadmap) uploads on its own over the
device uplink; the phone is then one path of several, not the only one.

The two paths are made to agree rather than coordinate. Both end at the same server
endpoints with the same semantics, every step is idempotent, and the server is the only
authority on whether a bundle is held:

- A bundle the server already holds comes back from `offer` with **no missing chunks and
  `receipt_available: true`**. The phone then reads nothing from the dongle and only carries
  the receipt back with `PUT_RECEIPT`, so the dongle can prune.
- A bundle the phone is halfway through when the dongle uploads it itself is still correct:
  chunks are content-addressed and `commit` is idempotent.
- The dongle never deletes on the word of either path, only on a receipt signed by the
  server key pinned in its firmware.

This document is the contract for the phone path. It extends [ble-companion-protocol.md](spec.md)
(same service, same bonding, little-endian, fixed binary layouts) and builds on
[bundle-format-v3.md](../../format/v3/spec.md) §6 (the upload protocol) and
[trust-model-v3.md](../../../docs/trust-model-v3.md).

## 1. Who is trusted with what

| | The phone | The server | The dongle |
|---|---|---|---|
| Can read trip data | **No.** It carries ciphertext only; frames are XChaCha20-Poly1305 under a key it never sees | Yes (holds the escrowed storage root) | Yes |
| Can make the dongle delete a bundle | **No.** Only a receipt signed by the server key pinned in firmware, naming the content root of exactly that bundle | Issues the receipt | Verifies it, then prunes |
| Can corrupt a bundle in transit | Every chunk is SHA-256-checked against the signed manifest by the server; the manifest is signed by the device | Rejects bad chunks | n/a |
| Can see metadata (sizes, counts, times) | Yes, from the manifest | Yes | Yes |

So the phone is trusted for **availability** only. A malicious or buggy phone can
fail to upload; it cannot lose data, forge a receipt, or read a trip. This is why
the BLE link's access control is "bonded with the passkey" and not a second
signature scheme (an enrolled-app challenge–response is a planned hardening, not a
requirement for this protocol).

## 2. Capability and characteristics

`PROTOCOL_VERSION` (`00F0`) byte 1 (capabilities) gains **bit 2 = bundle offload**.
A phone must not use the characteristics below unless it is set.

| Name | Suffix | Direction | Properties |
|---|---|---|---|
| `OFFLOAD_CONTROL` | `0030` | both | write (with response) phone→device; **indicate** device→phone |
| `OFFLOAD_DATA` | `0031` | both | **notify** device→phone (bundle bytes); write-without-response phone→device (receipt bytes) |

Both require an encrypted, authenticated (bonded) link, like every other
characteristic. Request an MTU of 247 and a 15–30 ms connection interval; expect
roughly 10–25 KB/s. A 1 MB drive offloads in about a minute.

**The MTU must be at least 43** (a 40-byte payload: enough for one `LIST` entry).
Below that the dongle answers every request `IO_ERROR` rather than half working, so
negotiate the MTU before the first request. Messages are sized to the negotiated MTU
minus 3, up to 244 bytes.

**Capability bit 2 is set only when the dongle's offload task actually started.**

## 3. Framing

### Control messages

Request (phone → `OFFLOAD_CONTROL`): `u8 op ‖ u8 request_id ‖ payload`.
Response (device → indication): `u8 (op | 0x80) ‖ u8 request_id ‖ u8 status ‖ payload`.
`request_id` is chosen by the phone and echoed. **One operation at a time**: a
second request while one is in progress gets `BUSY`.

| op | Name | Request payload | Response payload (after `status`) |
|---:|---|---|---|
| `0x01` | `LIST` | `u16 first_index` | `u16 total ‖ u16 first_index ‖ u8 n ‖ n × entry` |
| `0x02` | `GET_MANIFEST` | `bundle_id[16]` | `u32 total_len` (then data, §3.3) |
| `0x03` | `READ` | `bundle_id[16] ‖ u64 offset ‖ u32 length` | `u32 length` (then data, §3.3) |
| `0x04` | `PUT_RECEIPT` | `bundle_id[16] ‖ u16 receipt_len` | (after the receipt bytes arrive, §3.4) `u8 outcome` |
| `0x05` | `ABORT` | — | — |

`entry` (29 bytes): `bundle_id[16] ‖ u64 stream_bytes ‖ u16 manifest_len ‖ u16 chunk_count ‖ u8 state`
where `state` is `0` = sealed, awaiting a receipt, `1` = receipt verified, prune
pending. Only **sealed** bundles are listed; the capture in progress never is.

`status`: `0` OK · `1` BUSY · `2` UNKNOWN_BUNDLE · `3` BAD_ARGUMENT · `4` TRIP_ACTIVE ·
`5` IO_ERROR · `6` BAD_RECEIPT_LENGTH · `7` NO_TRANSFER.

### 3.1 Why `TRIP_ACTIVE`

Offload competes with capture for the card's SPI bus, so the dongle refuses
`LIST`, `GET_MANIFEST`, `READ` **and `PUT_RECEIPT`** while a trip is in progress and
the phone simply tries again after the drive. Capture is never degraded to serve a
transfer. "In progress" means any capture state but idle: a suspected start, the
drive itself, and the trailing dwell before the trip is sealed. **A trip's bundle only
exists to offload once it is sealed**, which happens after that dwell, so a phone that
asks the moment the engine stops will see `TRIP_ACTIVE`, then an empty list, then the
new bundle. A trip that starts *during* a transfer ends it with `TRIP_ACTIVE` in the
done indication.

An operation that stops making progress for 8 seconds is abandoned (`IO_ERROR` in the
done indication for transfers, `NO_TRANSFER` for a receipt upload) so a vanished
phone cannot hold the dongle. `ABORT` is always honoured.

### 3.2 The bundle byte stream

`READ` offsets and lengths address the **bundle byte stream**: the concatenation of
the member files' contents in the manifest's canonical member order
([bundle-format-v3.md](../../format/v3/spec.md) §6.1). It is exactly the byte string the
server's chunk upload carries. `length` is at most **65 536**; the phone issues
several reads per chunk and concatenates. `offset + length` past the end of the
stream is `BAD_ARGUMENT`.

### 3.3 Data transfer (`GET_MANIFEST`, `READ`)

After an `OK` response the device sends the bytes as `OFFLOAD_DATA` notifications,
each `u16 seq ‖ bytes` (`seq` starts at 0 per transfer and wraps), then a final
**transfer-done** indication on `OFFLOAD_CONTROL`:
`0x86 ‖ request_id ‖ status ‖ u32 bytes_sent ‖ u32 crc32`, where `crc32` is the
IEEE CRC-32 of the bytes sent. The phone checks `bytes_sent` equals what it asked
for, that it received contiguous `seq` values and that the CRC matches, and
re-issues the `READ` for the range otherwise. A notification can be lost on a bad
link; the length and CRC are how that is noticed. (The server's chunk SHA-256 is
the end-to-end check; this one just avoids uploading a chunk that is already known
to be bad.)

`GET_MANIFEST` transfers `manifest.cbor` followed by the 64-byte Ed25519
`manifest.sig`, `total_len = manifest_len + 64`.

### 3.4 Handing back a receipt (`PUT_RECEIPT`)

1. Phone sends `PUT_RECEIPT` with `receipt_len` (≤ 1024, else `BAD_RECEIPT_LENGTH`).
2. Device answers `OK` (ready).
3. Phone writes the receipt on `OFFLOAD_DATA` (write-without-response) as
   `u16 seq ‖ bytes` frames.
4. When `receipt_len` bytes have arrived the device **stores the receipt, verifies
   it against the pinned server key and the bundle's content root, and prunes**,
   then indicates `0x84 ‖ request_id ‖ 0 ‖ u8 outcome`.

| `outcome` | Meaning | Phone should |
|---:|---|---|
| `0` | Verified and pruned | Mark the bundle done |
| `1` | Verified and stored, but the delete did not complete | Mark done; the dongle finishes the prune at boot |
| `2` | **Rejected: malformed, or the signature does not verify** | Stop and surface it: the server key and the firmware's pinned key disagree. Never retry blindly |
| `3` | **Rejected: receipt names a different content root** | Same as 2 |
| `4` | **No receipt key is pinned in this firmware**, so the receipt could not be verified; **nothing was stored or deleted** | Surface it: the dongle will never free space until a build with the server's key is flashed. The bundle is safe |

A receipt is verified **before anything is written to the card**: a forged receipt
cannot overwrite a genuine one already stored, and does not leave a file that makes
the bundle look receipted.

If the upload itself goes wrong (a frame out of sequence, more bytes than announced,
a stall, a trip starting), the dongle ends it with `0x84 request_id status` and a
**non-zero status and no outcome byte** (`BAD_ARGUMENT`, `BAD_RECEIPT_LENGTH`,
`NO_TRANSFER`, `TRIP_ACTIVE`). Nothing was stored or deleted; start again.

A receipt is verified on the dongle against a key **pinned in firmware**, never
against a key the phone supplies. That is the whole guarantee: the phone cannot
cause a deletion the server did not authorise for exactly these bytes.

## 4. The phone's loop

```text
connected, bonded, capability bit 2 set
  LIST                                     (retry later on TRIP_ACTIVE)
  for each entry with state 0:
    GET_MANIFEST            → manifest.cbor ‖ manifest.sig
    POST /v1/relay/bundles/offer            → missing chunks {index, offset, length, sha256}
    for each missing chunk:
      READ(offset, length) × ⌈length/65536⌉ → verify sha256 → PUT /v1/relay/…/chunks/{sha256}
    POST /v1/relay/bundles/{id}/commit      → receipt (CBOR, signed, taken verbatim)
    PUT_RECEIPT(receipt)                    → outcome
```

Every step is idempotent and resumable: the server's offer reports which chunks it
already holds, the phone re-reads only those, and a receipt re-fetched with
`GET /v1/relay/bundles/{id}/receipt` is byte-identical. Nothing is ever deleted
on the dongle until `PUT_RECEIPT` succeeds.

The server half is specified in [app-sync-protocol.md](../../sync/v1/spec.md) §13.

## 5. When the dongle is reachable

The dongle advertises while it is awake. After a drive it stays up through its
idle dwell and **will not enter standby while an offload session is open or
bundles are pending and a phone is connected**. Once in standby (BLE off) it wakes
only on engine start or its six-hourly heartbeat. So the phone should connect as
soon as it sees the service after a drive (CoreBluetooth scan with the service UUID,
state restoration so the app is relaunched), offload immediately, and not expect
to be able to reach a dongle that has been parked for hours.

## 6. Out of scope here

Firmware updates through the same channel (the verification gate in `docs/ota.md`
is transport-independent; the BLE delivery is a later phase) and the optional
enrolled-app challenge–response on the BLE link.
