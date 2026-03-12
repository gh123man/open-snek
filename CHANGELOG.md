# Changelog

All notable changes to this project are documented in this file.

## [2026-03-12]

### Fixed
- Removed the transient `Stage x -> y DPI applied` status message because the live UI already reflects successful DPI changes directly.
- The `Menu bar icon` preference now keeps an upgrade user's stored choice intact; only installs without a saved preference pick up the default-on behavior.
- Choosing `Quit` from the menu bar service now only ends the current background session; it no longer silently turns off `Menu bar icon` or clears `Start at login`.
- Toggling `Launch menu bar service at startup` no longer blocks the UI or starts a second service/app instance immediately; it now only updates the launch-agent registration for the next login, while the separate `Enable menu bar service` toggle continues to control the current session.
- Restored the clear full-window title bar styling after the title bar icon removal accidentally dropped the shared window chrome configurator along with the accessory view.
- Removed the experimental main-window title bar icon, and the menu bar service `Settings…` action now uses SwiftUI's settings scene opener so it reliably opens the app settings window again.
- The menu bar service now reuses an already-open full app window when you choose `Show Open Snek`, bringing the existing app to the foreground instead of spawning duplicate full app instances.
- The menu bar service now publishes a real localhost IPC endpoint instead of trying to serialize an `NSXPCListenerEndpoint` into defaults, which restores shared backend ownership when the main window and background service are open together and prevents dual-process USB contention.
- When the background service is enabled, the full app now follows a service-published snapshot feed instead of polling the service for steady-state device/state updates, so hardware polling stays service-owned and both UIs converge from the same live snapshot stream.
- Remote UI clients now send a lightweight active-presence heartbeat to the service so the service keeps its faster interactive polling cadence while the full window is open, instead of dropping back to idle timing.
- The macOS app now keeps live telemetry and DPI/apply flows attached to the currently selected physical mouse even when the runtime device ID shifts during polling, avoiding `Poll Delayed` UI freezes and dropped apply/readback updates after recent multi-device safety changes.
- The full app now adopts an already-running menu bar service as its hardware backend even if local service preferences are stale, preventing dual-process USB/HID contention when the compact widget and main window are open at the same time.

### Changed
- The menu bar widget now includes a device picker when multiple supported mice are connected, and service-published apply snapshots now move both UIs to the last device that changed so the compact widget and full app stay focused on the same mouse.

## [2026-03-11]

### Added
- USB device-profile support for Razer Basilisk V3 Pro (`0x00AB`) in the shared Swift registry and macOS app, with the observed 3-profile / 3-zone layout, validated wheel-tilt slots, and documented fixed clutch/profile controls.
- `OpenSnekProbe` USB commands now accept `--pid 0x....` so bring-up and raw probes can target one attached Razer USB device without hopping between multiple mice.

### Fixed
- The Basilisk V3 Pro USB profile now exposes the validated clutch / DPI-clutch slot (`0x0F`) as an editable button with its observed native restore block (`06 05 05 01 90 01 90`).
- The button-binding UI now exposes `DPI Clutch` as a V3 Pro-only USB remap option after probe validation showed the clutch payload can be assigned to other writable buttons, not just the native clutch slot.
- `DPI Clutch` is now a configurable V3 Pro-only USB action in the app and probe CLI, with the held DPI value encoded into the clutch payload instead of being fixed at the observed 400-DPI default.
- Basilisk V3 Pro profile-button probing now documents the observed remap path on slot `0x6A` but keeps it hidden in the shipped UI because repeated USB write/readback cycles were not yet stable enough to trust.
- Extended Basilisk USB button hydration now treats Basilisk V3 Pro `0x02:0x8C` reads like the other 35K-style offset layout while keeping unsupported V3 Pro slots out of the shipped visible/writable profile.
- Restoring the Basilisk V3 35K top DPI button now preserves its observed default USB payload (`04 02 0F 7B 00 00 00`) instead of falling back to the generic DPI-cycle block.

