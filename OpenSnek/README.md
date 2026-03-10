# OpenSnek

Pure Swift macOS frontend for `open-snek`.

Official builds use the latest Xcode/macOS SDK. Minimum supported macOS version: macOS 14.

Device onboarding and capture interpretation live in:

```text
../CONTRIBUTING.md
```

## Targets

- `OpenSnekCore`: shared domain models, device profiles, button/layout helpers, persistence keys
- `OpenSnekProtocols`: shared BLE vendor framing and USB HID report helpers
- `OpenSnekHardware`: shared repository/driver abstractions for hardware-facing code
- `OpenSnekAppSupport`: app-only support services such as apply coordination and preference persistence
- `OpenSnek`: SwiftUI desktop app
- `OpenSnekProbe`: Swift CLI for BLE DPI read/set/cycle verification on top of the shared protocol/report helpers

## App Architecture

- `Sources/OpenSnekCore/`
  - shared device/state models
  - hybrid device-profile registry (`Basilisk V3 X` USB + BLE today)
  - button binding/turbo helpers and persistence key builders
- `Sources/OpenSnekProtocols/`
  - `BLEVendorProtocol`: BLE framing, key map, and DPI payload parsing/building
  - `USBHIDProtocol`: shared HID report encoding/CRC/response validation
- `Sources/OpenSnekHardware/`
  - shared repository/driver abstractions for bridge migration
  - shared `USBHIDControlSession` and `BLEVendorTransportClient` transport clients
- `Sources/OpenSnekAppSupport/`
  - `ApplyCoordinator`: latest-wins patch coalescing helper
  - `DevicePreferenceStore`: extracted `UserDefaults` persistence for lighting/button state
- `Sources/OpenSnek/Bridge/`
  - `BridgeClient`: repository-compatible bridge shell and discovery/orchestration
  - `BridgeClient+USB`: USB HID state/apply path
  - `BridgeClient+Bluetooth`: BLE vendor state/apply path
- `Sources/OpenSnek/Services/`
  - `AppState`: top-level UI state model composed with extracted apply/persistence helpers
  - `AppLog`: runtime file + OSLog logger
- `Sources/OpenSnek/UI/`
  - `ContentView`: shell + device refresh/fast-poll timers
  - `DeviceSidebarView`: device list and app utility actions
  - `DeviceDetailView`: hero card, DPI/poll/power cards, and button mapping table
  - `UIPrimitives`: shared cards, pills, stat blocks, and color helpers
- `App/`
  - `Info.plist`: app metadata/permissions for Xcode builds
  - `Resources/Assets.xcassets`: app icon catalog
- `project.yml`: XcodeGen spec for reproducible `OpenSnek.xcodeproj`

## Runtime Guarantees

- BLE vendor transactions are serialized per connection.
- Auto-apply edits are coalesced (latest-wins) to prevent write backlog.
- Refresh and fast-poll responses are revision-gated to drop stale results.
- Invalid DPI payloads are ignored (with retry) to avoid UI snapback on transient malformed frames.
- Device discovery now resolves profile metadata up front, including button layout and lighting-effect support per transport.

## Build / Run

From the repo root, the shortest path is:

```bash
./run.sh
```

To launch the current app bundle without rebuilding:

```bash
./run.sh --no-build
```

Direct app-package workflows:

```bash
swift run --package-path OpenSnek OpenSnek
```

For full app behavior (dock icon, proper activation/focus, keyboard text-entry reliability), run the app bundle path:

```bash
./OpenSnek/scripts/run_macos_app.sh
```

For distribution/signing workflows, use the generated Xcode project:

```bash
./OpenSnek/scripts/generate_xcodeproj.sh --open
```

Regenerate app icon assets (if branding changes):

```bash
./OpenSnek/scripts/generate_appiconset.sh
```

CLI Xcode validation:

```bash
xcodebuild -project OpenSnek/OpenSnek.xcodeproj -scheme OpenSnek -destination 'platform=macOS' build
xcodebuild -project OpenSnek/OpenSnek.xcodeproj -scheme OpenSnek -destination 'platform=macOS' test
xcodebuild -project OpenSnek/OpenSnek.xcodeproj -scheme OpenSnekProbe -destination 'platform=macOS' build
```

