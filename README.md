# open-snek

Configure Razer mice without Razer Synapse. Works over USB (full control) and Bluetooth (partial — actively being reverse engineered).

## Supported Devices

Tested with:
- Razer Basilisk V3 X HyperSpeed (USB PID `0x00B9`, BT PID `0x00BA`)

Should work with most modern Razer mice that use the same 90-byte USB HID protocol.

## Requirements

- Python 3.8+
- macOS or Linux
- USB connection (2.4GHz dongle or cable) for full config
- Bluetooth connection for battery, DPI read, and lighting

## Installation

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

## Usage

```bash
# View current settings (USB)
python razer_poc.py

# Set DPI
python razer_poc.py --dpi 1600

# Configure DPI stages (persisted to device memory)
python razer_poc.py --stages 400,800,1600,3200,6400

# Set polling rate
python razer_poc.py --poll-rate 1000

# Sniff DPI changes over Bluetooth (passive, read-only)
python razer_poc.py --sniff-dpi 10
```

## Features

| Feature | USB | Bluetooth | Notes |
|---------|-----|-----------|-------|
| Read/Set DPI | Yes | Read only | BT reads via passive HID input reports |
| Read/Set DPI Stages | Yes | No | |
| Read/Set Poll Rate | Yes | No | |
| Read Battery | Yes | Yes | BT uses BLE Battery Service (0x180F) |
| LED/Lighting | No | Yes | BT via vendor GATT service |
| Button Mapping | No | No | Protocol partially documented |

## Bluetooth Status

The USB 90-byte HID Feature Report protocol does **not** work over BLE as-is. The BLE HID Report Descriptor exposes only Input reports. On Windows, Razer's kernel driver (`RzDev_00ba.sys`) bridges HID commands to GATT writes at the driver level.

We've confirmed:
- **Battery**: Reads via standard BLE Battery Service
- **DPI read**: Via passive HID input reports (report ID 0x05)
- **Lighting**: Via vendor GATT service (`52401523-F97C-7F90-0E7F-6C6F4E36DB1C`)
- **DPI/config writes**: Not yet possible — requires discovering Feature Report GATT characteristics inside the HID service (0x1812), which macOS hides from applications

**Next step**: Run `enumerate_hid_gatt_linux.py` on Linux (e.g. Steam Deck) to enumerate the HID service's GATT characteristics and find the Feature Report handles that carry the 90-byte protocol.

See [PROTOCOL.md](PROTOCOL.md) for full protocol documentation and architecture details.

## Repo Structure

| File | Purpose |
|------|---------|
| `razer_poc.py` | Main CLI tool |
| `ble_battery.py` | BLE battery reading via CoreBluetooth (macOS) |
| `explore_ble.py` | BLE GATT service explorer (macOS) |
| `enumerate_hid_gatt.py` | HID service GATT enumeration (Windows/bleak) |
| `enumerate_hid_gatt_linux.py` | HID service GATT enumeration (Linux/Steam Deck) |
| `collect_razer_bt.ps1` | Windows driver/device data collector |
| `razer_bt_dump/` | Collected Windows driver data (INFs, handles, registry) |
| `PROTOCOL.md` | Full protocol documentation |

## License

MIT

## Acknowledgments

- [OpenRazer](https://github.com/openrazer/openrazer) — Protocol documentation and Linux driver
- [razer-macos](https://github.com/1kc/razer-macos) — macOS IOKit reference
- [RazerBlackWidowV3MiniBluetoothControllerApp](https://github.com/JiqiSun/RazerBlackWidowV3MiniBluetoothControllerApp) — BLE vendor GATT reference
