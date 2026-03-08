# Razer BLE Protocol Specification

## 1. Scope

This document describes BLE behavior implemented in `razer_ble.py`:
- Vendor GATT command channel (`...1524` write / `...1525` notify)
- BLE Battery Service fallback (`0x180F`)
- Passive HID input parsing used for DPI sniff/read fallback

Target device family in current captures:
- Basilisk V3 X HyperSpeed BT (`VID=0x068E`, `PID=0x00BA`)

## 2. GATT Endpoints

| Item | UUID | Handle (Windows capture) | Access |
|---|---|---:|---|
| Vendor Service | `52401523-F97C-7F90-0E7F-6C6F4E36DB1C` | `0x003B` service area | Service |
| Vendor Write Characteristic | `52401524-F97C-7F90-0E7F-6C6F4E36DB1C` | `0x003D` | Write Request |
| Vendor Notify Characteristic | `52401525-F97C-7F90-0E7F-6C6F4E36DB1C` | `0x003F` | Notify |
| Notify CCCD | `0x2902` | `0x0040` | Write `0x0100` |

## 3. Session Rules

- Enable notifications on `...1525` before command writes.
- Requests are keyed by request id (`req`, byte 0).
- `razer_ble.py` starts request IDs at `0x30`, increments modulo `0x100`.
- Success ACK is notify header status `0x02` with matching `req`.

## 4. Frame Formats

### 4.1 Request Header (8 bytes)

```text
byte0  req_id
byte1  op
byte2  0x00
byte3  0x00
byte4  key0
byte5  key1
byte6  key2
byte7  key3
```

### 4.2 Notify Header (20 bytes)

```text
byte0   req_id echo
byte1   payload_length
byte2-6 reserved
byte7   status (0x02 success, 0x03 error, 0x05 param error)
byte8-19 session/aux bytes
```

### 4.3 Continuation Notifies (20 bytes)

- Payload frames follow the header notify.
- `razer_ble.py` concatenates continuation frames in arrival order.

## 5. Generic Operations

### 5.1 Generic Read

- Write one header: `[req, 0x00, 0x00, 0x00, key0, key1, key2, key3]`
- Expect notify header + payload notify frame(s).

### 5.2 Generic Scalar Write

- Header: `[req, op, 0x00, 0x00, key0, key1, key2, key3]`
- Follow-up payload write: scalar bytes (`u8` or `u16` LE).
- Success: ACK notify with matching `req` and status `0x02`.

### 5.3 Button Binding Write

Two-write sequence:
1. Header select: `[req, 0x0A, 0x00, 0x00, 0x08, 0x04, 0x01, slot]`
2. 10-byte action payload

### 5.4 DPI Stage Table Read/Write

- Get header: `[req, 0x00, 0x00, 0x00, 0x0B, 0x84, 0x01, 0x00]`
- Set header: `[req, 0x26, 0x00, 0x00, 0x0B, 0x04, 0x01, 0x00]`
- Set payload: 38 bytes split as 20 + 18 writes.

## 6. Command Key Map (Implemented)

| Feature | Get key (`byte4..7`) | Set key (`byte4..7`) | Set op | Payload |
|---|---|---|---:|---|
| DPI stage table | `0B 84 01 00` | `0B 04 01 00` | `0x26` | 38 bytes |
| Power timeout raw | `05 84 00 00` | `05 04 00 00` | `0x02` | `u16 LE` |
| Sleep timeout raw | `05 82 00 00` | `05 02 00 00` | `0x01` | `u8` |
| Lighting raw | `10 85 01 01` | `10 05 01 00` | `0x01` | `u8` |
| Button bind (slot) | n/a | `08 04 01 <slot>` | `0x0A` | 10 bytes |

Observed extra read keys (capture-backed, not full APIs in code):
- Battery raw: `05 81 00 01` (`u8`)
- Status flag: `05 80 00 01` (`u8`)
- Serial key: `01 83 00 00` (ASCII payload)

## 7. Payload Specs

### 7.1 DPI Stage Set Payload (38 bytes)

```text
[active][count]
repeat 5x:
  [stage_id][dpi_x_le16][dpi_y_le16][0x00][marker]
[tail]
```

Conventions in current implementation:
- `stage_id`: `0..4`
- marker on stage 4 only (others `0x00`)
- trailing tail byte `0x00`

Read-side parsing in `razer_ble.py` accepts:
- full staged blob (`>=37` bytes)
- short single-stage blob (`>=7` bytes), then mirrors to 5 internal slots

### 7.2 Button Action Payload (10 bytes)

```text
[profile=0x01][slot][layer=0x00][action_type][p0_le16][p1_le16][p2_le16]
```

Action families exposed by helpers:
- `0x01`: mouse-button action
- `0x02`: simple keyboard action
- `0x0D`: extended keyboard/action variant

Observed mouse mapping (`action_type=0x01`):
- `p0=0x0101` left click
- `p0=0x0201` right click

