# Razer BLE Vendor Protocol Specification

## 1. Scope

This document is the reference for the BLE protocol currently implemented by the Swift codebase:

- `OpenSnek/Sources/OpenSnekProtocols/BLEVendorProtocol.swift`
- `OpenSnek/Sources/OpenSnek/Bridge/BTVendorClient.swift`
- `OpenSnek/Sources/OpenSnek/Bridge/BridgeClient.swift`
- `OpenSnek/Sources/OpenSnekProbe/main.swift`
- `OpenSnek/Tests/OpenSnekTests/BLEVendorProtocolTests.swift`

Source-of-truth rule:
- Swift is authoritative.
- Python tooling under `tools/python/` may contain older mappings or compatibility experiments; do not treat it as canonical when this document disagrees.

Supported device baseline:
- Basilisk V3 X HyperSpeed Bluetooth (`VID=0x068E`, `PID=0x00BA`)
- Basilisk V3 Pro Bluetooth (`VID=0x068E`, `PID=0x00AC`)

Document goal:
- A new reader should be able to build a client that implements the current OpenSnek Bluetooth feature set from scratch:
  - DPI stage read/write
  - lighting brightness read/write
  - lighting color read/write
  - limited lighting mode selection (`spectrum` fallback)
  - battery read
  - sleep-timeout read/write
  - button remap write

Out of scope:
- Full catalog of all possible vendor keys on all Razer devices
- Hypershift/Boss-clutch remap path beyond the currently mapped button-bind family
- Media/macro/system button action taxonomy beyond the payloads listed here

## 2. GATT Endpoints

| Item | UUID | Access | Notes |
|---|---|---|---|
| Vendor service | `52401523-F97C-7F90-0E7F-6C6F4E36DB1C` | Service | Required |
| Vendor write characteristic | `52401524-F97C-7F90-0E7F-6C6F4E36DB1C` | Write Request | OpenSnek uses ATT Write Request / `.withResponse` |
| Vendor notify characteristic | `52401525-F97C-7F90-0E7F-6C6F4E36DB1C` | Notify | Responses and payload frames arrive here |
| Notify CCCD | `0x2902` | Write `0x0100` | Enable before any command exchange |

Observed Windows handles in captures:
- service area: `0x003B`
- write characteristic: `0x003D`
- notify characteristic: `0x003F`
- CCCD: `0x0040`

The UUIDs matter; the numeric handles are capture-specific.

## 3. Exchange Model

### 3.1 One Exchange at a Time

The protocol is request/notify based, but OpenSnek treats it as strictly serialized:

- enable notifications first
- send one logical exchange at a time
- wait for its notify header and any payload frames
- only then start the next exchange

Do not pipeline requests on a single connection. The only correlation token is the one-byte request ID, and out-of-order notify interleaving is easy to create if you overlap commands.

### 3.2 Request ID

- Byte 0 of every request is a caller-chosen request ID (`req`).
- The response notify header echoes that same ID.
- OpenSnek and OpenSnekProbe start at `0x30` and increment modulo `0x100`.
- The exact starting value is not important; uniqueness across in-flight requests is.

### 3.3 Write Type

Current Swift behavior:
- all vendor writes use ATT Write Request (`withResponse`)

Capture-backed behavior:
- the implemented write flows in this repo also succeed as Write Request

If you are implementing a compatible client, use write-with-response unless you have a reason not to.

### 3.4 End of Exchange

OpenSnek considers an exchange complete after:
- all queued writes have been acknowledged at the ATT layer, and
- no more notify frames arrive for a short idle window

That idle window is a client policy, not an on-wire field. Your client can instead finish as soon as it has:
- the first matching notify header with `req`, and
- enough payload bytes to satisfy `payload_length`

## 4. Frame Formats

### 4.1 Request Header

All commands start with an 8-byte header:

```text
byte 0  req_id
byte 1  payload_length (0x00 for reads)
byte 2  reserved (0x00)
byte 3  reserved (0x00)
byte 4  key byte 0
byte 5  key byte 1
byte 6  key byte 2
byte 7  key byte 3
```

Read header:

```text
[req, 00, 00, 00, key0, key1, key2, key3]
```

Write header:

```text
[req, payload_len, 00, 00, key0, key1, key2, key3]
```

### 4.2 Notify Header

Observed notify-header variants:

