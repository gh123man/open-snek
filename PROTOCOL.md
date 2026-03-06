# Razer USB HID Protocol Documentation

This document describes the USB HID protocol used by Razer mice, based on reverse engineering from the [OpenRazer](https://github.com/openrazer/openrazer) project and our own testing.

## Table of Contents

- [Overview](#overview)
- [Report Structure](#report-structure)
- [Command Classes](#command-classes)
- [Implemented Commands](#implemented-commands)
- [Unimplemented Commands](#unimplemented-commands)
- [Device-Specific Notes](#device-specific-notes)
- [BLE Protocol](#ble-bluetooth-low-energy-protocol)
- [References](#references)

---

## Overview

Razer devices communicate via USB HID Feature Reports. The protocol uses 90-byte reports for both requests and responses.

### Connection Types

| Connection | Vendor ID | Protocol Support |
|------------|-----------|------------------|
| USB Cable | `0x1532` | Full |
| 2.4GHz Dongle | `0x1532` | Full |
| Bluetooth | `0x068e` (some devices) | Partial / transport-dependent |

**Important**: Bluetooth behavior varies by device/firmware/OS HID stack. Some devices expose configuration over Bluetooth HID, but transport method and transaction ID may differ from USB.

---

## Report Structure

All reports are exactly **90 bytes**.

```
Offset  Size  Field              Description
------  ----  -----              -----------
0       1     Status             Request: 0x00 (new command)
                                 Response: 0x01 (busy), 0x02 (success),
                                          0x03 (failure), 0x04 (timeout),
                                          0x05 (not supported)
1       1     Transaction ID     Device-specific, groups request/response
2       2     Remaining Packets  Big-endian, usually 0x0000
4       1     Protocol Type      Always 0x00
5       1     Data Size          Size of arguments (max 80)
6       1     Command Class      Category of command
7       1     Command ID         Specific command (bit 7: 0=set, 1=get)
8-87    80    Arguments          Command parameters
88      1     CRC                XOR of bytes 2-87
89      1     Reserved           Always 0x00
```

### CRC Calculation

```python
def calculate_crc(report: bytes) -> int:
    crc = 0
    for i in range(2, 88):
        crc ^= report[i]
    return crc
```

### Command ID Convention

- **Bit 7 = 0**: SET command (write to device)
- **Bit 7 = 1**: GET command (read from device)
- Example: `0x05` = SET, `0x85` = GET (same command, different direction)

---

## Command Classes

| Class | Name | Description |
|-------|------|-------------|
| `0x00` | Standard | Device mode, serial, firmware, poll rate |
| `0x02` | Configuration | Scroll wheel, button mapping, profiles |
| `0x03` | LED | Legacy LED control |
| `0x04` | DPI | DPI and sensitivity settings |
| `0x07` | Misc | Battery, idle time, dock settings |
| `0x0F` | Matrix | RGB lighting effects |

---

## Implemented Commands

### Class 0x00 - Standard

#### Get Serial Number
```
Command:  Class 0x00, ID 0x82, Size 0x16
Args:     (none)
Response: args[0-21] = ASCII serial string
TxnID:    0xFF
```

#### Get Firmware Version
```
Command:  Class 0x00, ID 0x81, Size 0x04
Args:     (none)
Response: args[0] = major, args[1] = minor
TxnID:    0xFF
```

#### Get Poll Rate
```
Command:  Class 0x00, ID 0x85, Size 0x01
Args:     (none)
Response: args[0] = rate byte
TxnID:    0x1F (modern mice) or 0xFF (older mice)

Rate byte mapping:
  0x01 = 1000 Hz
  0x02 = 500 Hz
  0x08 = 125 Hz
```

#### Set Poll Rate
```
Command:  Class 0x00, ID 0x05, Size 0x01
Args:     [0] = rate byte (see above)
TxnID:    0x1F (modern mice) or 0xFF (older mice)
```

#### Get/Set Device Mode
```
Command:  Class 0x00, ID 0x84 (get) / 0x04 (set), Size 0x02
Args:     [0] = mode, [1] = param

Modes:
  0x00, 0x00 = Normal Mode (onboard memory active)
  0x03, 0x00 = Driver Mode (software control)
```

---

### Class 0x02 - Configuration

#### Get Scroll Mode
```
Command:  Class 0x02, ID 0x94, Size 0x02
Args:     [0] = VARSTORE (0x01)
Response: args[1] = mode (0x00=tactile, 0x01=freespin)
TxnID:    0x1F
```

#### Set Scroll Mode
```
Command:  Class 0x02, ID 0x14, Size 0x02
Args:     [0] = VARSTORE (0x01), [1] = mode
TxnID:    0x1F
```

#### Get/Set Scroll Acceleration
```
Command:  Class 0x02, ID 0x96 (get) / 0x16 (set), Size 0x02
Args:     [0] = VARSTORE (0x01), [1] = enabled (0x00/0x01)
TxnID:    0x1F
```

#### Get/Set Scroll Smart Reel
```
Command:  Class 0x02, ID 0x97 (get) / 0x17 (set), Size 0x02
Args:     [0] = VARSTORE (0x01), [1] = enabled (0x00/0x01)
TxnID:    0x1F
```

---

### Class 0x04 - DPI

#### Get DPI
```
Command:  Class 0x04, ID 0x85, Size 0x07
Args:     [0] = storage (NOSTORE=0x00 or VARSTORE=0x01)
Response: args[0] = storage
          args[1-2] = DPI X (big-endian)
          args[3-4] = DPI Y (big-endian)
TxnID:    0x1F (Basilisk V3 X), 0x3F or 0xFF (others)
```

#### Set DPI
```
Command:  Class 0x04, ID 0x05, Size 0x07
Args:     [0] = storage
          [1-2] = DPI X (big-endian, 100-30000)
          [3-4] = DPI Y (big-endian, 100-30000)
          [5-6] = 0x00, 0x00
TxnID:    0x1F
```

#### Get DPI Stages
```
Command:  Class 0x04, ID 0x86, Size 0x26
Args:     [0] = VARSTORE (0x01)
Response: args[0] = storage
          args[1] = active stage (0-indexed)
          args[2] = number of stages (1-5)
          args[3+n*7] = stage data for each stage

Stage data (7 bytes each):
  [0] = stage number (0-indexed)
  [1-2] = DPI X (big-endian)
  [3-4] = DPI Y (big-endian)
  [5-6] = reserved (0x00)
TxnID:    0x1F
```

#### Set DPI Stages
```
Command:  Class 0x04, ID 0x06, Size 0x26
Args:     [0] = VARSTORE (0x01)
          [1] = active stage (0-indexed)
          [2] = count (1-5)
          [3+n*7] = stage data (same format as above)
TxnID:    0x1F
```

---

### Class 0x07 - Misc

#### Get Battery Level
```
Command:  Class 0x07, ID 0x80, Size 0x02
Args:     (none)
Response: args[0] = charging (0x00=no, 0x01=yes)
          args[1] = level (0-255, map to 0-100%)
TxnID:    0x1F
```

#### Get/Set Idle Time
```
Command:  Class 0x07, ID 0x83 (get) / 0x03 (set), Size 0x02
Args:     [0-1] = idle time in seconds (big-endian)
TxnID:    0x1F
```

#### Get/Set Low Battery Threshold
```
Command:  Class 0x07, ID 0x81 (get) / 0x01 (set), Size 0x01
Args:     [0] = threshold percentage
TxnID:    0x1F
```

---

## Unimplemented Commands

These commands are documented but not yet implemented in this tool.

### Button Remapping (Class 0x02)

**Status**: Protocol partially documented in [OpenRazer Issue #2031](https://github.com/openrazer/openrazer/issues/2031)

```
Command:  Class 0x02, ID 0x0d (non-analog) or 0x12 (analog)
Args:     [0] = memory slot / profile
          [1] = key/button identifier
          [2] = Fn/Hypershift flag
          [3-4] = actuation point (analog only)
          [5] = action type
          [6] = parameter length
          [7+] = action parameters

Action types (suspected):
  0x00 = Disable
  0x01 = Mouse button
  0x02 = Keyboard key
  0x03 = Multimedia key
  0x04 = Double-click
  0x05 = Fn key
  0x0C = Remap key (type 12)

Requires USB capture from Synapse to confirm exact format.
```

### Profile Management

**Status**: Not documented. Suspected commands:
- Profile switch
- Profile read/write
- Onboard memory storage

### RGB Lighting (Class 0x0F)

**Status**: Documented in OpenRazer but not implemented here.

```
Static Effect:
  Command: Class 0x0F, ID 0x02, Size varies
  Args: [0]=VARSTORE, [1]=LED_ID, [2]=effect, [3+]=params

Effects:
  0x00 = Off
  0x01 = Wave
  0x02 = Reactive
  0x03 = Breathing
  0x04 = Spectrum
  0x05 = Custom Frame
  0x06 = Static
```

---

## Device-Specific Notes

### Razer Basilisk V3 X HyperSpeed (0x00B9)

| Setting | Value |
|---------|-------|
| USB VID:PID | `1532:00B9` |
| Bluetooth VID:PID | `068e:00BA` |
| Transaction ID | `0x1F` |
| Max DPI | 18000 |
| DPI Stages | 5 |
| Poll Rates | 125, 500, 1000 Hz |

**Known Issues**:
- DPI button stops working when OpenRazer daemon is active ([#2701](https://github.com/openrazer/openrazer/issues/2701))
- Bluetooth configuration support is device/transport dependent

### Transaction ID by Device

| Device Type | Transaction ID |
|-------------|---------------|
| Modern wireless (2022+) | `0x1F` |
| Modern wired (2020+) | `0x3F` |
| Older devices | `0xFF` |

---

## Storage Modes

| Value | Name | Description |
|-------|------|-------------|
| `0x00` | NOSTORE | Apply immediately, don't persist |
| `0x01` | VARSTORE | Apply and save to device memory |

---

## BLE (Bluetooth Low Energy) Protocol

The standard 90-byte USB HID Feature Report protocol does **NOT** work over BLE. Testing with the Basilisk V3 X HyperSpeed (BT PID `0x00BA`) on macOS revealed a completely different transport.

### BLE HID Report Descriptor

The BLE HID descriptor contains **only Input reports** — zero Feature or Output reports. This means the USB feature report protocol cannot be used over BLE.

### GATT Services Discovered

Three services are present on the Basilisk V3 X HyperSpeed over BLE:

| Service | UUID | Purpose |
|---------|------|---------|
| Battery Service | `0x180F` | Standard battery level (0-100%) |
| HID Service | `0x1812` | Mouse input reports (movement, buttons, DPI status) |
| Vendor Service | `52401523-F97C-7F90-0E7F-6C6F4E36DB1C` | Razer vendor-specific (lighting, config?) |

### Battery Service (0x180F) — Working

The standard BLE Battery Service provides battery level readings:

```
Service:        0x180F (Battery Service)
Characteristic: 0x2A19 (Battery Level)
  Properties:   Read, Notify
  Value:        uint8 (0-100 percentage)
```

This is the most reliable way to read battery on BLE-connected Razer devices. It does not require the 90-byte Razer protocol and works directly via GATT.

**Limitation**: No charging status is available — only the level percentage.

### Passive HID Input Reports — Working (Read-Only)

DPI status can be read passively from HID input reports:

```
Report ID: 0x05
Format:    05 05 02 XX XX YY YY 00 00
  Byte 0:    Report ID (0x05)
  Byte 1:    Length/type (0x05)
  Byte 2:    Subtype (0x02 = DPI status)
  Bytes 3-4: DPI X (big-endian)
  Bytes 5-6: DPI Y (big-endian)
  Bytes 7-8: Reserved (0x00)
```

These reports are emitted when DPI changes (e.g., DPI button press). They can be read via `hidapi` on the BLE HID device path.

### Vendor GATT Service — Partially Explored

```
Service:        52401523-F97C-7F90-0E7F-6C6F4E36DB1C
Characteristics:
  Write:        52401524-F97C-7F90-0E7F-6C6F4E36DB1C (write-without-response)
  Notify 1:     52401525-F97C-7F90-0E7F-6C6F4E36DB1C (notify)
  Notify 2:     52401526-F97C-7F90-0E7F-6C6F4E36DB1C (notify)
```

This vendor service has been confirmed working for **lighting control on Razer keyboards** (BlackWidow V3 Mini uses the same service UUID). On mice, writes are accepted but DPI changes have not been achieved — likely requires an authentication handshake or different command format.

**Prior art**: The [razer-macos](https://github.com/1kc/razer-macos) project and community BlackWidow V3 Mini BLE tools use this same vendor service for keyboard lighting over BLE.

### macOS BLE Discovery

macOS hides paired BLE HID devices from normal BLE scans (`CBCentralManager.scanForPeripherals`). To find them, use:

```objc
// Objective-C / CoreBluetooth
[centralManager retrieveConnectedPeripheralsWithServices:@[batteryServiceUUID]];
```

```python
# Python via pyobjc
battery_uuid = CBUUID.UUIDWithString_("180F")
peripherals = manager.retrieveConnectedPeripheralsWithServices_([battery_uuid])
```

### What's Not Yet Possible Over BLE

| Feature | Status | Notes |
|---------|--------|-------|
| DPI write | Not working | Vendor GATT service accepts writes but no effect on DPI |
| DPI stages write | Not working | Same issue |
| Poll rate read/write | Not working | No known BLE path |
| Button remapping | Not working | No known BLE path |
| RGB lighting (mice) | Unknown | Vendor service may work (works for keyboards) |

### Future Work

To enable DPI/config writes over BLE:
1. Set up Windows VM with Razer Synapse and a BLE sniffer (e.g., nRF Sniffer)
2. Capture the Synapse BLE communication when changing DPI
3. Look for authentication handshake on the vendor GATT service
4. Document the command format for mice vs keyboards

---

## Reverse Engineering New Commands

To discover undocumented commands:

1. **Setup**: Windows VM with Razer Synapse, Wireshark with USBPcap
2. **Capture**: Filter by device VID/PID (`usb.idVendor == 0x1532`)
3. **Analyze**: Look for 90-byte feature reports
4. **Decode**: Map bytes to the report structure above

See: [OpenRazer Reverse Engineering Guide](https://github.com/openrazer/openrazer/wiki/Reverse-Engineering-USB-Protocol)

---

## References

- [OpenRazer Project](https://github.com/openrazer/openrazer)
- [OpenRazer Protocol Wiki](https://github.com/openrazer/openrazer/wiki/Reverse-Engineering-USB-Protocol)
- [OpenRazer Issue #2031 - Button Remapping](https://github.com/openrazer/openrazer/issues/2031)
- [OpenRazer Issue #2701 - Basilisk V3 X HyperSpeed](https://github.com/openrazer/openrazer/issues/2701)
- [razer-macos Project](https://github.com/1kc/razer-macos) (macOS IOKit reference)

---

## Changelog

- **2026-03-06**: Added BLE protocol section (Battery Service, vendor GATT service, passive HID reports)
- **2024-03-05**: Initial documentation based on OpenRazer and testing with Basilisk V3 X HyperSpeed
