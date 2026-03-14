# Repo Map

Open the smallest useful slice first.

| Task | Open These First | Usually Validate With |
|---|---|---|
| BLE vendor protocol, framing, keys | `OpenSnek/Sources/OpenSnekProtocols/BLEVendorProtocol.swift`, `OpenSnek/Sources/OpenSnekHardware/BLEVendorTransportClient.swift`, `OpenSnek/Sources/OpenSnek/Bridge/BridgeClient+Bluetooth.swift`, `OpenSnek/Sources/OpenSnekProbe/ProbeTransport.swift`, `OpenSnek/Sources/OpenSnekProbe/main.swift` | `BLEVendorProtocolTests`, `BridgeClientBluetoothFallbackTests`, probe commands in `docs/development/VALIDATION.md` |
| USB HID protocol | `OpenSnek/Sources/OpenSnekProtocols/USBHIDProtocol.swift`, `OpenSnek/Sources/OpenSnekHardware/USBHIDControlSession.swift`, `OpenSnek/Sources/OpenSnek/Bridge/BridgeClient+USB.swift`, `tools/python/razer_usb.py` | focused USB probe commands, `USBDpiStageParsingTests`, `USBButtonHydrationTests` |
| Device profiles, capabilities, lighting zones, button layouts | `OpenSnek/Sources/OpenSnekCore/DeviceSupport.swift`, `OpenSnek/Sources/OpenSnekCore/Models.swift`, `OpenSnek/Sources/OpenSnekCore/ButtonBindingSupport.swift` | `DeviceProfilesTests`, `USBButtonHydrationTests` |
| App-state hydration, persistence, auto-apply | `OpenSnek/Sources/OpenSnek/Services/AppState.swift`, `AppStateEditorController.swift`, `AppStateApplyController.swift`, `DeviceStore.swift`, `EditorStore.swift`, `OpenSnek/Sources/OpenSnekAppSupport/DevicePreferenceStore.swift` | `AppStateRefactorCharacterizationTests`, `AppStateMultiDeviceTests` |
| Background service / backend bridge / snapshot sync | `OpenSnek/Sources/OpenSnek/Services/BackendSession.swift`, `BackgroundServiceCoordinator.swift`, `CrossProcessStateSync.swift`, `BridgeClient.swift` | `BackgroundServiceTransportTests`, `RemoteServiceSnapshotTests`, `ServiceModeTests` |
| UI, menu bar, startup/lifecycle | `OpenSnek/Sources/OpenSnek/UI/*.swift`, `OpenSnek/Sources/OpenSnek/AppLifecycleDelegate.swift`, `OpenSnek/Sources/OpenSnek/OpenSnekApp.swift`, `RuntimeStore.swift` | `AppLifecycleDelegateTests`, `ServiceMenuBarPresentationTests` |
| Probe CLI behavior | `OpenSnek/Sources/OpenSnekProbe/main.swift`, `OpenSnek/Sources/OpenSnekProbe/ProbeTransport.swift` | `swift build --package-path OpenSnek --product OpenSnekProbe`, live probe command |
| Python transport tooling | `tools/python/razer_poc.py`, `tools/python/razer_usb.py`, `tools/python/razer_ble.py` | `python3 tools/python/razer_poc.py --force-usb`, `--force-ble` |

## Canonical Sources

- Swift app/probe plus protocol docs are the source of truth.
- Python tooling is helpful for probing and comparison, but do not treat it as authoritative when it disagrees with Swift/docs.

## Common Search Shortcuts

- Lighting: `rg -n "lighting|usbLightingZoneLEDIDs|readLightingColor|btSetLightingRGB" OpenSnek/Sources OpenSnek/Tests`
- DPI stages: `rg -n "dpiStages|stageIDs|active_stage|stale-read" OpenSnek/Sources OpenSnek/Tests`
- Button remap: `rg -n "button|slot|hypershift|clutch" OpenSnek/Sources/OpenSnekCore OpenSnek/Sources/OpenSnek OpenSnek/Tests`
- Background service: `rg -n "BackendSession|BackgroundService|snapshot|cross-process" OpenSnek/Sources OpenSnek/Tests`

## High-Churn Files

- `OpenSnek/Sources/OpenSnek/Bridge/BridgeClient.swift`
- `OpenSnek/Sources/OpenSnek/Services/AppStateEditorController.swift`
- `OpenSnek/Sources/OpenSnekCore/DeviceSupport.swift`

Check `git diff -- <file>` before editing these and stage only intended hunks if the worktree is dirty.