- 20-byte header on the Basilisk V3 X HyperSpeed Bluetooth path
- 8-byte header on the Basilisk V3 Pro Bluetooth path

Shared parsed fields:

```text
byte 0   req_id echo
byte 1   payload_length
byte 2   reserved
byte 3   reserved
byte 4   reserved
byte 5   reserved
byte 6   reserved
byte 7   status
byte 8   reserved/session (20-byte variant only)
...
byte 19  reserved/session (20-byte variant only)
```

Current status values:

| Status | Meaning |
|---:|---|
| `0x02` | success |
| `0x03` | error |
| `0x05` | parameter error / unsupported parameter |

### 4.3 Payload Frames

After a successful notify header:

- payload bytes usually arrive in one or more additional notify frames
- concatenate those continuation frames in arrival order
- truncate the concatenated stream to `payload_length`

OpenSnek parser details:
- it searches for the first notify header (currently `>= 8` bytes) whose `req` matches and whose status is in `{0x02, 0x03, 0x05}`
- if status is not `0x02`, the operation is treated as failed
- if there are continuation frames, payload comes from those frames
- if there are no continuation frames but `payload_length > 0`, the parser falls back to bytes `8...` of the notify header itself

That last fallback exists in Swift for robustness. The implemented keys in this repo are still capture-backed as header-plus-continuation transactions.

V3 Pro Bluetooth framing note:
- observed read responses use the same request header and key catalog as the V3 X Bluetooth path
- notify headers shrink to 8 bytes (`req len 00 00 00 00 00 status`)
- continuation frames may end with a short final fragment instead of always being 20 bytes

## 5. Key Catalog

These are the keys currently used by the Swift app/probe and therefore covered by this spec.

| Feature | Read key | Write key | Write payload length | Payload type |
|---|---|---|---:|---|
| DPI stage table | `0B 84 01 00` | `0B 04 01 00` | `0x26` | 38-byte table |
| Lighting zone catalog | `10 80 00 01` | none | none | LED ID list |
| Lighting brightness (legacy/global) | `10 85 01 01` | `10 05 01 00` | `0x01` | `u8` |
| Lighting brightness (V3 Pro zone) | `10 85 01 <led>` | `10 05 01 <led>` | `0x01` | `u8` |
| Lighting frame color (legacy) | `10 84 00 00` | `10 04 00 00` | `0x08` | 8-byte frame |
| Lighting zone static state (V3 Pro) | `10 83 00 <led>` | `10 03 00 <led>` | `0x0A` | 10-byte zone state |
| Lighting mode selector (legacy) | none | `10 03 00 00` | `0x04` | `u32 LE` |
| Sleep timeout | `05 84 00 00` | `05 04 00 00` | `0x02` | `u16 LE` |
| Battery raw | `05 81 00 01` | none | none | `u8` |
| Battery status | `05 80 00 01` | none | none | `u8` |
| Button bind | none | `08 04 01 <slot>` | `0x0A` | 10-byte action |

Not source-of-truth in Swift:
- older Python tooling also contains additional candidate keys such as `05 82 00 00`, `05 02 00 00`, `01 82 00 00`, and `01 83 00 00`
- those keys are intentionally omitted from the main spec because current Swift OpenSnek does not rely on them

## 6. Payload Layouts

### 6.1 Scalar Payloads

Scalar writes are little-endian:

- `u8`: one byte
- `u16 LE`: low byte first
- `u32 LE`: four bytes, low byte first

Examples:

- lighting brightness `128` -> payload `80`
- sleep timeout `300` seconds -> payload `2C 01`
- lighting mode `8` -> payload `08 00 00 00`

### 6.2 DPI Stage Table

#### 6.2.1 Write Payload Layout

DPI stage writes always send a fixed 38-byte payload:

```text
byte 0   active stage token
byte 1   declared stage count (1..5)

then 5 entries of 7 bytes each:
  byte 0   stage_id
  byte 1   dpi_x low
  byte 2   dpi_x high
  byte 3   dpi_y low
  byte 4   dpi_y high
  byte 5   reserved (0x00)
  byte 6   reserved/marker (only entry 5 uses the preserved marker value)

final trailing byte:
  0x00
```

Equivalent shape:

