# Validation

Prefer the smallest useful command first. Expand only when the change crosses boundaries.

## Fastest Useful Checks

| Change Area | Start Here | Expand When Needed |
|---|---|---|
| Probe CLI or protocol helper compile check | `swift build --package-path OpenSnek --product OpenSnekProbe` | run a live probe command |
| BLE key/parser changes | `swift test --package-path OpenSnek --filter BLEVendorProtocolTests` | add `BridgeClientBluetoothFallbackTests`; run live BT probe |
| Device profile / lighting zone / button-layout changes | `swift test --package-path OpenSnek --filter DeviceProfilesTests` | add probe readback |
| App-state hydration / persistence / auto-apply | `swift test --package-path OpenSnek --filter AppStateRefactorCharacterizationTests` | add `AppStateMultiDeviceTests` |
| Background service / backend transport | `swift test --package-path OpenSnek --filter BackgroundServiceTransportTests` | add `RemoteServiceSnapshotTests` or `ServiceModeTests` |
| Lifecycle / startup / menu bar | `swift test --package-path OpenSnek --filter AppLifecycleDelegateTests` | add `ServiceMenuBarPresentationTests` |
| USB button remap behavior | `swift test --package-path OpenSnek --filter USBButtonHydrationTests` | use `usb-button-read` / `usb-button-set` probe commands |
| BLE DPI stage behavior | `swift test --package-path OpenSnek --filter BLEVendorProtocolTests` | run hardware gate below when a supported device is connected |

Avoid `swift test --package-path OpenSnek` unless the change is broad or the user explicitly wants a full package run.

## Hardware Gates

Required for BLE DPI/stage changes when supported hardware is connected:

```bash
OPEN_SNEK_HW=1 swift test --package-path OpenSnek --filter HardwareDpiReliabilityTests
```

Report the result explicitly as `pass`, `fail`, or `skipped`.

## Probe Cheat Sheet

### BLE DPI

```bash
swift run --package-path OpenSnek OpenSnekProbe dpi-read
swift run --package-path OpenSnek OpenSnekProbe dpi-set --values 1600,6400 --active 2
swift run --package-path OpenSnek OpenSnekProbe dpi-cycle --sequence '1200,6400;2600,6400' --loops 10 --active 2
```

Stage-selection regression check:

```bash
swift run --package-path OpenSnek OpenSnekProbe dpi-set --values 1000,2000,3000 --active 1 --verify-retries 8 --verify-delay-ms 120
swift run --package-path OpenSnek OpenSnekProbe dpi-set --values 1000,2000,3000 --active 3 --verify-retries 8 --verify-delay-ms 120
swift run --package-path OpenSnek OpenSnekProbe dpi-read
```

Expected final output:

```text
active=3 count=3 values=[1000, 2000, 3000]
```

### Basilisk V3 Pro Bluetooth Lighting

```bash
swift run --package-path OpenSnek OpenSnekProbe bt-lighting-info --name "BSK V3 PRO"
swift run --package-path OpenSnek OpenSnekProbe bt-lighting-read --zone all --name "BSK V3 PRO"
swift run --package-path OpenSnek OpenSnekProbe bt-lighting-brightness --value 96 --zone all --name "BSK V3 PRO"
swift run --package-path OpenSnek OpenSnekProbe bt-lighting-color --color 00ff40 --zone all --name "BSK V3 PRO"
swift run --package-path OpenSnek OpenSnekProbe bt-lighting-color --color ff6600 --zone logo --name "BSK V3 PRO"
```

Validated zone map:

- `scroll_wheel` -> `0x01`
- `logo` -> `0x04`
- `underglow` -> `0x0A`

### USB Lighting

```bash
swift run --package-path OpenSnek OpenSnekProbe usb-lighting-info --pid 0x00ab
swift run --package-path OpenSnek OpenSnekProbe usb-lighting-read --zone all --pid 0x00ab
swift run --package-path OpenSnek OpenSnekProbe usb-lighting-brightness --value 96 --zone all --pid 0x00ab
swift run --package-path OpenSnek OpenSnekProbe usb-lighting-effect --kind static --color 00ff40 --zone all --pid 0x00ab
```

### Python Transport Wrapper

```bash
python3 tools/python/razer_poc.py --force-usb
python3 tools/python/razer_poc.py --force-ble
```

## App / Xcode Flows

Use these only when the task needs them:

```bash
./run.sh
swift run --package-path OpenSnek OpenSnek
./OpenSnek/scripts/run_macos_app.sh
./OpenSnek/scripts/generate_xcodeproj.sh
./OpenSnek/scripts/xcodebuild_generated.sh -scheme OpenSnek -destination 'platform=macOS' build
./OpenSnek/scripts/xcodebuild_generated.sh -scheme OpenSnek -destination 'platform=macOS' test
./OpenSnek/scripts/xcodebuild_generated.sh -scheme OpenSnekProbe -destination 'platform=macOS' build
```

`OpenSnek/OpenSnek.xcodeproj` is generated from `OpenSnek/project.yml` on demand and is not committed.

## Permissions / TCC

Bluetooth:

- `OpenSnekProbe` BT commands require macOS Bluetooth privacy approval for the launching host process.
- If a BT command aborts with `__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__`, fix host permission before changing BLE code.
- On this workspace, a quick verification command is:

```bash
swift run --package-path OpenSnek OpenSnekProbe bt-raw-read --name 'BSK V3 PRO' --key 10850101 --timeout-ms 1200
```

Expected success shape on the Basilisk V3 Pro BT path:

- notify header `30 01 00 00 00 00 00 02`
- payload `ff`

HID/Input Monitoring:

- Passive HID listeners and some USB/Bluetooth state flows require macOS Input Monitoring approval for the launching host.

## Runtime Logs

App log path:

```text
~/Library/Logs/OpenSnek/open-snek.log
```

Useful grep:

```bash
tail -n 300 ~/Library/Logs/OpenSnek/open-snek.log | rg "btSetDpiStages|btGetDpiStages|stale-read masked|values=\\["
```

Pass pattern:

- write ACK followed by stable readback matching the requested values and active stage

Fail patterns:

- repeated mirrored last-slot values after multi-stage writes
- stale-read masking that never converges
