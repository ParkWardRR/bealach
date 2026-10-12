# BLE protocol v1: golden vectors

Byte-exact frames for the BLE companion protocol (`contracts/ble/v1/spec.md`),
replayed by the firmware's host test (`make -C firmware/cairn-v2/test/host ble-vectors`)
and by the iOS app's tests.

**Provenance.** Copied unchanged from
`ParkWardRR/cairn-companion-ios-esp32-obd2-gps-ble` `docs/golden-vectors.json` at
commit `3281e48` (the last commit that touched the file; sha256 `258ee2b2dcb0b328c2f236360e46e9638de1a437cba07c8f34478c8900634dd7`), where it was written from an
independent implementation of the spec. The firmware test used to read it from a sibling
checkout of that repository, which exists on a developer's machine and never on CI, so it
failed there. It lives here now so the test is self-contained. Until the iOS repo is
repointed (repo split, phase 7) the two copies must be kept identical; the copy here is the
one the firmware is held to.
