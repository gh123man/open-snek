# Changelog

All notable changes to this project are documented in this file.

## [2026-03-08]

### Fixed
- BLE DPI stage value parsing no longer drops the last stage when read payload length is short by one byte.
- Active-stage selection now maps correctly to the stage actually selected on-device during mouse-button stage cycling.
- Removed unstable BLE active-stage nudge/toggle write behavior that caused stage-value collapse in some multi-stage transitions.
- Poll-rate telemetry/control visibility now respects capability detection (hidden for Bluetooth when unavailable).
- App activation now promotes the process to a regular foreground app on launch/reopen so windows reliably come frontmost.
- Keyboard button-binding text entry now applies with a short debounce instead of normalizing on each keystroke, allowing stable direct typing.
- HID permission denial (`kIOReturnNotPermitted`) no longer hard-fails device discovery; app now continues with best-effort BLE discovery/fallback.
- Bluetooth read/apply paths no longer require an IOHID handle, so BLE-only operation can continue when HID access is blocked.
- BLE runtime errors now report explicit CoreBluetooth state failures (unauthorized/powered-off/unsupported) instead of generic timeouts.

### Changed
- `OpenSnekMac` and `OpenSnekProbe` now decode BLE active stage using stage-id mapping from the current payload entries.
- BLE stage-table writes in Swift now preserve stage IDs from the current snapshot to keep UI stage selection aligned with hardware cycling.
- BLE protocol documentation now distinguishes protocol observations from per-client implementation behavior.
- `OpenSnekMac` UI is split into focused components (`ContentView`, `DeviceSidebarView`, `DeviceDetailView`, `UIPrimitives`) instead of a single monolithic view.
- Top-card lighting UX now uses integrated in-window controls (large brightness slider + inline color controls) instead of detached native color panel behavior.
- DPI telemetry now displays a single active DPI scalar value.
- Button remapping now uses a friendly-name table with per-button mapping summaries.
- Device metadata (name/protocol/battery) now renders as a standalone header above controls, with lighting moved into its own dedicated card.
- Redundant top stats strip and all auto-apply helper text were removed for a cleaner control-first layout.
- Button remap rows now right-align mapping menus and remove duplicate mapping summary text.
- Window/detail sizing is more fluid: smaller minimum window size plus adaptive split-view column widths.
- DPI stage editor now uses modern add/remove controls and stage-color accents (1 red, 2 green, 3 blue, 4 teal, 5 yellow).
- DPI stage mode toggle was removed; stage count now directly drives single-stage vs multi-stage behavior (1..5).

### Added
- Hardware BLE DPI reliability test (`OPEN_SNEK_HW=1 swift test --package-path OpenSnekMac --filter HardwareDpiReliabilityTests`).
- Regression-focused validation workflow in `README.md`, `OpenSnekMac/README.md`, and `AGENTS.md` including CLI, hardware, and log-based checks.
- Sleep-timeout power-management control in UI plus USB (`07:83/03`) and BLE (`05 84/05 04`) bridge read/write plumbing.
- BLE lighting-frame color hydration path on startup (`10 84 00 00`) plus persisted per-device fallback when firmware does not return payload for this read.
- macOS app-bundle build scripts: `OpenSnekMac/scripts/build_macos_app.sh` and `OpenSnekMac/scripts/run_macos_app.sh` for dock/icon/focus-correct launches outside `swift run`.
- Xcode-distribution scaffold for macOS: `OpenSnekMac/project.yml` (XcodeGen spec), generated `OpenSnekMac/OpenSnekMac.xcodeproj`, and `OpenSnekMac/scripts/generate_xcodeproj.sh`.
- Native app asset catalog + AppIcon set under `OpenSnekMac/App/Resources/Assets.xcassets`.
- `OpenSnekMac/scripts/generate_appiconset.sh` to reproducibly regenerate all macOS app icon sizes from a single generated source.
