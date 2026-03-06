# Claude Code Instructions

## Project Overview

**open-snek** — a Python tool to configure Razer mice without Razer Synapse. Works over USB HID (full control) and BLE (partial, actively being reverse engineered).

### Key Files

| File | Purpose |
|------|---------|
| `razer_poc.py` | Main CLI tool — DPI, poll rate, battery, stages |
| `ble_battery.py` | BLE battery reading via CoreBluetooth (macOS) |
| `explore_ble.py` | BLE GATT service explorer (macOS) |
| `enumerate_hid_gatt.py` | HID service GATT enumeration (Windows/bleak) |
| `enumerate_hid_gatt_linux.py` | HID service GATT enumeration (Linux/Steam Deck) |
| `collect_razer_bt.ps1` | Windows driver/device data collector |
| `razer_bt_dump/` | Collected Windows driver INFs, handles, registry dumps |
| `PROTOCOL.md` | **Complete protocol documentation — ALWAYS REFERENCE THIS** |

## Important: Protocol Documentation

**ALWAYS read `PROTOCOL.md` before making protocol-related changes.** It documents:
- 90-byte USB HID report structure and all known commands
- BLE vendor GATT service protocol (lighting)
- Windows BLE driver architecture (RzDev_00ba.sys, RZCONTROL, HidOverGatt)
- BLE HID Report Descriptor analysis
- What works, what doesn't, and what to investigate next

## Architecture

### USB Path (working)
```
razer_poc.py → RazerMouse._send_command() → hidapi → USB HID Feature Report (90 bytes)
```

### BLE Path (partial)
```
Battery:  ble_battery.py → CoreBluetooth → GATT Battery Service (0x180F)
DPI read: razer_poc.py --sniff-dpi → hidapi → passive HID Input Report (ID 0x05)
Lighting: explore_ble.py → CoreBluetooth → Vendor GATT (52401523...) → 8+10 byte writes
Config:   ??? → needs GATT Feature Report characteristics in HID service (0x1812)
```

### Windows Driver Stack (how Synapse does it)
```
Synapse → RZCONTROL IOCTL → RzDev_00ba.sys → HidOverGatt → GATT write to HID service
```

## Current State

### Working
- USB: DPI read/write, DPI stages, poll rate, battery, device enumeration
- BLE: Battery read, DPI read (passive), lighting control

### Not Working (yet)
- BLE: DPI write, poll rate, button remapping — requires Feature Report GATT handles
- USB: Button remapping, RGB (protocol known from OpenRazer, not implemented)

### Active Investigation
The BLE HID Report Descriptor has **zero Feature/Output reports**. The Razer Windows
driver writes to GATT characteristics that have Feature-type Report Reference descriptors
but are NOT in the Report Map. We need to enumerate these from Linux (macOS hides
the HID service). See PROTOCOL.md "What We Need To Uncover Next".

## Device IDs

| Connection | VID | PID | Transaction ID |
|------------|-----|-----|----------------|
| USB/Dongle | `0x1532` | `0x00B9` | `0x1F` |
| Bluetooth | `0x068E` | `0x00BA` | `0x1F` |

## Development Guidelines

1. **Read `PROTOCOL.md` first** before any protocol changes
2. **Document before implementing** — add commands to PROTOCOL.md before coding
3. **Test with real hardware** — protocol changes can brick device state (BLE power cycle recovery)
4. USB Feature Report path: `hidapi.send_feature_report()` / `get_feature_report()`
5. BLE vendor GATT path: CoreBluetooth write-with-response to `...1524`, notify on `...1525`

## References

- [OpenRazer](https://github.com/openrazer/openrazer) — Linux driver, protocol reference
- [OpenRazer Protocol Wiki](https://github.com/openrazer/openrazer/wiki/Reverse-Engineering-USB-Protocol)
- [razer-macos](https://github.com/1kc/razer-macos) — macOS IOKit reference
- [RazerBlackWidowV3MiniBluetoothControllerApp](https://github.com/JiqiSun/RazerBlackWidowV3MiniBluetoothControllerApp) — BLE vendor GATT reference
