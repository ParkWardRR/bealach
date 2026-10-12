# Bealach Firmware

ESP-IDF C firmware for the Freematics ONE+ Model B.

**Status: scaffold only.** No code has been migrated yet. This directory will
hold the product firmware once Phase 1 migration begins (P1.2+).

## Planned layout

```text
lib/                    bealach_* modules (renamed from cairn_*)
src/                    application: boot, capture tasks, sensors, sealing
include/                config.h, board_config.h, secrets.h.example
engines/                engine YAML profiles (allowlisted OBD definitions)
test/host/              host-side C tests + Makefiles
third_party/
  freematics-base/      vendored Freematics co-processor protocol
THIRD-PARTY-NOTICES     provenance and license attribution
```

## Provenance

All carried code originates from
[cairn-esp32-device-firmware](https://github.com/ParkWardRR/cairn-esp32-device-firmware)
@ `ead3532`. See [THIRD-PARTY-NOTICES](THIRD-PARTY-NOTICES) and
[docs/migration-from-cairn.md](../docs/migration-from-cairn.md).
