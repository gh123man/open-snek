# Codex Instructions

## Project Overview

**open-snek** configures supported Razer mice without Razer Synapse.

Current project scope includes:
- Python tooling (`tools/python/razer_usb.py`, `tools/python/razer_ble.py`, `tools/python/razer_poc.py`)
- Swift macOS app (`OpenSnek`) and Swift BLE probe CLI (`OpenSnekProbe`)

## Canonical Documentation

Always read protocol docs before protocol changes:
- `docs/protocol/PROTOCOL.md` (index)
- `docs/protocol/USB_PROTOCOL.md`
- `docs/protocol/BLE_PROTOCOL.md`
- `docs/protocol/PARITY.md`

When protocol behavior changes, update docs in the same change.

## Key Files

| Path | Purpose |
|---|---|
| `tools/python/razer_poc.py` | Transport wrapper CLI |
| `tools/python/razer_usb.py` | USB HID implementation |
| `tools/python/razer_ble.py` | BLE vendor + fallback implementation |
| `OpenSnek/Sources/OpenSnek/Bridge/BridgeClient.swift` | Swift transport bridge actor |
| `OpenSnek/Sources/OpenSnek/Bridge/BTVendorClient.swift` | CoreBluetooth vendor session manager |
| `OpenSnek/Sources/OpenSnekProtocols/BLEVendorProtocol.swift` | BLE framing and payload helpers |
| `OpenSnek/Sources/OpenSnek/Services/AppState.swift` | SwiftUI state model + apply scheduling |
| `OpenSnek/Sources/OpenSnek/Services/AppLog.swift` | Runtime app logs |
| `OpenSnek/Sources/OpenSnekProbe/main.swift` | BLE probe CLI (read/set/cycle + verify) |

## Current Device Coverage

Validated device family:
- Basilisk V3 X HyperSpeed
  - USB/dongle PID `0x00B9` (VID `0x1532`)
  - Bluetooth PID `0x00BA` (VID `0x068E`)

## Working Areas

- USB: DPI, stages, poll rate, battery, device metadata
- BLE vendor GATT: DPI table read/write, active stage update, lighting raw/frame controls, button remap payloads
- Swift app: auto-apply, state polling, stale-read defenses, runtime logging

## Development Rules

1. Read protocol docs first for protocol-facing edits.
2. Keep BLE vendor operations sequential per connection.
3. Prefer coalesced/latest-wins apply semantics for rapid UI edits.
4. Treat malformed BLE DPI payloads as transient; ignore/retry instead of applying invalid state.
5. Update docs and tests in the same change for behavior changes.
6. For BLE DPI stages:
   - parse by declared stage count even when read payload is short by one byte
   - resolve active stage via stage-id mapping from payload entries
   - preserve stage IDs on writes
   - do not reintroduce stage “nudge/toggle” write sequences
7. Keep `CHANGELOG.md` up to date for user-visible behavior changes, protocol handling changes, and reliability workflow changes.

## Validation Workflow

### Python

```bash
python3 tools/python/razer_poc.py --force-usb
python3 tools/python/razer_poc.py --force-ble
```

### Swift App / Tests

```bash
./run.sh
swift test --package-path OpenSnek
swift run --package-path OpenSnek OpenSnek
./OpenSnek/scripts/run_macos_app.sh
./OpenSnek/scripts/generate_xcodeproj.sh
xcodebuild -project OpenSnek/OpenSnek.xcodeproj -scheme OpenSnek -destination 'platform=macOS' build
xcodebuild -project OpenSnek/OpenSnek.xcodeproj -scheme OpenSnek -destination 'platform=macOS' test
xcodebuild -project OpenSnek/OpenSnek.xcodeproj -scheme OpenSnekProbe -destination 'platform=macOS' build
```

Notes:
- Use `swift run` for quick local iteration.
- Use `./run.sh` for the simplest root-level build-and-launch flow.
- Use `./OpenSnek/scripts/run_macos_app.sh` when validating UI/input behavior (dock icon, foreground activation, text-entry/keybinding interactions).
- Use Xcode project flows for signing/archive/distribution validation.
- After changing `OpenSnek/project.yml`, regenerate `OpenSnek/OpenSnek.xcodeproj` via `./OpenSnek/scripts/generate_xcodeproj.sh`.

### Swift Hardware Reliability Gate (required for BLE DPI/stage changes)

```bash
OPEN_SNEK_HW=1 swift test --package-path OpenSnek --filter HardwareDpiReliabilityTests
```

Policy:
- Always run this gate when a supported mouse is detected and connected during validation.
- Report explicit outcome in summaries: `pass`, `fail`, or `skipped` (with reason such as no Bluetooth device).

### Swift Probe CLI (preferred for fast BLE DPI iteration)

```bash
swift run --package-path OpenSnek OpenSnekProbe dpi-read
swift run --package-path OpenSnek OpenSnekProbe dpi-set --values 1600,6400 --active 2
swift run --package-path OpenSnek OpenSnekProbe dpi-cycle --sequence '1200,6400;2600,6400' --loops 10 --active 2
```

Bluetooth/TCC note:
- `OpenSnekProbe` BT commands use CoreBluetooth and require macOS Bluetooth privacy approval for the current host process.
- If a `swift run --package-path OpenSnek OpenSnekProbe ...` BT command aborts with `__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__`, fix macOS permission for the launching host before debugging protocol logic.
- On this workspace, the direct probe path works after granting Bluetooth access to the Codex host; verify with:

```bash
swift run --package-path OpenSnek OpenSnekProbe bt-raw-read --name 'BSK V3 PRO' --key 10850101 --timeout-ms 1200
```

- Expected success shape on the Basilisk V3 Pro BT path:
  - notify header `30 01 00 00 00 00 00 02`
  - payload `ff`
- If permission still looks stale, relaunch the host app (Codex / Terminal / Xcode) and retry before changing any BLE code.

For stage-selection regressions, run this exact check:

```bash
swift run --package-path OpenSnek OpenSnekProbe dpi-set --values 1000,2000,3000 --active 1 --verify-retries 8 --verify-delay-ms 120
swift run --package-path OpenSnek OpenSnekProbe dpi-set --values 1000,2000,3000 --active 3 --verify-retries 8 --verify-delay-ms 120
swift run --package-path OpenSnek OpenSnekProbe dpi-read
```

Expected final output: `active=3 count=3 values=[1000, 2000, 3000]`.

### Runtime Logs

App log path:

```text
~/Library/Logs/OpenSnek/open-snek.log
```

Useful regression grep:

```bash
tail -n 300 ~/Library/Logs/OpenSnek/open-snek.log | rg "btSetDpiStages|btGetDpiStages|stale-read masked|values=\\["
```

Fail patterns:
- `btGetDpiStages` repeatedly returning mirrored last-slot values after multi-stage writes
- stale-read masking persisting without convergence

Pass pattern:
- write ack followed by stable readback matching requested values and active stage

## References

- [OpenRazer](https://github.com/openrazer/openrazer)
- [OpenRazer Protocol Wiki](https://github.com/openrazer/openrazer/wiki/Reverse-Engineering-USB-Protocol)
- [razer-macos](https://github.com/1kc/razer-macos)
- [RazerBlackWidowV3MiniBluetoothControllerApp](https://github.com/JiqiSun/RazerBlackWidowV3MiniBluetoothControllerApp)