### Changed
- Fresh installs now default the menu bar icon to enabled, and the settings labels now read `Menu bar icon` and `Start at login` to match the intended behavior more closely.
- The menu bar status glyph and the full app title bar now use the provided `snek-menu.png` branding at a smaller fitted size, and local `.dist` bundle builds now copy that resource into the app so the icon shows up outside Xcode builds.
- Standardized app-icon generation around `OpenSnek/Branding/AppIcon-master.png` so the checked-in asset catalog, local `.app` bundle builds, and DMG artwork all use the same source image.
- Reduced the exported icon's optical size slightly to give the Dock icon more breathing room on macOS versions where the previous full-bleed artwork read as oversized.
- The menu bar widget now uses a custom status-item glyph with compact live-DPI text, clearer action labels, battery icon + percentage, and larger DPI stage hit targets in both the compact widget and the full app; the redundant manual refresh row and misleading chevron affordances were removed.

## [2026-03-10]

### Added
- An optional menu bar background service for the macOS app, including a compact current-stage DPI widget with battery/status readout, quick refresh, and a fast path to launch the full windowed app while sharing the same backend owner.
- Background-service settings in the macOS app for enabling the widget process and launching it automatically at startup, plus service-side logs under `~/Library/Logs/OpenSnek/`.
- USB device-profile support for Razer Basilisk V3 35K (`0x00CB`) in the macOS app and shared Swift support layers, including its own button layout metadata and three-zone USB lighting IDs.
- `OpenSnekProbe usb-raw`, a generic USB HID feature-report inspector for new-device bring-up and protocol verification.
- Shared button-slot access metadata now distinguishes editable, protocol-read-only, and software-read-only controls so future device bring-up can document non-remappable buttons explicitly.
- A per-device Diagnostics sheet in the macOS app, including generic selected-device views, with a copyable text dump of device identity, support profile, topology, capabilities, live state, and current app warnings for bug reports.
- A GitHub-ready diagnostics payload flow in Settings, plus a bug-report issue template that tells users how to generate and paste that payload.

### Fixed
- Bluetooth fallback discovery no longer aliases every connected Razer BLE peripheral to the supported Basilisk V3 X HyperSpeed profile when HID permission is denied; unsupported BLE devices now stay generic/unsupported until an exact Bluetooth profile match is added.
- Unsupported Razer USB devices no longer get hidden behind the generic unsupported screen; Open Snek now allows USB probing on unknown Razer mice, shows a warning that support is partial, and only exposes USB controls that responded during live capability probing. Unsupported Bluetooth devices remain gated to the explicit supported-device list.
- Bluetooth vendor exchanges now target the selected device by peripheral name instead of whichever connected Razer BLE peripheral CoreBluetooth returns first, fixing supported-device failures when a supported and unsupported Bluetooth device are connected at the same time.
- Device switching now swaps immediately to the selected device's cached state and ignores stale async refresh/apply results from the previously selected device, reducing DPI/control lag when multiple mice are connected.
- USB lighting apply/readback on Basilisk V3 35K now targets all three validated matrix LED zones (`0x01` scroll wheel, `0x04` logo, and `0x0A` underglow) instead of only the wheel zone.
- USB lighting effect encoding now matches the OpenRazer-documented matrix payloads for `off`, `spectrum`, `wave`, `reactive`, and breathing variants, fixing broken USB profile selections and removing an incorrect wave/spectrum mapping.
- USB button readback normalization now handles the Basilisk V3 35K `0x02:0x8C` response layout, which differs from the Basilisk V3 X slot echo shape and caused clutch/default blocks to be misparsed.
- USB button support now preserves and restores the Basilisk V3 35K top DPI-button default payload on slot `0x60`, and the app exposes the extra 35K-only USB slots for the wheel-tilt and DPI-button controls while keeping fixed-only special buttons labeled separately.
- Basilisk V3 35K button-slot hydration now rejects stale `0x02:0x8C` replies for the wrong echoed slot, and the shared 35K button layout now includes the validated wheel-tilt slots (`0x34`, `0x35`) with cleaned-up control labels.
- The button-binding UI now hides fixed-only 35K controls, and USB button bindings expose an explicit `DPI Cycle` action that can be assigned to any writable button while the 35K DPI button restores to a working DPI-cycle default.
- The USB lighting card now filters effect choices per device capability, keeps the original background treatment for `All Zones`, and only uses the multi-zone accent gradient when a specific static USB zone is selected.
- Open Snek now reads the Basilisk V3 35K onboard profile summary on USB, exposes multi-profile UI only on devices that actually advertise multiple onboard profiles, and scopes USB button remap reads/writes to the selected stored profile instead of hard-coding profile 1.
- Device/profile docs now explicitly record the Basilisk V3 35K software-read-only controls: sensitivity clutch (`0x0F` / report-4 `0x51`) and profile button (`0x6A` / report-4 `0x50`), plus scroll-mode toggle (`0x0E`) as protocol-read-only.
- Shared button metadata now also marks the Basilisk V3 X HyperSpeed Bluetooth Hypershift/sniper control (`slot 0x06`) as software-read-only so it appears in the unsupported-buttons footnote with the right explanation.
- The non-functional onboard-profile switcher card has been removed from the macOS UI until an actual active-profile switching path is decoded for supported devices.
- The button remap card now shows a compact per-device footnote for hidden unsupported buttons, including why each control is currently protocol-read-only or software-read-only.
- Python USB tooling now recognizes Basilisk V3 35K (`0x00CB`) and mirrors multi-zone USB lighting writes across all validated LED IDs.

