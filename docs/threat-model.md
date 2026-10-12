# Threat model

Bealach's trust model is **device-to-owner-phone**. There is no server, no
account, and no network-facing surface. The phone is the final verifier and
store; the SD card is the source of truth but never the security boundary.

This is a revision of Cairn's v3 trust model
([cairn-driving-log-selfhosted `docs/trust-model-v3.md`](https://github.com/ParkWardRR/cairn-driving-log-selfhosted/blob/main/docs/trust-model-v3.md),
pinned `7ed8dac`) with the server removed.

## 1. Assets

| Asset | Sensitivity | Impact of compromise |
|---|---|---|
| Trip location history | High | Routines, home/work, habits |
| Raw recording originals (SD) | High | The authoritative driving record |
| Storage root `K_root` (device-held; mirrored to the owner phone at enrolment) | High | Decrypts every recording the device made under that root |
| Device Ed25519 signing seed | High | Forges manifests; breaks authenticity |
| Owner-phone signing key (Secure Enclave) | High | Forges mirror acks; can authorise reclaim of verified data |
| BLE bond / link keys | Medium | Live access to metadata and the mirror channel |
| Manifest metadata (sizes, counts, times) | Medium | Reveal activity patterns even without plaintext |
| Derived trips/summaries on the phone | Medium | Same as location history, more convenient |

## 2. Actors and trust boundaries

```text
┌────────────────────────────────┐          ┌─────────────────────────────────┐
│ Dongle (trusted for capture)   │   BLE    │ Owner iPhone (trust anchor)     │
│  - K_root, Ed25519 seed        │◄────────►│  - Secure Enclave identity key  │
│  - pinned owner-phone key      │  bonded, │  - K_root copy (escrow)         │
│  - SD ciphertext               │  enc.,   │  - verified mirror + derived UI │
│  - NO network stack in scope   │  auth'd  │  - final verifier and store     │
└────────────────────────────────┘          └─────────────────────────────────┘
```

| Boundary | Trust |
|---|---|
| SD card | **Untrusted for confidentiality and integrity.** Ciphertext + structural checks; tamper-evident, not tamper-proof |
| BLE link | Trusted only after bonding + application-layer identity verification. Ciphertext frames cross it; manifests and chunks are verified end-to-end anyway |
| The phone | Trusted as the owner's device (it holds `K_root`). A hostile phone cannot forge a device manifest; it can withhold data or refuse to ack (availability only for the *dongle's* records, which remain on SD) |
| Any network | **Not used.** No Wi-Fi credentials, no LTE, no server. Nothing to MITM |
| OBD-II bus | Untrusted. Bounded read-only requests; responses treated as untrusted input (parsed defensively) |
| Vehicle electrical system | Untrusted (load dumps, brownouts). Recording must survive power loss; see vehicle-safety doc |

## 3. Protection layers (deliberately distinguished)

| Layer | Mechanism | What it does | What it does not do |
|---|---|---|---|
| **Transport security** | BLE bonding (passkey) + encrypted link; application-layer enrolment with pinned keys | Confidentiality and access control for the live channel | Does not protect data at rest on SD |
| **Recording encryption** | Per-frame XChaCha20-Poly1305 under `K_seg` = HKDF(`K_root`, vehicle_id salt, …) | A stolen SD card yields ciphertext | Does not stop a thief with the *running* device; does not replace physical security |
| **Cryptographic integrity** | Ed25519 manifest signature over `content_root` (domain-separated Merkle), CRC-32 chain + per-frame AAD | Anyone with the bytes can detect tearing/splicing; the key holder detects forgery | Does not prove the sensor told the truth |
| **Sensor quality** | Mandatory quality fields, sentinels, gap records | Downstream honesty about what is known | Not a security property |
| **Physical-extraction resistance** | Optional ESP32 flash/NVS encryption (gated) | Raises cost of chip-dumping keys | **Not enabled by default** (eFuse irreversibility); a determined attacker with chip-off tooling may extract flash. Stated plainly |

## 4. Threats and outcomes

| # | Threat | Outcome / mitigation |
|---|---|---|
| T1 | SD card stolen | Ciphertext only; `K_root` is not on the card. Structural metadata (sizes, timestamps in headers) is visible |
| T2 | Whole dongle stolen (running) | Same as T1 for existing data; future data is whatever the thief records. Owner resets ownership; a new enrolment invalidates old pins |
| T3 | Hostile/compromised phone | Cannot forge device manifests or frame tags. Can read metadata over a valid bond; can refuse to mirror (data stays safe on SD). Acknowledgements it signs are only valid for its own enrolment and are useless after ownership reset |
| T4 | Rogue BLE peer / pairing hijack | Access control is bond + enrolment pins; unauthenticated GATT writes are refused; no insecure fallback mode exists. Stale-bond state (phone restored/replaced) has an explicit recovery path (Cairn #44 lesson) rather than a lockout |
| T5 | Replay of old chunks/acks/manifests | Content addressing (SHA-256), manifest binding to device/vehicle/assignment/counter, acks naming exact content roots, monotonic device counter in NVS off-card |
| T6 | Torn write / power loss mid-write | Recovery scan at boot; torn tail discarded and *reported*; sealing is atomic-rename; segments never discarded because sealing failed |
| T7 | Malicious “mirror complete” pressure (someone deletes SD data claiming it was mirrored) | SD deletion is never triggered by transfer alone. Reclaim requires (a) user confirmation, (b) a signed ack naming the exact content, (c) local verification that the mirror holds it. Deletion bookkeeping is resumable and distinguishes intentional deletion from missing data |
| T8 | Lost/erased phone with the only `K_root` copy | SD originals become undecryptable. This is a key-management decision owned by the human ([open-questions.md](open-questions.md) Q2): backup/export of the escrow is explicit; Bealach will not silently hold a second escrow |
| T9 | Malicious OBD responses | Parsed defensively with bounded lengths; values rejected or flagged; no response can cause writes to the bus or firmware state beyond the allowlist path |
| T10 | Firmware tampering / evil maid | Without flash encryption/secure boot, reflashing is possible. Mitigation is version reporting in device-info and honest limitation; enabling eFuses is an explicit, approved, recovery-planned operation only |
| T11 | Denial of service on the bus (our own device) | Bounded rates, timeouts, backoff, and failure isolation so OBD trouble cannot create a request storm or starve sensors (Cairn #37/#42 lessons) |

## 5. Enrolment, identity, ownership

- **Enrolment** is explicit and local over BLE: discovery (AccessorySetupKit
  where available), bond establishment, application-layer identity exchange.
  The phone verifies the device identity by comparing a fingerprint shown on the
  device screen (or packaging) out of band; the device pins the owner phone's
  public key. Both sides record what they pinned.
- **Access** is encrypted and authenticated on every session; there is no
  pairing mode that leaves data readable without the bond.
- **Ownership reset** is an explicit destructive action: clears bonds, pinned
  keys, enrolment state and (separately, with its own confirmation) optionally
  the SD recordings. It is how a dongle changes hands; it is how a stale phone
  is removed.
- **Multiple phones** are out of v1 scope ([open-questions.md](open-questions.md)
  Q1); the contract reserves room for multiple pinned client keys.

## 6. Explicitly out of scope

- Nation-state adversaries, supply-chain attacks on the ESP32 fab, compromised
  iOS itself.
- Proving that recorded values are physically true (a spoofed GNSS or a lying ECU
  is detectable only insofar as quality fields and cross-checks allow).
- Anonymising data the owner keeps locally; Bealach protects data in transit and
  at rest on untrusted media, it does not police the owner's own disk.
