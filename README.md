# open-snek

Configure Razer mice without Razer Synapse.

- USB / 2.4GHz dongle: full config path (`razer_usb.py`)
- Bluetooth: partial but expanding support (`razer_ble.py`)
- Wrapper CLI: `razer_poc.py` auto-selects transport

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
python razer_ble.py --lighting-value-raw 1
```

## Feature Matrix

| Feature | USB | BLE | Notes |
|---|---|---|---|
| Read/Set DPI | Yes | Partial | BLE supports staged table writes via vendor GATT; direct HID set may fail per stack |
| Read/Set DPI Stages | Yes | Yes | BLE via vendor keys `0B 84` / `0B 04` |
| Set Active DPI Stage | Yes | Yes | BLE implemented via stage-table rewrite |
| Read/Set Poll Rate | Yes | Partial | Implemented with HID command path; BLE stack dependent |
| Read Battery | Yes | Yes | BLE fallback via Battery Service `0x180F` |
| Scroll LED Brightness/Effects | Yes | Partial | USB validated (`0x0F:0x84/0x04` + `0x0F:0x02`); BLE via HID path only |
| Power/Sleep/Lighting (raw) | No | Yes | BLE vendor scalar read/write keys |
| Button Rebinding | Partial | Yes | BLE vendor header+10-byte payload; USB has experimental raw writer |

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
| `captures/` | BLE capture corpus and index |
| `PROTOCOL.md` | Protocol documentation index |
| `USB_PROTOCOL.md` | USB transport protocol |
| `BLE_PROTOCOL.md` | BLE protocol + implementation mapping |
| `BLE_REVERSE_ENGINEERING.md` | Reverse-engineering notes and timeline |

## Documentation

- [Protocol Index](PROTOCOL.md)
- [USB Protocol](USB_PROTOCOL.md)
- [BLE Protocol](BLE_PROTOCOL.md)
- [USB/BLE Parity](PARITY.md)
- [BLE Reverse Engineering Notes](BLE_REVERSE_ENGINEERING.md)
- [Capture Corpus](captures/README.md)

## License

MIT