### Changed
- App-level polling is now runtime-owned instead of view-timer-owned, allowing the full app to keep its current cadence while the background widget drops to a slower idle cadence and only boosts polling when the menu is open or a DPI change was just applied.
- Unsupported-button footnotes now use plain-language UI copy instead of protocol jargon, including the Basilisk V3 X HyperSpeed sniper/Hypershift note.
- The polling-rate and scroll-control cards now align labels on the left and controls on the right to match the rest of the app.
- The empty-state supported-devices list now uses smaller inline USB/BT pills so more devices fit cleanly in one row.

## [2026-03-09]

### Changed
- Official app builds and GitHub macOS CI/release jobs now use the latest Xcode/macOS SDK while keeping the app deployment target at macOS 14 for backward compatibility on older supported systems.
- Runtime logging now has user-selectable levels with a macOS Settings page; the default level is now `Warning` to keep normal logs concise, while `Info` and `Debug` remain available for reproducing bug reports.
- Reorganized the repo around the macOS app: protocol/reference docs now live under `docs/`, supported Python tooling now lives under `tools/python/`, and the root entry point is now a zero-arg `./run.sh`.
- Split the Swift package into shared targets: `OpenSnekCore`, `OpenSnekProtocols`, `OpenSnekHardware`, and `OpenSnekAppSupport`, with the app and probe consuming those shared layers incrementally instead of keeping all architecture in the app target.
- Moved shared Swift domain models, device-profile metadata, button/turbo helpers, persistence key generation, BLE vendor framing, and USB HID report helpers out of `OpenSnek` local sources and into shared library targets.
- Rewrote `docs/protocol/BLE_PROTOCOL.md` around the Swift implementation as the source of truth, with complete transaction examples for every currently supported BLE vendor feature and a clearer split between wire-format rules and OpenSnek client policy.
- Device discovery in the macOS app now attaches resolved profile metadata to `MouseDevice`, including per-transport button layout and advanced-lighting support, so UI/app-state logic can rely on device capabilities instead of raw transport string branches.
- `AppState` now delegates patch coalescing and preference persistence to extracted support services (`ApplyCoordinator`, `DevicePreferenceStore`) instead of owning that logic directly.
- `OpenSnekProbe` now reuses shared BLE vendor and USB HID protocol helpers instead of maintaining fully separate copies of those framing/report builders.
- Bluetooth capture review now documents the shared BLE selector/frame lighting path (`10 03 = 0x00000008`, then repeated `10 04` frames), but OpenSnek keeps Bluetooth app lighting static-only for now because those advanced profiles appear to require software-driven streaming and are not yet shippable.

### Added
- Shared device-profile registry for the validated Basilisk V3 X HyperSpeed family (`0x00B9` USB / `0x00BA` BLE) with explicit button-layout metadata.
- Unit tests for shared device-profile resolution/persistence keys and extracted apply coordination.
- GitHub Release DMG automation: tag-driven macOS workflow, Xcode archive/export release script, notarization/stapling path, and release credential setup docs.
- Pull-request CI workflow that runs the Swift package test suite on macOS.
- Root contribution guide covering new-device onboarding, capture interpretation, and validation expectations.