```text
[active][count]
  [sid0][x0_lo][x0_hi][y0_lo][y0_hi][00][00]
  [sid1][x1_lo][x1_hi][y1_lo][y1_hi][00][00]
  [sid2][x2_lo][x2_hi][y2_lo][y2_hi][00][00]
  [sid3][x3_lo][x3_hi][y3_lo][y3_hi][00][00]
  [sid4][x4_lo][x4_hi][y4_lo][y4_hi][00][marker]
[00]
```

Important:
- the active byte is not a UI index in the Swift client; it is written as the selected entry's `stage_id`
- stage IDs should be preserved from the most recent read snapshot when possible
- OpenSnek reads current stage IDs first, then reuses them on write

#### 6.2.2 Read Payload Layout

Read payloads are variable-length:

```text
[active][count][entry0][entry1]...[entryN]
```

Each entry is the same 7-byte structure used above:

```text
[stage_id][dpi_x_le16][dpi_y_le16][reserved][marker_or_reserved]
```

Observed lengths:
- 2 stages: 16 bytes
- 3 stages: 23 bytes
- 5 stages: 37 bytes

Observed truncation:
- some payloads are short by one byte and omit the final entry marker
- OpenSnek still parses them as long as the declared `count` entries have stage ID plus DPI X/Y bytes

#### 6.2.3 Stage Order and Active Resolution

Swift source-of-truth behavior:

- preserve wire entry order exactly; do not sort by `stage_id`
- resolve `active` this way:
  1. if `active_raw` matches one of the visible `stage_id` bytes, use that entry index
  2. else if `active_raw` is in `1...count`, treat it as 1-based
  3. else clamp `active_raw` into `0...(count-1)`

This is required for correct behavior on the validated device family because the active byte behaves like a stage-ID token in normal traffic.

#### 6.2.4 OpenSnek-Compatible Write Policy

If you want write behavior that matches the app/probe:

- always write 5 stage entries even when `count < 5`
- preserve existing stage IDs from the last read
- preserve the final entry marker from the last read
- for multi-stage writes, replace only the first `count` stage values and keep the tail slots unchanged

#### 6.2.5 Passive HID DPI Input Report

The Bluetooth DPI-stage vendor exchange is still request/notify over GATT, but validated devices can also emit a passive HID input report when the on-device DPI cycle control changes the live DPI.

Validated macOS HID topology for Basilisk V3 X HyperSpeed Bluetooth (`VID=0x068E`, `PID=0x00BA`) and Basilisk V3 Pro Bluetooth (`VID=0x068E`, `PID=0x00AC`):
- transport: `Bluetooth Low Energy`
- primary usage: `0x01:0x02`
- max input report size: `9`
- max feature report size: `1`

Observed passive frame shape in the existing Python HID sniff path and a live macOS `IOHIDDeviceRegisterInputReportCallback` capture on the Basilisk V3 Pro Bluetooth path:

```text
05 05 02 <x_hi> <x_lo> <y_hi> <y_lo> ...
```

Where:
- first `0x05`: report ID
- second `0x05`: duplicated report ID on the current hidapi path
- `0x02`: DPI subtype
- X/Y DPI are big-endian 16-bit values

Observed V3 Pro Bluetooth examples:
- `05 05 02 03 84 03 84 00 00` -> `900 / 900 DPI`
- `05 05 02 07 D0 07 D0 00 00` -> `2000 / 2000 DPI`
- `05 05 02 04 4C 04 4C 00 00` -> `1100 / 1100 DPI`

OpenSnek's parser also accepts `05 02 ...` and `02 ...` report prefixes because macOS `IOHIDDeviceRegisterInputReportCallback` can normalize away one or both leading report-ID bytes. That normalization detail is an inference from current host behavior, not a separate wire-format claim.

Current app policy:
- subscribe to passive HID DPI reports only on capture-validated Bluetooth profiles
- update cached `dpi.x/y` immediately from the HID report
- recompute `active_stage` only when the reported DPI uniquely matches one cached stage value
- keep Bluetooth fast DPI polling enabled until the first passive HID event is actually observed at runtime, then disable the fast-poll fallback for that device
- for single-stage writes, mirror the single value across all 5 slots

Those are client rules, not independent protocol guarantees, but they are what current Swift uses.

### 6.3 Lighting Payloads

#### 6.3.1 Legacy Frame Payload (`10 84` / `10 04`)