Bundle build only:

```bash
./OpenSnek/scripts/build_macos_app.sh --configuration release
```

DMG release build and notarization:

```bash
./OpenSnek/scripts/build_release_dmg.sh --version 0.1.0 --build-number 1 --team-id '<APPLE_TEAM_ID>' --notary-key-path /path/to/AuthKey_XXXX.p8 --notary-key-id '<KEY_ID>' --notary-issuer-id '<ISSUER_ID>'
```

Release automation and GitHub secret setup:

```text
docs/release/DMG_RELEASE.md
```

Run the existing `.dist` app bundle without rebuilding (preserves signature/TCC grants by default):

```bash
./OpenSnek/scripts/run_macos_app.sh
```

Output:

```text
OpenSnek/.dist/Open Snek.app
```

```bash
swift test --package-path OpenSnek
```

## Logs

Runtime app logs:

```text
~/Library/Logs/OpenSnek/open-snek.log
```

## Permissions

- If you see `IOHIDManagerOpen failed (-536870174)` in logs, macOS denied HID access (`kIOReturnNotPermitted`).
- Grant access in `System Settings > Privacy & Security > Input Monitoring` for `Open Snek`.
- Reset Bluetooth permission prompt if needed:

```bash
tccutil reset Bluetooth io.opensnek.OpenSnek
```

## Probe CLI

### Read current BLE DPI

```bash
swift run --package-path OpenSnek OpenSnekProbe dpi-read
```

### Set DPI and verify readback

```bash
swift run --package-path OpenSnek OpenSnekProbe dpi-set --values 1600,6400 --active 2
```

### Stress cycle values

```bash
swift run --package-path OpenSnek OpenSnekProbe dpi-cycle --sequence '1200,6400;2600,6400;3200,6400' --loops 20 --active 2
```

## Hardware Reliability Loop (CLI)

Run the app bridge path in a repeatable CLI test loop (skips unless enabled):

```bash
OPEN_SNEK_HW=1 swift test --package-path OpenSnek --filter HardwareDpiReliabilityTests
```

This exercises repeated BLE DPI stage apply/readback and requires stable convergence
across multiple consecutive reads for each step.

## Stage Selection Validation (Manual + CLI)

Use this when debugging UI-stage selection mismatch against mouse stage-button cycling.

```bash
swift run --package-path OpenSnek OpenSnekProbe dpi-set --values 1000,2000,3000 --active 1 --verify-retries 8 --verify-delay-ms 120
swift run --package-path OpenSnek OpenSnekProbe dpi-set --values 1000,2000,3000 --active 3 --verify-retries 8 --verify-delay-ms 120
swift run --package-path OpenSnek OpenSnekProbe dpi-read
```

Expected final readback: `active=3 count=3 values=[1000, 2000, 3000]`.

Then validate in app:
- set 3 unique stage values
- press mouse stage button repeatedly
- verify highlighted stage in UI matches the stage value currently applied on mouse
- verify wraparound stage 3 -> stage 1 is correct

## UI Validation Checklist

Use this after UI/control changes:

1. Poll visibility:
- Connect over Bluetooth and verify poll-rate stat/card is hidden.
- Connect over USB/dongle and verify poll-rate stat/card is shown and writable.

2. Power management:
- Confirm `Power Management` card appears.
- Change sleep timeout and confirm write/readback in logs (`sleep=` patch + updated state).

3. Lighting hero controls:
- Confirm brightness slider is in the top hero card.
- On Bluetooth, confirm inline color controls apply without opening detached color windows.

4. Button mapping table:
- Confirm table uses friendly button names.
- Change a mapping and confirm apply log includes `button(slot=...,kind=...)`.

## BLE DPI Guardrails

- parse stage reads by declared count even if payload length is short by one byte
- decode active stage via payload stage-id mapping
- preserve stage IDs on writes to keep hardware stage-button cycling aligned with UI
- avoid active-stage “nudge/toggle” write sequences