### Fixed
- Fixed a USB DPI-stage parsing regression introduced during the transport-layer split: stage-table reads were decoded one byte off, which corrupted stage values, broke on-mouse stage cycling, and could make the app collapse USB devices into the wrong stage count or single-stage mode.
- Release DMGs now preserve the macOS asset catalog and app icon in exported `Open Snek.app` bundles.
- Release packaging now produces a styled drag-to-Applications DMG instead of a plain file-drop image.
- USB apply flows no longer fail immediately on transient post-write telemetry drops; readback now retries with short backoff and falls back to projected cached state when writes succeeded but immediate readback is temporarily unavailable.
- USB state reads now probe live DPI first and fail fast on non-responsive HID interfaces instead of running full telemetry sweeps on dead handles, removing long timeout storms that caused delayed/intermittent stage switching.
- USB transaction candidate handling now sticks to the last known-good transaction ID for normal traffic, reducing repeated per-command transaction scanning that amplified timeout latency on unstable sessions.
- USB DPI stage writes now preserve/report stage IDs and write active stage as the device stage-ID token (not raw UI index), fixing active-stage `0` timeout failures and off-by-one stage mapping during stage-count edits.
- Transient USB stage-table read failures no longer collapse state to single-stage fallback; cached stage values remain stable, and fast DPI polling now also runs on USB for quicker on-mouse stage-switch UI updates.
- Fast DPI refresh now preserves non-DPI USB telemetry fields (including low-battery threshold and scroll controls), fixing card flicker caused by transient nil resets during high-frequency stage polling.
- USB button remapping on Basilisk V3 X HyperSpeed USB (`0x00B9`) now uses validated class `0x02` button-function commands (`0x0C` write / `0x8C` read) with correct 7-byte function-block encoding; remap writes/readback now succeed in hardware tests.
- USB startup hydration now reads button assignments from device readback (`0x02:0x8C`) before cache fallback, so launch/reconnect reflects real on-device button mappings instead of stale local `UserDefaults` values.

### Changed
- The macOS app now checks GitHub Releases on launch and shows a sidebar `New Version Available` button when a newer published release exists.

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
- USB HID feature-report framing in `OpenSnek` now matches device expectations (90-byte payload without extra leading byte), fixing missing USB telemetry/control cards where the app previously read request-echo frames (`status 0x00`) instead of real responses.
- USB state readback now evaluates all HID handle candidates and selects the highest-telemetry interface (DPI/poll/lighting weighted), avoiding partial USB sessions that only surfaced timeout/remap controls.
- Refresh/apply diagnostics are now explicit in-app: repeated read failures and partial USB telemetry states are surfaced as visible warnings/errors instead of being silently masked behind cache.
- USB permission diagnostics UI no longer renders duplicate overlapping red banners; input-monitoring failures now collapse to a single callout with host identity context.
- USB permission diagnostics now include stale-TCC guidance (`tccutil reset ListenEvent`) for local ad-hoc builds where macOS reports code-requirement mismatch despite a visible prior grant.
- USB core controls (DPI, polling, lighting) now remain visible for supported USB devices even when readback is temporarily partial; the UI surfaces a warning that values may be stale instead of hiding those cards.
- USB refresh now stops probing alternate HID interfaces once the preferred interface exposes DPI control telemetry, preventing 20s+ polling stalls that blocked applies and delayed UI updates.
- USB single-stage DPI writes now use a two-step persist/apply flow with readback retries, and HID response polling allows longer stale-frame drain windows, improving DPI write/readback convergence when a one-stage profile is configured.
- USB DPI stage editing is restored for USB mode (multi-stage count + active-stage selection), with active-stage readback now resolved from live DPI when stage index telemetry lags.
- USB button-binding UI now exposes `DPI Cycle` slot `96` (slot `6` remains hidden), and slot `96` default restore uses the capture-backed DPI-cycle action payload.