The legacy static-color payload used by the Basilisk V3 X HyperSpeed Bluetooth path is 8 bytes:

```text
04 00 00 00 [marker] [R] [G] [B]
```

OpenSnek writes:
- prefix `04 00 00 00`
- marker `00`
- RGB bytes

Read payloads accepted by Swift:

1. 8-byte form

```text
04 00 00 00 [marker] [R] [G] [B]
```

2. compact 4-byte form

```text
[marker] [R] [G] [B]
```

#### 6.3.2 V3 Pro Zone-State Payload (`10 83` / `10 03`)

The Basilisk V3 Pro Bluetooth path uses per-zone static state instead of the legacy frame stream.

Validated LED IDs:
- `0x01` scroll wheel
- `0x04` logo
- `0x0A` underglow

Read key:
- `10 83 00 <led>`

Write key:
- `10 03 00 <led>`

Payload layout:

```text
01 00 00 01 [R] [G] [B] 00 00 00
```

Observed examples:
- `01 00 00 01 bf 00 f2 00 00 00`
- `01 00 00 01 00 00 ff 00 00 00`
- `01 00 00 01 00 ff 00 00 00 00`

OpenSnek now treats bytes `4...6` as `R/G/B` and fans out one `10 03 00 <led>` write per targeted zone.

#### 6.3.3 V3 Pro Zone Brightness (`10 85` / `10 05`)

The Basilisk V3 Pro Bluetooth path also exposes per-zone brightness:

- read: `10 85 01 <led>`
- write: `10 05 01 <led>`
- payload: one brightness byte

Observed reads on the validated device returned `ff` for `0x01`, `0x04`, and `0x0A`.

### 6.4 Lighting Mode Selector Payload

The write payload for key `10 03 00 00` is a `u32 LE`.

Currently validated value:
- `08 00 00 00` -> spectrum fallback mode

No other BLE vendor selector values are source-of-truth in Swift today.

### 6.5 Button-Bind Payload

Button-binding writes use key `08 04 01 <slot>` and a 10-byte payload:

```text
[profile][slot][layer][action][p0_le16][p1_le16][p2_le16]
```

Field meanings:
- `profile`: always `0x01` in current Swift implementation
- `slot`: physical/logical slot selector
- `layer`: `0x00` normal, `0x01` clear-layer payloads
- `action`: action family
- `p0`, `p1`, `p2`: action-specific little-endian `u16` values

#### 6.5.1 Validated Action Families

| Action | Meaning | Payload notes |
|---:|---|---|
| `0x00` | clear layer override | uses `layer=0x01`, params all zero |
| `0x01` | mouse button action | `p0 = (button_id << 8) | 0x01` |
| `0x02` | simple keyboard action | `p0 = 0x0002`, `p1 = HID key` |
| `0x06` | DPI-cycle default restore | used only for slot `0x60` default |
| `0x0D` | keyboard turbo action | `p0 = 0x0004`, `p1 = HID key`, `p2 = turbo rate` |
| `0x0E` | mouse turbo action | `p0 = ((button_id - 1) << 8) | 0x0003`, `p1 = turbo rate` |

#### 6.5.2 Mouse Button IDs Used by Swift

| Meaning | Button ID |
|---|---:|
| left click | `0x01` |
| right click | `0x02` |
| middle click | `0x03` |
| back | `0x04` |
| forward | `0x05` |
| scroll up | `0x09` |
| scroll down | `0x0A` |

#### 6.5.3 Default-Restore Payloads

OpenSnek does not write a generic "restore default" opcode for normal mouse slots. It writes the slot-native payload explicitly.

Examples:

- slot `0x01` default:
  - `01 01 00 01 01 01 00 00 00 00`
- slot `0x02` default:
  - `01 02 00 01 01 02 00 00 00 00`
- slot `0x04` default:
  - `01 04 00 01 01 04 00 00 00 00`
- slot `0x05` default:
  - `01 05 00 01 01 05 00 00 00 00`
- slot `0x09` default:
  - `01 09 00 01 01 09 00 00 00 00`
- slot `0x0A` default:
  - `01 0A 00 01 01 0A 00 00 00 00`

Special case:

- slot `0x60` default (DPI cycle):
  - `01 60 00 06 01 06 00 00 00 00`

#### 6.5.4 Slot Coverage

