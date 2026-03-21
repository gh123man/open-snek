# Codex Instructions

Goal: shortest path from user request to the exact files, commands, and constraints needed to do the work.

## Start Here

| Task | Open First | Usually Validate With |
|---|---|---|
| BLE protocol, BT probe, BT device bug | `docs/protocol/PROTOCOL.md` then `docs/protocol/BLE_PROTOCOL.md`; `OpenSnek/Sources/OpenSnekProtocols/BLEVendorProtocol.swift`; `OpenSnek/Sources/OpenSnekHardware/BLEVendorTransportClient.swift`; `OpenSnek/Sources/OpenSnek/Bridge/BridgeClient+Bluetooth.swift`; `OpenSnek/Sources/OpenSnekProbe/{main.swift,ProbeTransport.swift}` | `swift test --package-path OpenSnek --filter BLEVendorProtocolTests`; build/run probe |
| USB protocol, USB lighting, USB buttons | `docs/protocol/PROTOCOL.md` then `docs/protocol/USB_PROTOCOL.md`; `OpenSnek/Sources/OpenSnekProtocols/USBHIDProtocol.swift`; `OpenSnek/Sources/OpenSnek/Bridge/BridgeClient+USB.swift`; `OpenSnek/Sources/OpenSnekCore/DeviceSupport.swift` | focused USB probe command; `DeviceProfilesTests`; `USBButtonHydrationTests` |
| Device support, product IDs, zones, button layout | `OpenSnek/Sources/OpenSnekCore/{DeviceSupport.swift,Models.swift,ButtonBindingSupport.swift}`; `docs/protocol/PARITY.md` if shipped-status changes | `swift test --package-path OpenSnek --filter DeviceProfilesTests` |
| App-state hydration, persistence, auto-apply | `OpenSnek/Sources/OpenSnek/Services/{AppState.swift,AppStateEditorController.swift,AppStateApplyController.swift,DeviceStore.swift,EditorStore.swift}`; `OpenSnek/Sources/OpenSnekAppSupport/DevicePreferenceStore.swift` | `swift test --package-path OpenSnek --filter AppStateRefactorCharacterizationTests` |
| Background service, bridge transport, snapshots | `OpenSnek/Sources/OpenSnek/Services/{BackendSession.swift,BackgroundServiceCoordinator.swift,AppStateRuntimeController.swift}`; `OpenSnek/Sources/OpenSnek/Bridge/BridgeClient.swift` | `swift test --package-path OpenSnek --filter BackgroundServiceTransportTests` or `RemoteServiceSnapshotTests` |
| UI, menu bar, startup/lifecycle | `OpenSnek/Sources/OpenSnek/UI/*.swift`; `OpenSnek/Sources/OpenSnek/{AppLifecycleDelegate.swift,OpenSnekApp.swift}`; `RuntimeStore.swift` | `swift test --package-path OpenSnek --filter AppLifecycleDelegateTests` or `ServiceMenuBarPresentationTests` |

Protocol behavior changes require docs, tests, and `CHANGELOG.md` updates in the same change.

## Canonical Sources

- Swift app/probe code and protocol docs are canonical.
- Python tooling (`tools/python/`) is useful for probing and comparison, but may lag; do not treat it as source of truth when it disagrees with Swift/docs.
- Open `docs/protocol/PARITY.md` only when support status, shipped capability, or transport parity changes.

## Current Validated Devices

- Basilisk V3 X HyperSpeed: USB `0x00B9`, Bluetooth `0x00BA`
- Basilisk V3 Pro: USB `0x00AB`, Bluetooth `0x00AC`
- Basilisk V3 35K: USB `0x00CB`

## Repo Rules

1. BLE vendor exchanges stay serialized one-at-a-time per connection.
2. Prefer focused reads, focused tests, and the smallest useful probe/build command instead of defaulting to full-package runs.
3. Keep latest-wins/coalesced apply behavior for rapid UI edits.
4. Treat malformed BLE DPI payloads as transient; ignore/retry instead of applying bad state.
5. For BLE DPI stages, preserve stage IDs on write, resolve active stage from stage IDs, and do not reintroduce stage nudge/toggle writes.
6. Keep `CHANGELOG.md` up to date for user-visible or protocol-visible changes.
7. Treat `OpenSnek/project.yml` as the Xcode source of truth; generate `OpenSnek/OpenSnek.xcodeproj` on demand and do not commit it.
8. Before saying work is done or pushing code, run the complete unit test suite with `swift test --package-path OpenSnek` and ensure it passes locally.

## Quick Commands

```bash
swift build --package-path OpenSnek --product OpenSnekProbe
swift run --package-path OpenSnek OpenSnekProbe dpi-read
swift run --package-path OpenSnek OpenSnekProbe bt-lighting-info --name "BSK V3 PRO"
swift run --package-path OpenSnek OpenSnekProbe usb-lighting-info --pid 0x00ab
swift run --package-path OpenSnek OpenSnek
```

Highest-value focused tests:

```bash
swift test --package-path OpenSnek --filter BLEVendorProtocolTests
swift test --package-path OpenSnek --filter DeviceProfilesTests
swift test --package-path OpenSnek --filter AppStateRefactorCharacterizationTests
swift test --package-path OpenSnek --filter BackgroundServiceTransportTests
```

Hardware gate for BLE DPI/stage changes when a supported device is connected:

```bash
OPEN_SNEK_HW=1 swift test --package-path OpenSnek --filter HardwareDpiReliabilityTests
```

## High-Value Gotchas

- Basilisk V3 Pro Bluetooth lighting is multi-zone. Static color uses per-zone `10 83` / `10 03`; brightness uses per-zone `10 85` / `10 05`. Do not assume legacy `10 84` / `10 04` works on that device.
- Basilisk V3 Pro Bluetooth notify headers are 8 bytes. Older captures/tools may assume 20-byte headers.
- If `swift run --package-path OpenSnek OpenSnekProbe ...` aborts with `__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__`, fix macOS Bluetooth permission for the launching host before debugging protocol logic.
- `OpenSnek/Sources/OpenSnek/Bridge/BridgeClient.swift` is a high-churn file. Check `git diff -- <file>` before editing and stage only intended hunks when the worktree is dirty.

## Deeper Docs

- `docs/development/README.md`
- `docs/development/REPO_MAP.md`
- `docs/development/VALIDATION.md`
- `docs/protocol/PROTOCOL.md`
