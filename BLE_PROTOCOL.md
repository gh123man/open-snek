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
- Issue commands sequentially per device connection. Parallel in-flight vendor transactions can interleave notifies and corrupt command correlation.
- Consumer recommendation: reject malformed DPI payload reads (for example `0` DPI stage entries) and retry once before exposing state to UI.

## 4. Frame Formats

### 4.1 Request Header (8 bytes)

```text
byte0  req_id
byte1  payload_length_for_followup_write (0x00 for reads)
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
- In capture-backed reads (`power-lighting.pcapng`), short scalar reads use:
  - notify header (req echo + payload length), then
  - one data notify where first `payload_length` bytes are the scalar payload.

## 5. Generic Operations

### 5.1 Generic Read

- Write one header: `[req, 0x00, 0x00, 0x00, key0, key1, key2, key3]`
- Expect notify header + payload notify frame(s).

### 5.2 Generic Scalar Write

- Header: `[req, payload_len, 0x00, 0x00, key0, key1, key2, key3]`
- Follow-up payload write: scalar bytes (`u8` or `u16` LE).
- Success: ACK notify with matching `req` and status `0x02`.

### 5.3 Button Binding Write

Two-write sequence:
1. Header select: `[req, 0x0A, 0x00, 0x00, 0x08, 0x04, 0x01, slot]`
2. 10-byte action payload

Capture-backed slots now include `0x60` (DPI-cycle control) in addition to
the previously observed low slots.

Transport note (capture-backed):
- Both writes are ATT Write Request (`0x12`, with response) on this firmware/capture set.
- The 10-byte action payload write does not need ATT Write Command (`0x52`) to succeed.

### 5.4 DPI Stage Table Read/Write

- Get header: `[req, 0x00, 0x00, 0x00, 0x0B, 0x84, 0x01, 0x00]`
- Set header: `[req, 0x26, 0x00, 0x00, 0x0B, 0x04, 0x01, 0x00]`
- Set payload: 38 bytes split as 20 + 18 writes.

## 6. Command Key Map (Implemented)

| Feature | Get key (`byte4..7`) | Set key (`byte4..7`) | Set len (byte1) | Payload |
|---|---|---|---:|---|
| DPI stage table | `0B 84 01 00` | `0B 04 01 00` | `0x26` | 38 bytes |
| Idle time raw | `05 84 00 00` | `05 04 00 00` | `0x02` | `u16 LE` |
| Low battery threshold raw | `05 82 00 00` | `05 02 00 00` | `0x01` | `u8` |
| Lighting raw | `10 85 01 01` | `10 05 01 00` | `0x01` | `u8` |
| Lighting mode raw | n/a | `10 03 00 00` | `0x04` | `u32 LE` (capture value: `08`) |
| Lighting frame stream | n/a | `10 04 00 00` | `0x08` | `04 00 00 00 [M][R][G][B]` |
| Battery raw | `05 81 00 01` | n/a | n/a | `u8` |
| Battery status raw | `05 80 00 01` | n/a | n/a | `u8` |
| Device mode raw (read fallback) | `01 82 00 00` | `01 02 00 00` (candidate) | `0x02` | `u16 LE` |
| Button bind (slot) | n/a | `08 04 01 <slot>` | `0x0A` | 10 bytes |

Observed extra read key (capture-backed, not full API in code):
- Serial key: `01 83 00 00` (ASCII payload)

## 7. Payload Specs

### 7.1 DPI Stage Set Payload (38 bytes)

```text
[active][count]
repeat 5x:
  [stage_id][dpi_x_le16][dpi_y_le16][0x00][marker]