Validated writable slots in current project:
- `0x01`
- `0x02`
- `0x03`
- `0x04`
- `0x05`
- `0x09`
- `0x0A`
- `0x60`

Known rejection:
- slot `0x06` returns error status `0x03` on the validated BLE key family and is treated as software-read-only / unsupported for remapping on the current BLE vendor path

## 7. Complete Transaction Examples

All examples below use zero-filled reserved bytes in notify headers because only `req`, `payload_length`, and `status` are semantically consumed by current Swift code.

### 7.1 Read DPI Stages

Request header:

```text
34 00 00 00 0B 84 01 00
```

Success notify header (`payload_length = 0x17 = 23`):

```text
34 17 00 00 00 00 00 02 00 00 00 00 00 00 00 00 00 00 00 00
```

Payload continuation #1:

```text
01 03 02 80 0C 80 0C 00 00 00 20 03 20 03 00 00 01 40 06 40
```

Payload continuation #2:

```text
06 00 03 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

Decoded 23-byte payload:

```text
01 03
02 80 0C 80 0C 00 00
00 20 03 20 03 00 00
01 40 06 40 06 00 03
```

Interpretation:
- `active_raw = 0x01`
- `count = 3`
- wire entries:
  - stage ID `0x02` -> `3200`
  - stage ID `0x00` -> `800`
  - stage ID `0x01` -> `1600`
- active resolves to index `2` because `active_raw` matches the third entry's `stage_id`

### 7.2 Write DPI Stages

Target state:
- visible stages = `[800, 1600, 3200]`
- active index = `2`
- preserved stage IDs = `[1, 2, 3, 4, 5]`
- preserved tail slots = `[6400, 12000]`
- preserved marker = `0x03`

Write header:

```text
35 26 00 00 0B 04 01 00
```

38-byte payload:

```text
03 03
01 20 03 20 03 00 00
02 40 06 40 06 00 00
03 80 0C 80 0C 00 00
04 00 19 00 19 00 00
05 E0 2E E0 2E 00 03
00
```

Sent as two characteristic writes after the header:

Payload chunk #1 (20 bytes):

```text
03 03 01 20 03 20 03 00 00 02 40 06 40 06 00 00 03 80 0C 80
```

Payload chunk #2 (18 bytes):

```text
0C 00 00 04 00 19 00 19 00 00 05 E0 2E E0 2E 00 03 00
```

ACK header:

```text
35 00 00 00 00 00 00 02 00 00 00 00 00 00 00 00 00 00 00 00
```

### 7.3 Read Lighting Brightness

Request header:

```text
40 00 00 00 10 85 01 01
```

Success notify header:

```text
40 01 00 00 00 00 00 02 00 00 00 00 00 00 00 00 00 00 00 00
```

Payload frame:

```text
80 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

Decoded value:
- brightness raw = `0x80` (`128`)

### 7.4 Write Lighting Brightness

Write header:

```text
41 01 00 00 10 05 01 00
```

Payload:

```text
80
```

ACK header:

```text
41 00 00 00 00 00 00 02 00 00 00 00 00 00 00 00 00 00 00 00
```

### 7.5 Read Lighting Color

Request header:

```text
42 00 00 00 10 84 00 00
```

Success notify header:

```text
42 08 00 00 00 00 00 02 00 00 00 00 00 00 00 00 00 00 00 00
```

Payload frame:

```text
04 00 00 00 00 FF 40 10 00 00 00 00 00 00 00 00 00 00 00 00
```

Decoded value:
- marker `00`
- RGB = `FF 40 10`

### 7.6 Write Lighting Color

Write header:

```text
43 08 00 00 10 04 00 00
```

Payload:

```text
04 00 00 00 00 FF 40 10
```

ACK header:

```text
43 00 00 00 00 00 00 02 00 00 00 00 00 00 00 00 00 00 00 00
```

### 7.7 Select Spectrum Lighting Mode

Write header:

```text
44 04 00 00 10 03 00 00
```

Payload:

```text
08 00 00 00
```

ACK header:

```text
44 00 00 00 00 00 00 02 00 00 00 00 00 00 00 00 00 00 00 00
```

### 7.8 Read Sleep Timeout

Request header:

```text
45 00 00 00 05 84 00 00
```

Success notify header:

```text
45 02 00 00 00 00 00 02 00 00 00 00 00 00 00 00 00 00 00 00
```