### Changed
- Replaced the macOS app icon artwork in `AppIcon.appiconset` with the new Open Snek icon and cropped out the black background letterboxing from the source image.
- `OpenSnek/scripts/build_macos_app.sh` now automatically uses `AppIcon.appiconset/icon_512x512@2x.png` as the default app icon source instead of falling back to the generic macOS icon.
- `OpenSnek/scripts/build_macos_app.sh` now supports stable signing identities (`--sign-identity auto|adhoc|none|<identity>`) and auto-detects a local Apple signing cert when available, reducing TCC/Input Monitoring permission churn across rebuilds.
- `OpenSnek/scripts/build_macos_app.sh` now supports `--sign-identity preserve` and auto-reuses an existing app bundle signature in `auto` mode when available, helping keep TCC grants stable across rebuilds.
- `OpenSnek/scripts/build_macos_app.sh` `auto` signing now ignores existing ad-hoc signatures and prefers a real local signing identity when available, reducing TCC permission churn on rebuild.
- `OpenSnek/scripts/build_macos_app.sh` now applies a stable designated requirement when ad-hoc signing (`identifier "<bundle-id>"`) so Input Monitoring grants can persist across local rebuilds.
- `OpenSnek/scripts/run_macos_app.sh` continues to skip rebuilds unless explicitly requested; when rebuilding, it now defaults signing mode to `auto`.
- `OpenSnek` and `OpenSnekProbe` now decode BLE active stage using stage-id mapping from the current payload entries.
- BLE stage-table writes in Swift now preserve stage IDs from the current snapshot to keep UI stage selection aligned with hardware cycling.
- BLE protocol documentation now distinguishes protocol observations from per-client implementation behavior.
- `OpenSnek` UI is split into focused components (`ContentView`, `DeviceSidebarView`, `DeviceDetailView`, `UIPrimitives`) instead of a single monolithic view.
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
- Lighting profile picker has been temporarily removed from OpenSnek UI; app now exposes static lighting controls only while BLE effect parity remains unreliable on current macOS BT HID paths.
- OpenSnek lighting controls are now transport-scoped: USB exposes full effect/profile controls again, while Bluetooth remains static-only (brightness + color) to avoid BLE regressions.
- OpenSnek USB apply/readback now includes device mode (`00:84/04`), low-battery threshold (`07:81/01`), and scroll controls (`02:94/14`, `02:96/16`, `02:97/17`) with per-device capability probing.
- Unsupported USB controls are now hidden in the UI instead of shown disabled (device mode, low-battery threshold, and each individual scroll control).
- USB color-only writes now use the static matrix-effect path (`0x0F:0x02`) so RGB color edits apply reliably on USB.

### Added
- Hardware BLE DPI reliability test (`OPEN_SNEK_HW=1 swift test --package-path OpenSnek --filter HardwareDpiReliabilityTests`).
- Hardware USB button-remap test harness (`OPEN_SNEK_HW=1 swift test --package-path OpenSnek --filter HardwareUSBButtonRemapTests`) with write/readback/restore flow.
- Hardware USB startup hydration test harness (`OPEN_SNEK_HW=1 OPEN_SNEK_USB=1 swift test --package-path OpenSnek --filter HardwareUSBStartupHydrationTests`) that seeds conflicting cache and verifies startup rehydration prefers device state.
- Regression-focused validation workflow in `README.md`, `OpenSnek/README.md`, and `AGENTS.md` including CLI, hardware, and log-based checks.
- Sleep-timeout power-management control in UI plus USB (`07:83/03`) and BLE (`05 84/05 04`) bridge read/write plumbing.
- BLE lighting-frame color hydration path on startup (`10 84 00 00`) plus persisted per-device fallback when firmware does not return payload for this read.
- macOS app-bundle build scripts: `OpenSnek/scripts/build_macos_app.sh` and `OpenSnek/scripts/run_macos_app.sh` for dock/icon/focus-correct launches outside `swift run`.
- Xcode-distribution scaffold for macOS: `OpenSnek/project.yml` (XcodeGen spec), generated `OpenSnek/OpenSnek.xcodeproj`, and `OpenSnek/scripts/generate_xcodeproj.sh`.
- Native app asset catalog + AppIcon set under `OpenSnek/App/Resources/Assets.xcassets`.
- `OpenSnek/scripts/generate_appiconset.sh` to reproducibly regenerate all macOS app icon sizes from a single generated source.
- `OpenSnekProbe` USB HID commands for button remap validation (`usb-info`, `usb-button-read`, `usb-button-set`, `usb-button-set-raw`).
