# BLE v1

The dongle's GATT service. [`spec.md`](spec.md): phone GPS in, status and live data out.
[`offload.md`](offload.md): how sealed bundles leave a dongle that has no network (the phone
pulls them over BLE and uploads them), including the receipt gate.
[`device-info.md`](device-info.md): what a dongle is (firmware, engines, transports, boot timing)
and when it leaves BLE for a Wi-Fi slot. [`checkin.md`](checkin.md): the closed set of signed
instructions and the home trigger. Both are **draft**.

- **Vectors:** [`vectors/golden/`](vectors/golden/) (companion frames, written from an
  independent implementation) and [`vectors/offload/`](vectors/offload/) (offload frames,
  generated from the firmware's own protocol module and held there by a test) and
  [`vectors/device-info/`](vectors/device-info/) (device info, slot events, instructions: draft,
  from a Go reference in `tools/blevectors`).
- **Status:** the companion protocol is stable. The offload protocol is implemented by the
  firmware and a Go reference client and tested end to end; the phone app has not
  implemented it yet.
- **Support window:** for as long as firmware that serves it is supported.

## Negative cases

[`vectors/offload/`](vectors/offload/) scenarios that must be refused: `read_bad_arguments`,
`unknown_bundle`, `trip_active`, `mtu_too_small`, and on the receipt path
`put_receipt_wrong_key`, `put_receipt_no_pinned_key`, `put_receipt_bad_length`, `put_receipt_out_of_order`.
A refused receipt stores and deletes nothing. Those are produced by the firmware's own
module, not by `mkvectors`. The receipt bytes themselves (signature, signer, tampered root, version,
canonical form) are covered by the `receipt-*` vectors in [`format/v3`](../../format/v3/). The golden
companion frames have no negative cases yet.
