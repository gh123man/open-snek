# Razer Mouse macOS Configuration Tool

Configure DPI, DPI stages, poll rate, and more for Razer mice on macOS — no Razer Synapse required.

## Supported Devices

Currently tested with:
- Razer Basilisk V3 X HyperSpeed

Should work with most modern Razer mice that use the same USB HID protocol.

## Requirements

- macOS
- Python 3.8+
- USB connection (2.4GHz dongle or cable) — **Bluetooth is not supported**

## Installation

```bash
# Clone the repo
git clone https://github.com/yourusername/razer-macos-poc.git
cd razer-macos-poc

# Create virtual environment
python3 -m venv venv
source venv/bin/activate

# Install dependencies
pip install hidapi
```

## Usage

```bash
# Activate virtual environment
source venv/bin/activate

# View current settings
python razer_poc.py

# Set DPI (temporary, immediate effect)
python razer_poc.py --dpi 1600

# Configure DPI stages (persisted, cycles with DPI button)
python razer_poc.py --stages 400,800,1600,3200,6400

# Set stages with specific active stage
python razer_poc.py --stages 400,800,1600,3200 --active-stage 2

# Set polling rate (125, 500, or 1000 Hz)
python razer_poc.py --poll-rate 1000

# Quiet mode (minimal output)
python razer_poc.py --stages 800,1600,3200 -q
```

## Features

| Feature | Status | Notes |
|---------|--------|-------|
| Read DPI | ✅ | Current DPI setting |
| Set DPI | ✅ | Immediate change |
| Read DPI Stages | ✅ | Hardware button presets |
| Set DPI Stages | ✅ | 1-5 stages, persisted |
| Set Active Stage | ✅ | Which stage is selected |
| Read Poll Rate | ✅ | 125/500/1000 Hz |
| Set Poll Rate | ✅ | 125/500/1000 Hz |
| Read Battery | ✅ | Percentage + charging status |
| RGB Control | ❌ | Not yet implemented |
| Button Mapping | ❌ | Not yet implemented |

## How It Works

This tool communicates with Razer mice using the same USB HID protocol as Razer Synapse and [OpenRazer](https://github.com/openrazer/openrazer). It sends 90-byte feature reports to configure the mouse.

### Why Bluetooth Doesn't Work

When connected via Bluetooth:
- The mouse uses a different vendor ID (`068e` vs Razer's `1532`)
- Bluetooth HID doesn't support the feature report protocol used for configuration
- Configuration requires the USB dongle or wired connection

## Protocol Reference

Based on reverse engineering from OpenRazer.

### Report Structure (90 bytes)
```
Offset  Size  Description
0       1     Status (0x00=new, 0x02=success)
1       1     Transaction ID (device-specific, usually 0x1F)
2-3     2     Remaining packets (big-endian, usually 0)
4       1     Protocol type (always 0x00)
5       1     Data size
6       1     Command class
7       1     Command ID (bit 7: 0=set, 1=get)
8-87    80    Arguments
88      1     CRC (XOR of bytes 2-87)
89      1     Reserved
```

### Key Commands
| Command | Class | ID | Description |
|---------|-------|-----|-------------|
| Get DPI | 0x04 | 0x85 | Read current DPI |
| Set DPI | 0x04 | 0x05 | Write current DPI |
| Get DPI Stages | 0x04 | 0x86 | Read DPI presets |
| Set DPI Stages | 0x04 | 0x06 | Write DPI presets |
| Get Poll Rate | 0x00 | 0x85 | Read polling rate |
| Set Poll Rate | 0x00 | 0x05 | Write polling rate |
| Get Battery | 0x07 | 0x80 | Read battery level |

## License

MIT

## Acknowledgments

- [OpenRazer](https://github.com/openrazer/openrazer) — Protocol documentation and reference implementation
- [razer-macos](https://github.com/1kc/razer-macos) — macOS IOKit approach reference
