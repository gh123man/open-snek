# Changelog

All notable changes to this project are documented in this file.

## [2026-03-08]

### Fixed
- Closing the main window with the macOS close button now terminates the app instead of leaving a background process running.
- BLE DPI stage value parsing no longer drops the last stage when read payload length is short by one byte.
- Active-stage selection now maps correctly to the stage actually selected on-device during mouse-button stage cycling.
- Removed unstable BLE active-stage nudge/toggle write behavior that caused stage-value collapse in some multi-stage transitions.
- Poll-rate telemetry/control visibility now respects capability detection (hidden for Bluetooth when unavailable).
- App activation now promotes the process to a regular foreground app on launch/reopen so windows reliably come frontmost.
- Keyboard button-binding text entry now applies with a short debounce instead of normalizing on each keystroke, allowing stable direct typing.
- HID permission denial (`kIOReturnNotPermitted`) no longer hard-fails device discovery; app now continues with best-effort BLE discovery/fallback.
- Bluetooth read/apply paths no longer require an IOHID handle, so BLE-only operation can continue when HID access is blocked.
- BLE runtime errors now report explicit CoreBluetooth state failures (unauthorized/powered-off/unsupported) instead of generic timeouts.
- BLE button remap UI now guards unsupported Bluetooth slot writes and uses capture-backed slot `0x60` for the DPI-cycle side control.
- BLE button remap now supports capture-backed DPI-cycle slot `0x60` writes and default-restore semantics (action `0x06`, `p0=0x0601`).
- BLE button remap no longer exposes slot `6` (`Hypershift/Boss key`) in the UI; runtime probes now document slot `6` as rejected (`status 0x03`) on the mapped BLE vendor key family.
- Lighting profile apply on Bluetooth no longer hard-fails when HID effect writes are unavailable; app now uses best-effort BLE fallback paths (`static`, `off`, `spectrum`) and keeps state/cache consistent.
- Persisted lighting state now re-applies automatically after reconnect/discovery instead of waiting for a fresh manual UI edit.

### Changed
- Replaced the macOS app icon artwork in `AppIcon.appiconset` with the new Open Snek icon and cropped out the black background letterboxing from the source image.
- `OpenSnekMac/scripts/build_macos_app.sh` now automatically uses `AppIcon.appiconset/icon_512x512@2x.png` as the default app icon source instead of falling back to the generic macOS icon.
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
- Button remap labels now use user-facing names aligned to side-control order: slot `4` = `Back Button`, slot `5` = `Forward Button`, plus BLE slot `0x60` labeled `DPI Cycle`.
- BLE button UI now shows capture-backed writable slots (`1..5` + `0x60`) and labels slot `0x60` as `DPI Cycle`.
- Slot `6` (`Hypershift/Boss key`) support attempt on BLE was reverted after capture/runtime validation; the UI now hides slot `6` pending a decoded writable command path.
- BLE button remap now includes wheel-button slots `0x09`/`0x0A` (Scroll Up/Down) and exposes capture-backed scroll-up/scroll-down action mappings in both CLI and app payload builders.
- BLE button remap now supports turbo payload encoding on Bluetooth for mouse actions (`action 0x0E`) and keyboard bindings (`action 0x0D`) with UI toggle + rate control.
- Turbo slider is labeled as raw rate (`1` fastest, `255` slowest).
- Turbo control visibility now follows binding mode: hidden for `Default`, shown below the dropdown for non-default remaps.
- `Default` button remaps now restore per-slot native actions (left/right/middle/back/forward/scroll up/scroll down) instead of writing the generic `p0=0x0000` fallback.
- Turbo slider now uses Synapse-style `1..20` presses/second in the UI, with internal conversion to the existing raw BLE rate field.
- On fresh launch, button remap pickers now default to `Default` (neutral state) instead of pre-selecting slot action labels when no binding state has been read from hardware.
- Button remap selections are now cached per-device in UserDefaults using the mouse identifier, then restored on reconnect/launch (including turbo toggle/rate and keyboard key).
- Button remap rows now display friendly names without numeric slot prefixes.
- Button remap action label `Clear Layer` is now user-facing `Disabled`.
- Lighting brightness slider now uses a `0..100%` UI scale (mapped to the same raw `0..255` transport values).
- Slider controls now use continuous tracks without discrete step marker dots; value snapping is handled in setters where needed.
- Lighting card now exposes full scroll LED profile families (off, static, spectrum, wave, reactive, pulse random/single/dual) with per-profile controls (direction/speed/colors).
- Lighting profile state (mode + wave direction + reactive speed + secondary color) is now cached per device in UserDefaults and restored on reconnect/launch.
- Lighting/button persistence keys now use a stable per-device identity (`serial` when available, otherwise `VID:PID:transport`) with legacy-key fallback for previously cached values.
- Lighting profile picker has been temporarily removed from OpenSnekMac UI; app now exposes static lighting controls only while BLE effect parity remains unreliable on current macOS BT HID paths.

### Added
- Hardware BLE DPI reliability test (`OPEN_SNEK_HW=1 swift test --package-path OpenSnekMac --filter HardwareDpiReliabilityTests`).
- Regression-focused validation workflow in `README.md`, `OpenSnekMac/README.md`, and `AGENTS.md` including CLI, hardware, and log-based checks.
- Sleep-timeout power-management control in UI plus USB (`07:83/03`) and BLE (`05 84/05 04`) bridge read/write plumbing.
- BLE lighting-frame color hydration path on startup (`10 84 00 00`) plus persisted per-device fallback when firmware does not return payload for this read.
- macOS app-bundle build scripts: `OpenSnekMac/scripts/build_macos_app.sh` and `OpenSnekMac/scripts/run_macos_app.sh` for dock/icon/focus-correct launches outside `swift run`.
- Xcode-distribution scaffold for macOS: `OpenSnekMac/project.yml` (XcodeGen spec), generated `OpenSnekMac/OpenSnekMac.xcodeproj`, and `OpenSnekMac/scripts/generate_xcodeproj.sh`.
- Native app asset catalog + AppIcon set under `OpenSnekMac/App/Resources/Assets.xcassets`.
- `OpenSnekMac/scripts/generate_appiconset.sh` to reproducibly regenerate all macOS app icon sizes from a single generated source.