## 8. Non-Vendor BLE Paths Used by `razer_ble.py`

### 8.1 BLE Battery Service Fallback

If HID battery read fails on BT, code reads Battery Service `0x180F` level (0-100).

### 8.2 Passive HID DPI Read/Sniff

Code parses input reports matching prefix:
- `05 05 02 xx xx yy yy ...`
- DPI X=`xx xx` (big-endian in packet order), DPI Y=`yy yy`

This powers:
- `get_dpi()` fallback on Bluetooth
- `--sniff-dpi`

### 8.3 HID Command Path on Bluetooth Interfaces

`get/set_poll_rate` and direct `get/set_dpi` still use the 90-byte HID command path.
Behavior is backend/OS dependent for BT HID interfaces.

## 9. Slot and Feature Coverage

- DPI stage table: read/write with active-stage handling.
- Button rebinding validated on slots `0x02`, `0x03`, `0x04`, `0x05`.
- Slot `0x02` default restore is implemented as explicit right-click payload.

## 10. Status Codes

| Status | Meaning |
|---:|---|
| `0x02` | Success |
| `0x03` | Error |
| `0x05` | Parameter error / unsupported parameter |

## 11. Current Gaps

- Full semantic catalog for all remaining key bytes (`byte4..7`).
- Complete action taxonomy for button payloads (media/macro/system families).
- Synapse UI-unit mapping for raw scalar fields.
- More cross-device validation beyond PID `0x00BA`.

## 12. USB/BLE Parity Matrix

| Feature (User-Level) | USB Command(s) | BLE Mapping | Script Status (`razer_usb.py` / `razer_ble.py`) | Gap |
|---|---|---|---|---|
| Serial read | `00:82` | Observed read key `01 83 00 00` (read-only observed) | Implemented in both scripts via HID path | Need stable vendor-path mapping |
| Firmware read | `00:81` | Not mapped | Implemented in both scripts via HID path | Need BLE vendor mapping |
| Device mode | `00:84/04` | Not mapped | Implemented in both scripts via HID path | Need BLE vendor mapping |
| DPI XY | `04:85/05` | Passive HID read + HID set fallback | Implemented in both scripts | Need fully reliable BLE set path |
| DPI stages | `04:86/06` | `0B84` / `0B04` + `op=0x26` | Implemented in both scripts | Mostly covered |
| Poll rate | `00:85/05` | HID fallback only | Implemented in both scripts | Need vendor mapping for reliability |
| Battery | `07:80` | Battery Service + observed `05 81 00 01` | Implemented in both scripts | Need charging-state mapping on vendor path |
| Idle time | `07:83/03` | Not mapped | Implemented in both scripts via HID path | Need BLE vendor mapping |
| Low battery threshold | `07:81/01` | Not mapped | Implemented in both scripts via HID path | Need BLE vendor mapping |
| Scroll mode | `02:94/14` | Not mapped | Implemented in both scripts via HID path | Need BLE vendor mapping |
| Scroll acceleration | `02:96/16` | Not mapped | Implemented in both scripts via HID path | Need BLE vendor mapping |
| Scroll smart reel | `02:97/17` | Not mapped | Implemented in both scripts via HID path | Need BLE vendor mapping |
| Scroll LED brightness/effects | `0F:84/04`, `0F:02` | Not mapped | Implemented in both scripts via HID path | Need BLE vendor mapping for non-HID parity |
| Button remap | USB experimental raw writer only | `08 04 01 <slot>` + payload | BLE implemented + USB experimental writer | Need USB action taxonomy + shared safe helpers |
| Lighting / matrix | USB class `0x0F` partly implemented (scroll LED) | Raw scalar lighting key only (`10 85` / `10 05`) | USB scroll LED + partial BLE scalar | Need full effect model on both transports |

## 13. `razer_ble.py` Feature Overlap Checklist

| `razer_ble.py` feature | Protocol section |
|---|---|
| Vendor request header + notify ACK handling | Sections 3-5 |
| Generic scalar get/set helpers (`_bt_get_scalar`, `_bt_set_scalar`) | Sections 5.1, 5.2, 6 |
| DPI stage table get/set (`_bt_get_dpi_stages_blob`, `_bt_set_dpi_stages_blob`) | Sections 5.4, 7.1 |
| Stage payload parse/build (`_parse_bt_stage_table`, `_build_bt_stage_payload`) | Section 7.1 |
| Button bind raw + helpers (`set_button_*`) | Sections 5.3, 7.2 |
| Raw power/sleep/lighting APIs | Section 6 |
| Scroll LED HID helpers (`get/set_scroll_led_*`) | Sections 8.3, 12 |
| BLE Battery Service fallback (`get_battery_ble`, `get_battery`) | Section 8.1 |
| Passive DPI fallback/sniff (`get_dpi`, `sniff_bt_dpi_values`) | Section 8.2 |
| Poll-rate + direct DPI HID path behavior on BT | Section 8.3 |
