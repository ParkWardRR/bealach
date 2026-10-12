# Bealach iOS App

Swift/SwiftUI app for iOS 18+.

**Status: scaffold only.** No code has been migrated yet. This directory will
hold the product iOS app once Phase 1 migration begins (P1.5+).

## Planned layout

```text
Sources/
  BealachCore/          BLE client, mirror engine, models, history
  BealachRuntime/       Store (GRDB + encryption), auth, views
Tests/
  BealachCoreTests/     vector and unit tests
project.yml             XcodeGen config (iOS 18.0)
THIRD-PARTY-NOTICES     provenance and license attribution
```

## Provenance

All carried code originates from
[cairn-ios-companion-app](https://github.com/ParkWardRR/cairn-ios-companion-app)
@ `52f134e`. See [THIRD-PARTY-NOTICES](THIRD-PARTY-NOTICES) and
[docs/migration-from-cairn.md](../docs/migration-from-cairn.md).