Payload frame for `300` seconds:

```text
2C 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

### 7.9 Write Button Binding

Example: slot `0x02` -> right click

Write header:

```text
46 0A 00 00 08 04 01 02
```

Payload:

```text
01 02 00 01 01 02 00 00 00 00
```

ACK header:

```text
46 00 00 00 00 00 00 02 00 00 00 00 00 00 00 00 00 00 00 00
```

Example: slot `0x02` -> right-click turbo with rate `0x003E`

```text
01 02 00 0E 03 01 3E 00 00 00
```

Example: slot `0x03` -> keyboard key `0x08` with turbo rate `0x008E`

```text
01 03 00 0D 04 00 08 00 8E 00
```

## 8. Feature Semantics Used by OpenSnek

These behaviors are not pure wire-format rules, but they are part of what you need if you want a client that behaves like the current app.

### 8.1 DPI Reliability Rules

OpenSnek:
- retries malformed DPI-stage reads once immediately
- rejects parsed DPI results if:
  - the value list is empty
  - active index is out of range
  - any visible value is outside `100...30000`
- after a successful DPI write, temporarily masks a small number of stale readbacks if they do not match the just-written state

Those stale-read masks are bounded and expire quickly; they are meant to hide transient firmware lag, not permanent mismatches.

### 8.2 Battery Interpretation

Current Swift interpretation:
- `batteryRaw`:
  - if `<= 100`, treat as direct percentage
  - else scale `0...255` to `0...100`
- `batteryStatus == 1` means charging

Those semantics are client policy inferred from observed behavior, not a fully decoded vendor spec.

### 8.3 Lighting Feature Surface

Current Swift BLE feature surface:
- brightness scalar read/write
- color frame read/write
- spectrum fallback via mode selector value `8`

Not currently source-of-truth on BLE vendor path:
- wave
- reactive
- pulse random
- pulse single
- pulse dual

The app may still expose richer lighting on USB HID, but this BLE document only guarantees the vendor path above.

## 9. Reference Swift API Map

| Swift API | Protocol operation |
|---|---|
| `BLEVendorProtocol.buildReadHeader` | request header encoder |
| `BLEVendorProtocol.buildWriteHeader` | request header encoder |
| `BLEVendorProtocol.parsePayloadFrames` | notify/payload decoder |
| `BLEVendorProtocol.parseDpiStageSnapshot` | DPI read payload parser with stage IDs |
| `BLEVendorProtocol.parseDpiStages` | DPI read payload parser for visible values |
| `BLEVendorProtocol.buildDpiStagePayload` | 38-byte DPI write payload builder |
| `BLEVendorProtocol.buildButtonPayload` | 10-byte button action builder |
| `BTVendorClient.run` | one serialized exchange over CoreBluetooth |
| `BridgeClient.btGetDpiStages` | DPI read + validation + stale-read handling |
| `BridgeClient.btSetDpiStages` | DPI write with ID/marker preservation |
| `PassiveDPIParser.parse` | passive HID DPI input parser used for Bluetooth live updates |
| `PassiveDPIEventMonitor.replaceTargets` | passive HID input-report subscription manager |
| `BridgeClient.readLightingColor` | lighting-frame read |
| `BridgeClient.btSetLightingRGB` | lighting-frame write |
| `BridgeClient.btSetLightingModeRaw` | mode-selector write |
| `BridgeClient.btSetButtonBinding` | button-bind write |

## 10. Current Gaps

- No source-of-truth BLE vendor key for serial read in Swift
- No source-of-truth BLE vendor key for device mode in Swift
- No source-of-truth BLE vendor key for low-battery-threshold control in Swift
- No source-of-truth BLE vendor key for poll-rate control in Swift
- No decoded BLE vendor path for slot `0x06` / Hypershift-Boss-sniper control remap; treat it as software-read-only on the current BLE path until a separate HID/report command family is validated
- No complete button action taxonomy for media/macro/system families
- No multi-device validation beyond the Basilisk V3 X Bluetooth family

## 11. Cross-References

- [Protocol Index](./PROTOCOL.md)
- [USB Protocol](./USB_PROTOCOL.md)
- [USB/BLE Parity](./PARITY.md)
- [BLE Reverse Engineering Notes](../research/BLE_REVERSE_ENGINEERING.md)
