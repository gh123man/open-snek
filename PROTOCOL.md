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

### Vendor GATT Service

```
Service:        52401523-F97C-7F90-0E7F-6C6F4E36DB1C
Characteristics:
  Write:        52401524-F97C-7F90-0E7F-6C6F4E36DB1C (write-with-response only)
  Notify 1:     52401525-F97C-7F90-0E7F-6C6F4E36DB1C (read, notify)
  Notify 2:     52401526-F97C-7F90-0E7F-6C6F4E36DB1C (read, notify)
```

**Note**: Only 3 GATT services are exposed via CoreBluetooth: 180A (Device Info),
180F (Battery), and the vendor service. The HID service (0x1812) is **claimed by
macOS** and NOT accessible via GATT — it's handled entirely by the OS HID stack.

This same vendor service UUID appears on both Razer keyboards (e.g., BlackWidow V3 Mini)
and mice (e.g., Basilisk V3 X HyperSpeed, Basilisk X HyperSpeed). The only known
third-party implementation is [JiqiSun/RazerBlackWidowV3MiniBluetoothControllerApp](https://github.com/JiqiSun/RazerBlackWidowV3MiniBluetoothControllerApp) (Swift/macOS, lighting only).

#### Command Protocol

Commands use a **two-write pair**: an 8-byte init followed by a 10-byte payload.
Both writes go to the write characteristic (`...1524`) using write-with-response.
The writes must be sent on separate GATT write operations (not batched), with at
least ~50ms between them (the ATT write response from the first must complete
before the second is sent).

**Important**: Do NOT use write-without-response for the init — it will be silently
dropped and the payload will be treated as a standalone (failing) command.

**Init format (8 bytes)**:
```
13 0a 00 00 [mode_hi] [mode_lo] 00 00

Init bytes are STRICT:
  byte[0] = 0x13 (only value that works)
  byte[1] = 0x0a (only value that works; 20 other values tested, all fail)
  bytes[2-3] = 0x00 0x00 (padding)
  bytes[4-5] = mode selector (see below)
  bytes[6-7] = 0x00 0x00 (padding)

Working modes:
  10 03  — Lighting control (confirmed: changes scroll wheel LED)
  10 04  — DANGEROUS: freezes mouse input (still BLE-connected, no movement)
  10 05  — Unknown (accepts all payloads, no observable effect)
  10 06  — Unknown (accepts all payloads, no observable effect)

Failing modes (error 0x03):
  10 00, 10 01, 10 02, 10 07, 10 08, 10 09, 10 0a, 10 0b,
  10 0c, 10 0d, 10 0e, 10 0f

Parameter error (0x05):
  20 XX, 04 XX
```

**Response format (20 bytes, on notify1 / `...1525`)**:
```
[echo_byte0] 00 00 00 00 00 00 [status] [12-byte session token]

echo_byte0: First byte of the INIT command (0x13 for valid pairs)
Status values:
  0x02 = Success
  0x03 = Error (unknown command / bad format)
  0x05 = Parameter error

Session token: Changes on each BT reconnect.
  Example: 71 f8 b9 97 94 b6 eb 41 6a ff 9b 6b
```

**Unsolicited notification on subscribe**: `01 00 00 00 00 00 00 03 [token]`
(Always status 0x03/ERR — this is normal, not an error condition)

**Notify2 read value** (8 bytes): `aa ef 6d 16 2c 27 4f 48`
(Purpose unknown, possibly device identifier; constant across sessions)

#### Session State and Recovery

The vendor GATT service can enter a **permanent error state** where all commands
return ERR (status 0x03), including previously working lighting commands. This
appears to happen after sending many commands (especially failed ones) in rapid
succession during probing.

**Recovery**: Toggle Bluetooth off and back on on the mouse (physical switch).
A software disconnect/reconnect via CoreBluetooth is NOT sufficient — the device
must be power-cycled. After reconnecting, the session token changes and the GATT
service accepts commands again.

This matches the BlackWidow V3 Mini BLE app's setup instructions: "Toggle the
keyboard's Bluetooth off, then back on."

#### Payload Validation Behavior

In working modes (10/03, 10/05, 10/06), the device accepts **any** 10-byte payload
without error. It does NOT validate payload content — only the mode is checked.
Payloads that don't match a known command format are silently ignored.

This means OK responses do NOT indicate the command had any effect — only that the
mode was valid.

Mode 10/04 is more selective (rejects byte0=0x00) but still accepts most payloads.
**WARNING**: Mode 10/04 can freeze mouse input.

#### Lighting Payload (mode 10 03) — Confirmed Working

```
Payload (10 bytes): [effect] [param1] [param2] [color_count] [R] [G] [B] [R2] [G2] [B2]

Effects:
  0x01 = Static      e.g., 01 00 00 01 ff ff ff 00 00 00 (white)
  0x02 = Breathe     e.g., 02 00 00 01 00 ff 00 00 00 00
  0x03 = Spectrum     e.g., 03 00 00 00 00 00 00 00 00 00
  0x04 = Wave        e.g., 04 02 28 00 00 00 00 00 00 00
  0x05 = Reactive    e.g., 05 00 03 01 00 ff 00 00 00 00

LED off: 01 00 00 01 00 00 00 00 00 00 (static black)
```

**Confirmed on Basilisk V3 X HyperSpeed**: Static and spectrum effects change the
scroll wheel LED. Sending static black turns LED off. The LED brightness may
decrease after sending many commands in sequence.

#### DPI Write Testing — Exhaustive Results

Extensive testing confirmed that **DPI cannot be changed** through the vendor GATT
service on the Basilisk V3 X HyperSpeed. The following approaches were all tried
with HID DPI sniffing active (monitoring report 0x05 0x05 0x02):

| Approach | Modes Tested | Payloads | DPI Changes |
|----------|-------------|----------|-------------|
| byte0=0x08 + DPI X/Y big-endian | 10/03, 04, 05, 06 | 400-3200 DPI | 0 |
| byte0=0x00-0x05 + DPI data | 10/03, 04, 05 | 800 DPI | 0 |
| USB class+id (0x04 0x05) as payload | 10/03, 05, 06 | 800 DPI | 0 |
| USB GET DPI (0x04 0x85) as payload | 10/03, 05, 06 | read | 0 |
| DPI/100 single byte | 10/03, 05, 06 | 4,8,16,32 | 0 |
| DPI at various byte positions | 10/06 | 800 DPI | 0 |
| Full 90-byte USB report | (direct) | various | 0 |
| Chunked USB report (20, 10 bytes) | (direct) | various | 0 |
| Raw DPI bytes (2-8 bytes) | (direct) | various | 0 |
| HID output reports via hidapi | all report IDs | 800 DPI | all return -1 |
| HID feature reports via hidapi | all report IDs | GET DPI | all return -1 |

**Conclusion**: The vendor GATT service on the Basilisk V3 X HyperSpeed appears
to be **lighting-only**. DPI configuration over BLE may require access to the HID
service (0x1812), which macOS claims exclusively. On Linux, this service may be
accessible.

#### HID Report Limitations on BLE

The BLE HID descriptor contains **only Input reports**:
- No Feature reports (cannot send/receive USB-style configuration)
- No Output reports (cannot send commands via HID)
- All HID output/feature report writes via hidapi return -1
- All HID feature report reads via hidapi raise OSError

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

### Current BLE Capabilities

| Feature | Status | Notes |
|---------|--------|-------|
| Battery read | Working | Via BLE Battery Service (0x180F) |
| DPI read | Working | Passive HID input reports (report 0x05) |
| LED/Lighting | Working | Vendor GATT service, mode `10 03` |
| DPI write | **Not possible on macOS** | Vendor GATT is lighting-only; HID service claimed by OS |
| Poll rate | Not possible on macOS | No known BLE path |
| Button remapping | Not possible on macOS | No known BLE path |

---

## Windows BLE Driver Architecture

Analysis of the Razer driver stack on Windows 11 reveals how Synapse communicates
with the mouse over BLE. This is critical for understanding the config write path.

### GATT Services (from Windows device enumeration)

| Service | UUID | GATT Handle | Windows Driver |
|---------|------|-------------|----------------|
| Generic Access | `0x1800` | 1 | UmPass |
| Generic Attribute | `0x1801` | 10 | UmPass |
| Device Information | `0x180A` | 14 | UmPass |
| Battery Service | `0x180F` | 19 | UmPass |
| **HID Service** | **`0x1812`** | **23** | **mshidumdf** (+ Razer filter) |
| Vendor Service | `52401523...` | 59 | UmPass |

The HID service (handle 23) is the only one with a specialized driver stack.
All other services use the generic `UmPass` (User-Mode Pass-through) driver.

### Driver Stack

```
┌──────────────────────────────────────────────────────┐
│  Razer Synapse (usermode)                            │
│  Communicates via IOCTLs to RZCONTROL device         │
├──────────────────────────────────────────────────────┤
│  RzCommon.sys                                        │
│  Manages RZCONTROL virtual bus device                │
│  Custom class GUID: {1750F915-5639-497C-...}         │
├──────────────────────────────────────────────────────┤
│  RzDev_00ba.sys  (UPPER filter on Col01 mouse)       │
│  Creates RZCONTROL child device                      │
│  Sets: ControlDevice=1, DeviceType=1                 │
├──────────────────────────────────────────────────────┤
│  HID Collection 01 (Mouse)                           │
│  + Col02 (Pointer), Col03-05, Col06 (Keyboard)       │
├──────────────────────────────────────────────────────┤
│  mshidumdf  (Microsoft HID minidriver for UMDF)      │
├──────────────────────────────────────────────────────┤
│  RzDev_00ba.sys  (LOWER filter on BLE HID parent)    │
│  Flags: DkmKeyDevice, DkmMouseDevice, MouseExDevice  │
├──────────────────────────────────────────────────────┤
│  WudfRd + HidOverGatt  (Microsoft BLE-to-HID)        │
│  Translates HID reports to/from GATT characteristics  │
├──────────────────────────────────────────────────────┤
│  BthLEEnum  (Windows BLE enumerator)                 │
│  GATT transport layer                                │
└──────────────────────────────────────────────────────┘
```

### Key Observations

1. **`RzDev_00ba.sys` sits at TWO levels**: lower filter on the BLE HID parent device
   AND upper filter on HID Collection 01 (mouse) and Collection 06 (keyboard).

2. **RZCONTROL virtual bus**: The upper filter creates a child device on the RZCONTROL
   bus (`RZCONTROL\VID_068E&PID_00BA&MI_00`). Synapse communicates through this device
   via IOCTLs, which flow down through `RzDev_00ba` to `HidOverGatt` to GATT writes.

3. **HidOverGatt**: Microsoft's WUDF driver that translates HID Feature/Output reports
   into GATT write operations on the HID service's Report characteristics. This is how
   Razer's 90-byte protocol reaches the mouse over BLE.

4. **Six HID Collections** (from the BLE HID Report Map):
   - Col01: Mouse (Generic Desktop / Mouse)
   - Col02: Pointer (Generic Desktop / Pointer)
   - Col03: Consumer Control
   - Col04: System Control
   - Col05: Vendor (Generic Desktop / Undefined) — Report ID 4
   - Col06: Keyboard (Generic Desktop / Keyboard)

5. **The INF files** (`razer_bt_dump/oem64.inf`, `oem66.inf`) contain the full
   driver configuration. `oem64.inf` installs the lower filter with `MouseEx_ReportId=1`.

### BLE HID Report Descriptor (254 bytes)

Extracted via IOKit on macOS. Six report IDs, **all Input-only**:

| Report ID | Collection | Size | Type |
|-----------|-----------|------|------|
| 1 | Mouse (buttons + X/Y/wheel) | 9 bytes | Input |
| 2 | Consumer Control | 7 bytes | Input |
| 3 | System Control | 8 bytes | Input |
| 4 | Vendor (Generic Desktop, Usage 0x00) | 8 bytes | Input |
| 5 | Vendor (Generic Desktop, Usage 0x00) | 8 bytes | Input |
| 6 | Keyboard | 7 bytes | Input |

**Critical**: The descriptor declares `MaxFeatureReportSize=1` and `MaxOutputReportSize=1`.
There are **zero Feature Reports and zero Output Reports** in the BLE HID descriptor.

This means the HID Report Map visible to the OS does NOT include Razer's 90-byte
protocol. On Windows, `HidOverGatt` + `RzDev_00ba` likely inject or intercept
reports at the driver level, writing directly to GATT characteristics that have
Feature-type Report Reference descriptors — even though the Report Map doesn't
advertise them.

### What This Means

The 90-byte Razer protocol almost certainly travels over BLE through **GATT
characteristics within the HID service (0x1812)** that have Feature-type Report
Reference descriptors. These characteristics exist at the GATT level but are NOT
described in the HID Report Map. The Razer Windows driver (`RzDev_00ba.sys`) knows
about them because it's purpose-built for this device — it doesn't rely on the
Report Map to discover writable characteristics.

---

## What We Need To Uncover Next

### 1. Enumerate HID Service GATT Characteristics (Linux/Steam Deck)

**This is the critical next step.** We need to see the actual GATT characteristics
inside the HID service (0x1812) — specifically looking for:

- Report characteristics (`0x2A4D`) with **Feature-type** (0x03) or **Output-type**
  (0x02) Report Reference descriptors (`0x2908`)
- Their GATT handles and properties (read/write/notify)

**Why Linux**: macOS hides the HID service entirely from CoreBluetooth. Windows
restricts raw GATT access when a HID driver is loaded. Linux (BlueZ) provides
unrestricted access to all GATT characteristics.

**Tool**: `enumerate_hid_gatt_linux.py` — designed to run on a Steam Deck or any
Linux machine with BlueZ and Python 3. It discovers Razer devices, enumerates all
characteristics in the HID service, reads Report Reference descriptors, and identifies
Feature/Output reports.

**Expected outcome**: We should find 1-2 Report characteristics with Feature-type
references. Their GATT handles are what `HidOverGatt` writes the 90-byte protocol to.

### 2. Test 90-byte Protocol on Discovered Feature Reports

Once we know the GATT handles of Feature Report characteristics:

1. Write a 90-byte Razer "get serial" command to the Feature Report characteristic
2. Read back from the same characteristic after ~100ms
3. If we get a valid response (status 0x02, matching TxID), the protocol works

### 3. Verify DPI Write Over BLE

If step 2 succeeds, send a DPI set command and verify the mouse changes DPI.
This would confirm the full write path works without any OS-specific driver.

### 4. Port Back to macOS (If Possible)

If the GATT handles are known, we might be able to write to them from macOS using
IOKit at a lower level than CoreBluetooth — potentially via `IOBluetoothDevice`
or by opening the GATT service's IOService entry directly. This is speculative.

---

## References

- [OpenRazer Project](https://github.com/openrazer/openrazer)
- [OpenRazer Protocol Wiki](https://github.com/openrazer/openrazer/wiki/Reverse-Engineering-USB-Protocol)
- [OpenRazer Issue #2031 - Button Remapping](https://github.com/openrazer/openrazer/issues/2031)
- [OpenRazer Issue #2701 - Basilisk V3 X HyperSpeed](https://github.com/openrazer/openrazer/issues/2701)
- [razer-macos Project](https://github.com/1kc/razer-macos) (macOS IOKit reference)

---

## Changelog

- **2026-03-06**: Added Windows BLE driver architecture:
  - Documented full driver stack (RzDev_00ba.sys filter driver, RZCONTROL virtual bus, HidOverGatt)
  - Mapped all 6 GATT services with handles from Windows device enumeration
  - Analyzed BLE HID Report Descriptor (254 bytes, 6 report IDs, all Input-only)
  - Identified that Razer protocol uses GATT Feature Report characteristics not advertised in Report Map
  - Added concrete "What We Need To Uncover Next" section with actionable steps
- **2026-03-06**: Comprehensive BLE vendor GATT protocol documentation:
  - Confirmed 4 working modes (10/03 lighting, 10/04 dangerous, 10/05 unknown, 10/06 unknown)
  - Documented session state/recovery behavior (BT power cycle required)
  - Exhaustive DPI write testing across all modes and payload formats — DPI is NOT configurable via vendor GATT
  - Documented HID report limitations (no Feature/Output reports over BLE)
  - Added init byte strictness (only 0x13/0x0a works), payload validation behavior
  - Updated capabilities table with definitive status
- **2026-03-06**: Added BLE protocol section (Battery Service, vendor GATT service, passive HID reports)
- **2024-03-05**: Initial documentation based on OpenRazer and testing with Basilisk V3 X HyperSpeed
