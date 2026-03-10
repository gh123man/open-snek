# Razer USB HID Protocol Documentation

This document describes the USB HID protocol used by Razer mice, based on reverse engineering from the [OpenRazer](https://github.com/openrazer/openrazer) project and our own testing.

## Table of Contents

- [Overview](#overview)
- [Report Structure](#report-structure)
- [Command Classes](#command-classes)
- [Implemented Commands](#implemented-commands)
- [Unimplemented Commands](#unimplemented-commands)
- [Device-Specific Notes](#device-specific-notes)
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
Command:  Class 0x00, ID 0x81, Size 0x02
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

#### Get/Set Button Function
```
Get:      Class 0x02, ID 0x8C, Size 0x0A
Set:      Class 0x02, ID 0x0C, Size 0x0A
Args:     [0] = profile (`0x00` direct/effective layer, `0x01` persistent slot 1;
                        Basilisk V3 35K also validates persistent slots `0x02..0x05`)
          [1] = button slot
          [2] = hypershift flag (0x00 normal, 0x01 hypershift layer)
          [3] = function class
          [4] = function-data length (0..5)
          [5..9] = function data bytes
TxnID:    0x1F
```

Validated slot ids on Basilisk V3 X HyperSpeed (`0x00B9`): `0x01..0x05`, `0x09`, `0x0A`, `0x60`.

Validated slot ids on Basilisk V3 35K (`0x00CB`): `0x01..0x05`, `0x09`, `0x0A`, `0x0E`, `0x0F`, `0x34`, `0x35`, `0x60`, `0x6A`.
Observed control labels on `0x00CB`:
- `0x0E`: scroll-mode toggle
- `0x0F`: sensitivity clutch
- `0x34`: wheel tilt left
- `0x35`: wheel tilt right
- `0x60`: top DPI button
- `0x6A`: profile button

Validated function block examples:
- right click: `01 01 02 00 00 00 00`
- back button (default for slot `0x04`): `01 01 04 00 00 00 00`
- keyboard key `A` (HID `0x04`): `02 02 00 04 00 00 00`
- disable: `00 00 00 00 00 00 00`
- DPI cycle action: `06 01 06 00 00 00 00`
- Basilisk V3 35K wheel-tilt defaults (`0x34`, `0x35`): `01 01 02 00 00 00 00`
- Basilisk V3 35K sensitivity-clutch default (`0x0F`): `02 02 00 09 00 00 00`
- Basilisk V3 35K observed alternate DPI-button block (`0x60`): `04 02 0F 7B 00 00 00`
- Basilisk V3 35K profile-button default (`0x6A`): `12 01 01 00 00 00 00`

Client note:
- USB function blocks are not BLE `p0/p1/p2` payloads. Use `class,len,data[]` encoding directly.
- Legacy non-analog write command `0x02:0x0D` is still observed in ecosystem notes but is fallback-only on this device.
- Basilisk V3 35K (`0x00CB`) `0x02:0x8C` reads do not use one fixed payload offset for every slot. Observed 35K slots decode from `response[11..<18]`; treating `response[10...]` as the block causes false positives and mislabels on extra buttons such as `0x60` and `0x6A`.
- Always validate the echoed `profile` and `slot` bytes before decoding a `0x02:0x8C` read. This device will otherwise yield stale-looking success frames that can be mistaken for additional slots.
- Open Snek normalizes both `06 01 06 00 00 00 00` and the observed `0x60` variant `04 02 0F 7B 00 00 00` as the user-facing `DPI Cycle` action.
- Treat button access as three separate categories during new-device bring-up:
  - `editable`: validated over `0x02:0x0C`
  - `protocol-read-only`: readable from `0x02:0x8C`, but no validated writable path
  - `software-read-only`: fixed control exposed to software through auxiliary HID input/report paths rather than button-function writes
- On Basilisk V3 35K, OpenRazer documents keyboard-interface report-4 codes `0x50 = profile` and `0x51 = sensitivity clutch`. Those controls should be tracked as software-read-only even if their fixed defaults are also visible through `0x02:0x8C`.

#### Get Onboard Profile Summary
```
Command:  Class 0x00, ID 0x87, Size 0x00
Response: args[0] = active onboard profile (1-based)
          args[1] = reserved / zero in current captures
          args[2] = onboard profile count
TxnID:    0x1F
```

Observed on Basilisk V3 35K (`0x00CB`):
- response payload `01 00 05` on USB, indicating active profile `1` and `5` onboard profiles
- the corresponding low-bit write candidate (`0x00:0x07`) is not yet validated for active-profile switching

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
          args[1] = active stage ID (on Basilisk V3 X this is 1-indexed)
          args[2] = number of stages (1-5)
          args[3+n*7] = stage data for each stage

Stage data (7 bytes each):
  [0] = stage ID (commonly 1-indexed on Basilisk V3 X)
  [1-2] = DPI X (big-endian)
  [3-4] = DPI Y (big-endian)
  [5-6] = reserved (0x00)
TxnID:    0x1F
```

#### Set DPI Stages
```
Command:  Class 0x04, ID 0x06, Size 0x26
Args:     [0] = VARSTORE (0x01)
          [1] = active stage ID (must match a stage entry ID)
          [2] = count (1-5)
          [3+n*7] = stage data (same format as above)
TxnID:    0x1F
```

Client note: treat `active` as a stage-ID token and map it against entry `[0]` stage IDs. Do not assume a fixed zero-based index.

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

OpenRazer bounds:
  60..900 seconds
```

#### Get/Set Low Battery Threshold
```
Command:  Class 0x07, ID 0x81 (get) / 0x01 (set), Size 0x01
Args:     [0] = threshold percentage
TxnID:    0x1F

OpenRazer raw threshold clamp:
  0x0C..0x3F
Examples:
  0x0C ~= 5%
  0x26 ~= 15%
  0x3F ~= 25%
```

### Class 0x02 - Scroll Wheel Controls

#### Get/Set Scroll Mode
```
Command:  Class 0x02, ID 0x94 (get) / 0x14 (set), Size 0x02
Args:     [0] = VARSTORE (0x01), [1] = mode
Modes:    0x00=tactile, 0x01=freespin
```

#### Get/Set Scroll Acceleration
```
Command:  Class 0x02, ID 0x96 (get) / 0x16 (set), Size 0x02
Args:     [0] = VARSTORE (0x01), [1] = enabled (0x00/0x01)
```

#### Get/Set Scroll Smart Reel
```
Command:  Class 0x02, ID 0x97 (get) / 0x17 (set), Size 0x02
Args:     [0] = VARSTORE (0x01), [1] = enabled (0x00/0x01)
```

### Class 0x0F - Scroll LED Brightness and Effects

Validated on Basilisk V3 X HyperSpeed (`0x00B9`) and Basilisk V3 35K (`0x00CB`) over USB.

#### Get/Set Scroll LED Brightness
```
Get:      Class 0x0F, ID 0x84, Size 0x03
Set:      Class 0x0F, ID 0x04, Size 0x03
Args:     [0] = VARSTORE (0x01), [1] = LED ID (0x01 scroll wheel), [2] = brightness (0..255)
```

Validated LED IDs on `0x00B9`:
- `0x01`: supported for brightness read/write
- other tested IDs (`0x00`, `0x02..0x08`): failure status on brightness get

Validated LED IDs on `0x00CB`:
- `0x01`: scroll wheel
- `0x04`: logo
- `0x0A`: underglow

Client note:
- For whole-device USB lighting on Basilisk V3 35K, apply brightness/effect writes to all validated LED IDs (`0x01`, `0x04`, and `0x0A`).

#### Set Scroll LED Effects
```
Command:  Class 0x0F, ID 0x02, Size varies
Common:   [0] = VARSTORE (0x01), [1] = LED ID (0x01 scroll wheel), [2] = effect id
```

Observed-working payload families:
- none: `01 01 00 00 00 00`
- spectrum: `01 01 03 00 00 00`
- wave: `01 01 04 <dir> 28 00` (`dir` tested `0x01`/`0x02`)
- static: `01 01 01 00 00 01 <R> <G> <B>`
- reactive: `01 01 05 00 <speed 1..4> 01 <R> <G> <B>`
- breath random: `01 01 02 00 00 00`
- breath single: `01 01 02 01 00 01 <R> <G> <B>`
- breath dual: `01 01 02 02 00 02 <R1> <G1> <B1> <R2> <G2> <B2>`

---

## Unimplemented Commands

These commands are documented but not yet implemented in this tool.

### Advanced Button Action Catalog

`0x02:0x8C/0x0C` is now validated for base function-block transport, but the full action taxonomy
(macro families, media/consumer, analog variants) is still incomplete per device/firmware.

Open questions:
- exact behavior of advanced function classes (`0x03..0x05`, `0x07`, `0x09`, `0x0A`, `0x0F`, `0x12`)
- interoperability of legacy non-analog command `0x02:0x0D`
- per-device slot map differences beyond the validated Basilisk V3 X set

### Profile Management

**Status**: Not documented. Suspected commands:
- Profile switch
- Profile read/write
- Onboard memory storage

### RGB Lighting (Class 0x0F)

**Status**: Partially implemented. Scroll wheel LED brightness and effect families above are implemented and hardware-validated. Matrix-wide/custom-frame and multi-zone abstractions are still unimplemented.

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

## USB/BLE Parity Matrix

| Feature (User-Level) | USB (this spec) | BLE Vendor Spec | Script Status (`razer_usb.py` / `razer_ble.py`) | Gap |
|---|---|---|---|---|
| Serial read | `00:82` | Observed key `01 83 00 00` (read only) | Implemented in both scripts via HID path | Need stable BLE vendor mapping support across stacks |
| Firmware read | `00:81` | Not mapped in BLE vendor keys | Implemented in both scripts via HID path | Need BLE vendor command mapping |
| Device mode | `00:84/04` | Not mapped | Implemented in both scripts via HID path | Need BLE vendor command mapping |
| DPI XY | `04:85/05` | HID fallback + staged vendor path | Implemented in both scripts | BLE direct set still stack-dependent outside vendor staged path |
| DPI stages | `04:86/06` | `0B84` / `0B04` + op `0x26` | Implemented in both scripts | Mostly covered |
| Poll rate | `00:85/05` | No stable vendor mapping yet | Implemented in both scripts via HID path | Need BLE vendor mapping for reliable parity |
| Battery | `07:80` | Battery Service + observed vendor read key | Implemented in both scripts | Need unified source preference and charging semantics on BLE |
| Idle time | `07:83/03` | Not mapped | Implemented in both scripts via HID path | Need BLE vendor mapping |
| Low battery threshold | `07:81/01` | Not mapped | Implemented in both scripts via HID path | Need BLE vendor mapping |
| Scroll mode | `02:94/14` | Not mapped | Implemented in both scripts via HID path | Need BLE vendor mapping |
| Scroll acceleration | `02:96/16` | Not mapped | Implemented in both scripts via HID path | Need BLE vendor mapping |
| Scroll smart reel | `02:97/17` | Not mapped | Implemented in both scripts via HID path | Need BLE vendor mapping |
| Scroll LED brightness/effects | `0F:84/04`, `0F:02` | Not mapped | Implemented in both scripts via HID path | Need BLE vendor mapping for non-HID parity |
| Button remap | `0x02:0x8C/0x0C` validated for base function blocks | Vendor write path documented and implemented | BLE implemented, USB read/write validated for base categories | Need advanced action taxonomy validation (macro/media/analog) |
| RGB / matrix effects | OpenRazer-documented classes | Partial BLE raw lighting scalar only | Not implemented end-to-end in scripts | Need cross-transport effect model and commands |

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

### Razer Basilisk V3 35K (0x00CB)

| Setting | Value |
|---------|-------|
| USB VID:PID | `1532:00CB` |
| Transaction ID | `0x1F` |
| Max DPI | 35000 |
| DPI Stages | 5 |
| Poll Rates | 125, 500, 1000 Hz |
| Validated matrix LEDs | `0x01` scroll wheel, `0x04` logo, `0x0A` underglow |
| Extra validated button slots | `0x0E` scroll mode (protocol-read-only), `0x0F` sensitivity clutch (software-read-only / report-4 `0x51`), `0x34` wheel tilt left, `0x35` wheel tilt right, `0x60` DPI button, `0x6A` profile button (software-read-only / report-4 `0x50`) |

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


## References


- [OpenRazer Project](https://github.com/openrazer/openrazer)
- [OpenRazer Protocol Wiki](https://github.com/openrazer/openrazer/wiki/Reverse-Engineering-USB-Protocol)
- [OpenRazer Issue #2031 - Button Remapping](https://github.com/openrazer/openrazer/issues/2031)
- [OpenRazer Issue #2701 - Basilisk V3 X HyperSpeed](https://github.com/openrazer/openrazer/issues/2701)
- [razer-macos Project](https://github.com/1kc/razer-macos) (macOS IOKit reference)

---