[tail]
```

Protocol observations:
- `stage_id` is present per entry and should be treated as device-provided metadata.
- capture-backed reads commonly use `stage_id` values like `1..N`.
- active byte in read blobs often matches one of the entry `stage_id` bytes
  (do not assume fixed 0-index or 1-index semantics across all states).
- marker is commonly observed on final entry and may be omitted when read payload length is short by one.
- trailing tail byte is present on 38-byte set payloads.

Implementation behavior (current code):

| Consumer | Active decode | Stage IDs on set payload |
|---|---|---|
| `razer_ble.py` | raw `active` clamped into `0..count-1` | emits `0..4` |
| `OpenSnekMac` / `OpenSnekProbe` | maps active byte to entry stage IDs (with fallback normalization) | preserves IDs from current snapshot |

Read-side parsing in `razer_ble.py` accepts:
- variable-length staged blob (`2 + count*7` bytes), commonly:
  - `16` bytes for 2 stages
  - `23` bytes for 3 stages
  - `37` bytes for 5 stages
- capture-backed reads can report `payload_length` one byte short
  (`15/22/36` for `2/3/5` stages), omitting the final entry marker byte;
  consumers should parse by declared `count` as long as DPI X/Y bytes are present
- short single-stage blob (`>=7` bytes), then mirrors to 5 internal slots

Observed 2-stage example (active 0, values 800/6400):
`00 02 00 20 03 20 03 00 00 01 00 19 00 19 00 00`

### 7.2 Button Action Payload (10 bytes)

```text
[profile=0x01][slot][layer_or_plane][action_type][p0_le16][p1_le16][p2_le16]
```

Action families exposed by helpers:
- `0x00`: clear/default layer entry (observed with `layer=0x01`)
- `0x01`: mouse-button action
- `0x02`: simple keyboard action
- `0x0D`: keyboard turbo/action variant (`basic-rebind.pcapng`)
- `0x0E`: mouse turbo action (`right-click-turbo.pcapng`)

Observed mouse mapping (`action_type=0x01`):
- `p0=0x0101` left click
- `p0=0x0201` right click
- `p0=0x0301` middle click (inferred from existing action-id progression + USB/OpenRazer family)
- `p0=0x0901` scroll up (`scroll-up-down-rebind.pcapng`, slot `0x09`)
- `p0=0x0A01` scroll down (`scroll-up-down-rebind.pcapng`, slot `0x0A`)
- slot `0x02` default restore is wire-identical to right click (`01 02 00 01 0102 0000 0000`).

Observed keyboard mapping:
- simple key: `01 <slot> 00 02 0200 <hid_key_le16> 0000`
  (`right-click-bind.pcapng`, `basic-rebind.pcapng`)
- turbo key: `01 <slot> 00 0D 0400 <hid_key_le16> <rate_le16>`
  (`basic-rebind.pcapng`, inferred as keyboard turbo from matching key+rate shape)

Observed turbo mapping:
- mouse turbo right-click (`right-click-turbo.pcapng`, slot `0x02`):
  - `01 02 00 0E 0301 8E00 0000`
  - `01 02 00 0E 0301 3E00 0000`
  - `p1` behaves as turbo-rate scalar changed by Synapse slider.
- keyboard turbo (`basic-rebind.pcapng`, slot `0x03`):
  - `01 03 00 0D 0400 0800 8E00`

Observed layer-clear mapping (`all-key-binding-functions.pcapng`):
- `01 <slot> 01 00 0000 0000 0000`
- interpreted as clearing layer-1 override for that slot.

Observed slot-specific default mapping (`dpi-cycle-left-click-default.pcapng`):
- slot `0x60` restore payload: `01 60 00 06 0106 0000 0000`
- this differs from mouse-button slot defaults, which resolve to slot-native `action_type=0x01` payloads.

Implemented default restore mapping (slot-native):
- `0x01` -> left click (`p0=0x0101`)
- `0x02` -> right click (`p0=0x0201`)
- `0x03` -> middle click (`p0=0x0301`)
- `0x04` -> back (`p0=0x0401`)
- `0x05` -> forward (`p0=0x0501`)
- `0x09` -> scroll up (`p0=0x0901`)
- `0x0A` -> scroll down (`p0=0x0A01`)

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

`razer_ble.py` still exposes `get/set_poll_rate` and direct `get/set_dpi` via the
90-byte HID command path, but behavior is backend/OS dependent for BT HID interfaces.

Latest validation (macOS, Basilisk V3 X `0x00BA`, 2026-03-08):
- transport probe succeeds
- command-path reads return `None`
- command-path writes return `False`

This includes poll rate, idle/threshold, and scroll LED HID controls.
It also includes direct HID `set_dpi`; BT HID DPI apply is not reliable on this stack.

Vendor GATT path in the same environment works when enabled:
- raw idle-time/threshold/lighting read/write
- battery raw/status read keys

## 9. Slot and Feature Coverage

- DPI stage table: read/write with active-stage handling.
- Button rebinding validated on slots `0x01`, `0x02`, `0x03`, `0x04`, `0x05`, `0x09`, `0x0A`, and `0x60` on Basilisk V3 X BT firmware.
- Slot `0x02` default restore is implemented as explicit right-click payload.
- Slot `0x60` (DPI cycle control) uses a capture-backed special default payload (`action 0x06`, `p0=0x0601`).
- Layer-clear payload (`layer=0x01`, `action=0x00`) observed on slots `0x04` and `0x05`.
- `hypershift-bind.pcapng` / `hypershift-full-hid.pcapng` replay the same apply triplet:
  - slot `0x05` layer-clear payload (`01 05 01 00 0000 0000 0000`)
  - slot `0x04` layer-clear payload (`01 04 01 00 0000 0000 0000`)
  - slot `0x02` right-click payload (`01 02 00 01 0102 0000 0000`)
- `scroll-up-down-rebind.pcapng` confirms wheel-button slot rebinding on BLE:
  - slot `0x09`: left click (`p0=0x0101`) and scroll up (`p0=0x0901`)
  - slot `0x0A`: left click (`p0=0x0101`) and scroll down (`p0=0x0A01`)
- `right-click-turbo.pcapng` confirms turbo mouse payload family (`action=0x0E`) and rate-field changes (`0x008E` <-> `0x003E`) on slot `0x02`.
- `basic-rebind.pcapng` includes a keyboard turbo-form payload (`action=0x0D`, `p0=0x0004`, `p2=0x008E`).
- No button-bind selector for slot `0x06` appears in those captures.
- Direct runtime probes on Basilisk V3 X BT reject slot `0x06` writes on this key family with status `0x03` (error), while slot `0x60` ACKs with `0x02` (success).
- Practical implication: the Hypershift/Boss clutch button is not currently rebindable via vendor key `08 04 01 <slot>` in this implementation path.

## 9.1 OpenSnekMac Runtime Notes (2026-03)

The Swift app (`OpenSnekMac`) applies additional runtime safety around the same vendor protocol:

- one BLE exchange at a time per connection (serialized request pipeline)
- coalesced apply queue (latest local edit wins under rapid slider movement)
- stale-read masking after DPI set is short and bounded (few polls / ~1s) to avoid hiding real hardware stage changes
- BT DPI apply uses a single vendor stage-table write (no active-stage nudge/toggle sequence)
- BT writer preserves stage-id bytes from the current snapshot so hardware stage-button cycling stays in sync with UI selection
- invalid DPI read filtering + immediate retry for transient malformed payloads
- `razer_ble.py` includes HID scroll LED effect families (`0x0F:0x02`), but on current macOS BT stack these HID writes are commonly unsupported (`send result=-1`).
- OpenSnekMac currently treats lighting as static-only in UI (brightness + RGB frame write) until a reliable cross-transport effect path is validated.
- persisted lighting settings are keyed by stable device identity and replayed on reconnect/discovery
- log-backed diagnostics at `~/Library/Logs/OpenSnekMac/open-snek.log`

These are transport-consumer behaviors and do not change the on-wire packet format.

## 10. Status Codes

| Status | Meaning |
|---:|---|
| `0x02` | Success |
| `0x03` | Error |
| `0x05` | Parameter error / unsupported parameter |

## 11. Current Gaps

- Full semantic catalog for all remaining key bytes (`byte4..7`).
- Complete action taxonomy for remaining button payloads (media/macro/system families).
- Hypershift/Boss clutch remap command path (outside currently mapped `08 04 01 <slot>` family).
- Synapse UI-unit mapping for raw scalar fields.
- More cross-device validation beyond PID `0x00BA`.

## 12. USB/BLE Parity Matrix

| Feature (User-Level) | USB Command(s) | BLE Mapping | Script Status (`razer_usb.py` / `razer_ble.py`) | Gap |
|---|---|---|---|---|
| Serial read | `00:82` | `01 83 00 00` | Implemented in both scripts (BT vendor fallback) | Covered |
| Firmware read | `00:81` | Not mapped | Implemented in both scripts via HID path | Need BLE vendor mapping |
| Device mode | `00:84/04` | `01 82 00 00` (read fallback) | Implemented in both scripts | BT write fallback intentionally disabled pending further decoding |
| DPI XY | `04:85/05` | Passive HID read; live apply via vendor stage writes | Implemented in both scripts | No reliable direct BT HID `set_dpi` on validated stack |
| DPI stages | `04:86/06` | `0B84` / `0B04` + `op=0x26` | Implemented in both scripts | Mostly covered |
| Poll rate | `00:85/05` | HID fallback only | Implemented in both scripts | Need vendor mapping for reliability |
| Battery | `07:80` | Battery Service + observed `05 81 00 01` | Implemented in both scripts | Need charging-state mapping on vendor path |
| Idle time | `07:83/03` | `05 84 00 00` / `05 04 00 00` | Implemented in both scripts | Covered via BT vendor fallback |
| Low battery threshold | `07:81/01` | `05 82 00 00` / `05 02 00 00` | Implemented in both scripts | Covered via BT vendor fallback |
| Scroll mode | `02:94/14` | Not mapped | Implemented in both scripts via HID path | Need BLE vendor mapping |
| Scroll acceleration | `02:96/16` | Not mapped | Implemented in both scripts via HID path | Need BLE vendor mapping |
| Scroll smart reel | `02:97/17` | Not mapped | Implemented in both scripts via HID path | Need BLE vendor mapping |
| Scroll LED brightness/effects | `0F:84/04`, `0F:02` | Not mapped | Implemented in both scripts and OpenSnekMac via HID path | Need BLE vendor mapping for non-HID parity |
| Button remap | USB experimental raw writer only | `08 04 01 <slot>` + payload | BLE implemented + USB experimental writer | Mouse + keyboard turbo payloads are mapped on BLE; USB taxonomy still incomplete |
| Lighting / matrix | USB class `0x0F` partly implemented (scroll LED) | Scalar key (`10 85` / `10 05`) + frame stream key (`10 04`) | USB/BLE HID scroll LED profiles + BLE scalar/frame writes | Need vendor-key parity for non-HID BLE effect writes |

## 13. `razer_ble.py` Feature Overlap Checklist

| `razer_ble.py` feature | Protocol section |
|---|---|
| Vendor request header + notify ACK handling | Sections 3-5 |
| Generic scalar get/set helpers (`_bt_get_scalar`, `_bt_set_scalar`) | Sections 5.1, 5.2, 6 |
| DPI stage table get/set (`_bt_get_dpi_stages_blob`, `_bt_set_dpi_stages_blob`) | Sections 5.4, 7.1 |
| Stage payload parse/build (`_parse_bt_stage_table`, `_build_bt_stage_payload`) | Section 7.1 |
| Button bind raw + helpers (`set_button_*`, `set_button_clear_layer`) | Sections 5.3, 7.2 |
| Raw idle/threshold/lighting APIs | Section 6 |
| BLE frame lighting APIs (`set_lighting_frame_raw`, `set_lighting_rgb`, `stream_lighting_spectrum`) | Sections 5.2, 6 |
| BLE lighting mode raw API (`set_lighting_mode_raw`) | Sections 5.2, 6 |
| Vendor battery raw/status APIs + `get_battery()` fallback | Sections 6, 8.3 |
| Generic vendor key reader (`--vendor-key-get`) | Sections 4-6 |
| Scroll LED HID helpers (`get/set_scroll_led_*`) | Sections 8.3, 12 |
| BLE Battery Service fallback (`get_battery_ble`, `get_battery`) | Section 8.1 |
| Passive DPI fallback/sniff (`get_dpi`, `sniff_bt_dpi_values`) | Section 8.2 |
| Poll-rate + direct DPI HID path behavior on BT | Section 8.3 |
