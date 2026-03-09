# open-snek

Configure Razer mice without Razer Synapse.

- USB / 2.4GHz dongle: full config path (`razer_usb.py`)
- Bluetooth: partial but expanding support (`razer_ble.py`)
- Wrapper CLI: `razer_poc.py` auto-selects transport
- Native macOS app: `OpenSnek` (SwiftUI + CoreBluetooth + IOKit HID)

## Supported Device

Validated on:
- Razer Basilisk V3 X HyperSpeed
  - USB PID `0x00B9`
  - Bluetooth PID `0x00BA` (VID `0x068E`)

## Requirements

- Python 3.8+
- macOS or Linux
- `hidapi` backend available to `hid` Python package

For Bluetooth battery and vendor GATT features on macOS:
- `pyobjc-framework-CoreBluetooth`

## Installation

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

## macOS App (`OpenSnek`)

`OpenSnek` is a pure Swift macOS app that provides:
- device discovery (USB / Bluetooth)
- live state polling
- auto-apply settings (DPI stages, active stage, poll rate, sleep timeout, lighting, button remap)
- state-safe apply behavior (coalesced writes + stale-read protection)
- runtime logging

Run in-place during development:

```bash
swift run --package-path OpenSnek OpenSnek
```

Build and launch as a proper macOS app bundle (recommended for reliable focus, dock icon, and keyboard text-entry behavior):

```bash
./OpenSnek/scripts/run_macos_app.sh
```

Generate and use the native Xcode project (recommended for signing/archive/distribution):

```bash
./OpenSnek/scripts/generate_xcodeproj.sh --open
```

Regenerate app icon assets:

```bash
./OpenSnek/scripts/generate_appiconset.sh
```

Headless Xcode build/test:

```bash
xcodebuild -project OpenSnek/OpenSnek.xcodeproj -scheme OpenSnek -destination 'platform=macOS' build
xcodebuild -project OpenSnek/OpenSnek.xcodeproj -scheme OpenSnek -destination 'platform=macOS' test
```

Xcode build for probe CLI:

```bash
xcodebuild -project OpenSnek/OpenSnek.xcodeproj -scheme OpenSnekProbe -destination 'platform=macOS' build
```

Bundle-only build (no launch):

```bash
./OpenSnek/scripts/build_macos_app.sh --configuration release
```

Prefer stable signing identity (keeps macOS privacy grants like Input Monitoring more consistent across rebuilds):

```bash
./OpenSnek/scripts/build_macos_app.sh --configuration debug --sign-identity auto --open
```

Default output:

```text
OpenSnek/.dist/Open Snek.app
```

Optional custom icon:

```bash
./OpenSnek/scripts/build_macos_app.sh --icon /absolute/path/to/AppIcon.png
```

Run tests:

```bash
swift test --package-path OpenSnek
```

Runtime log file:

```bash
~/Library/Logs/OpenSnek/open-snek.log
```

### Permission Troubleshooting (macOS)

- If logs show `IOHIDManagerOpen failed (-536870174)` / `kIOReturnNotPermitted`, macOS is blocking HID access.
- Grant `Open Snek` in: `System Settings > Privacy & Security > Input Monitoring`.
- Bluetooth control does not require App Sandbox Bluetooth entitlements in this local-signing setup, but the app still needs user Bluetooth permission when prompted.
- If Bluetooth was denied previously, reset and re-prompt:

```bash
tccutil reset Bluetooth io.opensnek.OpenSnek
```

### DPI Stage Reliability Workflow (Required Before Merge)

Use this exact workflow for any change touching BLE DPI/stage code, UI stage selection,
or apply scheduling.

1. Run fast protocol/unit checks:

```bash
swift test --package-path OpenSnek
```

2. Run hardware reliability loop (real mouse required):

```bash
OPEN_SNEK_HW=1 swift test --package-path OpenSnek --filter HardwareDpiReliabilityTests
```

3. Validate deterministic CLI readback path:

```bash
swift run --package-path OpenSnek OpenSnekProbe dpi-set --values 1000,2000,3000 --active 1 --verify-retries 8 --verify-delay-ms 120
swift run --package-path OpenSnek OpenSnekProbe dpi-set --values 1000,2000,3000 --active 3 --verify-retries 8 --verify-delay-ms 120
swift run --package-path OpenSnek OpenSnekProbe dpi-read
```

Expected: final read reports `active=3` with `values=[1000, 2000, 3000]`.

4. Validate UI/mouse-button stage sync manually:
- Set 3 unique stage values in app (example: 1000/2000/3000).
- Press mouse stage button repeatedly.
- Confirm applied DPI matches the stage highlighted in UI each step.
- Confirm cycle wraps correctly (stage 3 -> stage 1).

5. Check logs for known bad signatures:

```bash
tail -n 300 ~/Library/Logs/OpenSnek/open-snek.log | rg "btSetDpiStages|btGetDpiStages|stale-read masked|values=\\["
```

Regression indicators:
- repeated mirrored last-slot values after multi-stage write (for example `[800,1600,1600]`)
- persistent stale-read masking without convergence

Pass indicators:
- `btSetDpiStages ... ok=true` followed by stable `btGetDpiStages ... values=[...]` matching requested slots
- active stage in logs matches expected selected stage

### BLE Probe CLI (`OpenSnekProbe`)

For deterministic protocol verification and stress testing without UI interaction:

```bash
# Read current BLE DPI table
swift run --package-path OpenSnek OpenSnekProbe dpi-read

# Set single-stage DPI and verify readback
swift run --package-path OpenSnek OpenSnekProbe dpi-set --values 1600 --active 1

# Cycle through values with readback verification
swift run --package-path OpenSnek OpenSnekProbe dpi-cycle --sequence '1200;2600;3200' --loops 12 --active 1
```

### BLE DPI Protocol Notes (Regression-Critical)

- BLE read payload length can be short by one byte (`15/22/36` for `2/3/5` stages). Parse by declared stage count while DPI bytes are present.
- Active stage byte must be resolved via stage-id mapping from current read entries, not assumed fixed 0-index/1-index.
- Preserve stage IDs when writing stage tables so mouse hardware stage-button cycling stays in sync with UI.
- Do not reintroduce active-stage “nudge/toggle” writes as a latching workaround; use single write + readback verification.

## Usage

```bash
# Auto transport (prefers USB if both are present)
python razer_poc.py

# Force transport
python razer_poc.py --force-usb
python razer_poc.py --force-ble

# USB examples
python razer_usb.py --dpi 1600
python razer_usb.py --stages 400,800,1600,3200,6400
python razer_usb.py --poll-rate 1000
python razer_usb.py --scroll-led-brightness 128
python razer_usb.py --scroll-led-static 00ff00
python razer_usb.py --scroll-led-effect spectrum

# BLE examples
python razer_ble.py --single-dpi 1600
python razer_ble.py --button-right-click 2
python razer_ble.py --button-middle-click 3
python razer_ble.py --button-scroll-up 9
python razer_ble.py --button-scroll-down 10
python razer_ble.py --button-clear-layer 5:1
python razer_ble.py --lighting-value-raw 1
python razer_ble.py --lighting-mode-raw 8
python razer_ble.py --lighting-rgb ff0000
python razer_ble.py --lighting-spectrum-seconds 3
python razer_ble.py --battery-vendor
python razer_ble.py --vendor-key-get 00810000
```

## Feature Matrix

| Feature | USB | BLE | OpenSnek | Notes |
|---|---|---|---|---|
| Read/Set DPI | Yes | Partial | Yes | BLE uses staged table writes via vendor GATT; HID direct set may fail per stack |
| Read/Set DPI Stages | Yes | Yes | Yes | BLE via vendor keys `0B 84` / `0B 04` |
| Set Active DPI Stage | Yes | Yes | Yes | BLE implemented via stage-table rewrite |
| Read/Set Poll Rate | Yes | Partial | Partial | BLE stack dependent |
| Device Mode | Yes | Partial | Partial | App supports USB read/write + BT read-only fallback |
| Read Battery | Yes | Yes | Yes | BLE fallback via Battery Service `0x180F` |
| Idle Timeout | Yes | Yes | Yes | USB `07:83/03`; BLE vendor fallback `05 84/05 04` |
| Low Battery Threshold | Yes | Yes | Yes | App supports USB + BLE read/write; USB card hidden when unsupported on a device/firmware |
| Scroll Mode/Acceleration/Smart Reel | Yes | Partial | Partial | App probes USB support and hides each unsupported control instead of showing disabled toggles |
| Scroll LED Brightness/Effects | Yes | Partial | Partial | App exposes full profile controls on USB; Bluetooth UI remains static-only (brightness + color) |
| Button Rebinding | Partial | Yes | Yes | BLE vendor header + 10-byte payload; USB has experimental raw writer |

## Repository Structure

| Path | Purpose |
|---|---|
| `razer_poc.py` | Transport wrapper (`razer_usb.py` / `razer_ble.py`) |
| `razer_usb.py` | USB/2.4GHz implementation |
| `razer_ble.py` | Bluetooth implementation (vendor GATT + HID fallback) |
| `ble_battery.py` | BLE Battery Service read helper (macOS) |
| `explore_ble.py` | BLE service/characteristic exploration tool (macOS) |
| `enumerate_hid_gatt.py` | HID-over-GATT enumeration helper |
| `enumerate_hid_gatt_linux.py` | Linux HID-over-GATT probing helper |
| `discover_bt_vendor_keys.py` | Safe BLE vendor key discovery and writeback validator |
| `OpenSnek/` | Swift package containing `OpenSnek` app and `OpenSnekProbe` CLI |
| `OpenSnek/OpenSnek.xcodeproj` | Native macOS Xcode project for signing/archive/distribution |
| `OpenSnek/project.yml` | XcodeGen source-of-truth used to regenerate the Xcode project |
| `captures/` | BLE capture corpus and index |
| `PROTOCOL.md` | Protocol documentation index |
| `USB_PROTOCOL.md` | USB transport protocol |
| `BLE_PROTOCOL.md` | BLE protocol + implementation mapping |
| `BLE_REVERSE_ENGINEERING.md` | Reverse-engineering notes and timeline |

## Documentation

- [Protocol Index](PROTOCOL.md)
- [Changelog](CHANGELOG.md)
- [USB Protocol](USB_PROTOCOL.md)
- [BLE Protocol](BLE_PROTOCOL.md)
- [USB/BLE Parity](PARITY.md)
- [BLE Reverse Engineering Notes](BLE_REVERSE_ENGINEERING.md)
- [Capture Corpus](captures/README.md)
- [OpenSnek App/Probe Guide](OpenSnek/README.md)

## License

MIT
