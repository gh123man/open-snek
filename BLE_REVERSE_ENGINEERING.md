# BLE Reverse Engineering Notes

## Objective

Reverse engineer the Razer BLE configuration path used by Synapse and implement stable features in `razer_ble.py`.

## Device Context

- Primary target: Basilisk V3 X HyperSpeed
- BLE IDs: `VID 0x068E`, `PID 0x00BA`
- OS used during work: macOS (live validation), Windows captures for protocol discovery

## Capture Timeline

- `captures/ble/filteredcap.pcapng`
  - First full Synapse BLE config capture
  - Established vendor write/notify path and request/response framing
  - Identified command-key model in bytes `4..7`
- `captures/ble/power-lighting.pcapng`
  - Isolated power timeout, sleep timeout, lighting changes
  - Confirmed raw get/set scalar key pairs
- `captures/ble/basic-rebind.pcapng`
  - Isolated button rebind operations for multiple slots
  - Confirmed two-step slot-select + payload write for button bindings
- `captures/ble/right-click-bind.pcapng`
  - Focused right-click slot transitions
  - Confirmed slot `0x02` payloads for default, left-click remap, keyboard `F`, and restore

## Reverse Engineering Strategy

1. Capture one UI action class at a time.
2. Diff write sequences and cluster by `(op, key bytes 4..7, payload length)`.
3. Correlate request id in writes with response notify headers.
4. Validate each inferred key with live write + readback.
5. Add narrow API methods only after live confirmation.
6. Keep raw fallback APIs for untyped keys.

## Core Findings

- Synapse BLE config uses vendor GATT (`...1524` write, `...1525` notify).
- Requests use an 8-byte header with request id + op + 4-byte key.
- Notify header status codes: `0x02` success, `0x03` error, `0x05` parameter error.
- Many reads/writes are scalar values via a common framing pattern.
- DPI stage table uses a dedicated multi-chunk write/read path.
- Button rebinding uses:
  - header select: `op=0x0a`, key `08 04 01 <slot>`
  - then 10-byte action payload

## Implemented from Captures

- DPI stages read/write (all 5 slots)
- Single-DPI mode helper (derived from stage table behavior)
- Power timeout raw read/write (`05 84` / `05 04`)
- Sleep timeout raw read/write (`05 82` / `05 02`)
- Lighting value raw read/write (`10 85` / `10 05`)
- Button rebinding:
  - raw payload writer
  - default helper
  - keyboard helpers
  - generic action helper
  - mouse-button helpers (left/right click)

## Validation Method

- For each setter:
  1. Send set command.
  2. Require ACK with matching request id and status `0x02`.
  3. Read back value (or repeat getter) to confirm state.
- For button actions:
  - Validate command ACK and verify physical behavior on mouse buttons.

## Operational Constraints

- BLE session can enter a bad state after aggressive probing.
- Reliable recovery: physical Bluetooth toggle on mouse (off/on), then reconnect.
- Parallel command runs can conflict on BLE access; run writes sequentially.

## Open Work

- Expand full command-key catalog for remaining Synapse settings.
- Decode remaining button action types and all slot semantics.
- Map raw scalar values to exact Synapse UI units/options.
- Capture and decode macro/media/system rebind payloads.
- Add automated capture parser tooling for key/payload diffing.

## Practical Capture Guidance

- Record one setting family per capture.
- Change one control at a time with clear before/after states.
- Include explicit restore-to-default actions in the same capture.
- For rebind captures, include: default -> target mapping -> alternate mapping -> default.
- Keep timestamps/action logs while capturing to improve correlation speed.

## Historical Timeline and Changelog

### Timeline

- 2024-03-05: Initial BLE notes and OpenRazer-based assumptions recorded.
- 2026-03-06: Broad BLE transport exploration on macOS + Windows driver stack analysis.
- 2026-03-07: `captures/ble/filteredcap.pcapng` decoded enough to establish Synapse vendor-GATT frame model.
- 2026-03-08: Live write/readback validation for scalar keys and DPI stages.
- 2026-03-08: Added focused captures for power/lighting and button rebinding (`captures/ble/power-lighting.pcapng`, `captures/ble/basic-rebind.pcapng`, `captures/ble/right-click-bind.pcapng`).

### Changelog

- **2026-03-08**: Added automated vendor-key discovery (`discover_bt_vendor_keys.py`) and live validation:
  - Validated key-space scanner with read-only and same-value writeback modes
  - Added captured sweep report: `captures/ble/vendor-key-sweeps-2026-03-08.md`
  - Confirmed scalar mappings:
    - `05 84`/`05 04` (`u16`) aligned with idle-time value
    - `05 82`/`05 02` (`u8`) aligned with low-battery-threshold value
  - Confirmed read fallbacks:
    - `01 83 00 00` serial payload
    - `01 82 00 00` mode tuple read
  - Safety note:
    - Candidate mode write key `01 02 00 00` can trigger unstable/blinking radio state on current firmware.
    - BT device-mode write fallback is intentionally disabled in `razer_ble.py`.

- **2026-03-08**: Added right-click remap mapping from `captures/ble/right-click-bind.pcapng`:
  - Confirmed slot `0x02` payloads for left-click, keyboard `F`, and right-click restore
  - Refined action `0x01` semantics to mouse-button action with observed `p0` values:
    `0x0101` (left click), `0x0201` (right click)
  - Implemented convenience helpers:
    `set_button_mouse_button`, `set_button_left_click`, `set_button_right_click`
  - Updated `set_button_default(2)` to restore right-click explicitly
- **2026-03-08**: Added power/lighting mapping from `captures/ble/power-lighting.pcapng`:
  - `05 84`/`05 04` raw u16 power-timeout path (2-byte LE payload writes)
  - `05 82`/`05 02` raw u8 sleep-timeout path
  - `10 85`/`10 05` raw u8 lighting-value path
  - `10 04` 8-byte lighting frame stream path (`04 00 00 00 [M][R][G][B]`) used by Synapse during color/effect updates
  - Clarified read response structure: header notify (length/status) followed by payload notify for scalar values
  - Added capture-backed examples and `razer_ble.py` implementations
- **2026-03-08**: Added all-lighting-modes mapping from `captures/ble/all-lighting-modes.pcapng`:
  - Confirmed mode selector key `10 03` (`u32`, observed value `0x00000008`)
  - Confirmed heavy frame stream key `10 04` for effect/color playback (`04 00 00 00 [M][R][G][B]`)
  - Added `razer_ble.py` APIs/CLI:
    - `set_lighting_mode_raw` / `--lighting-mode-raw`
    - `set_lighting_frame_raw`, `set_lighting_rgb`, `stream_lighting_spectrum`
- **2026-03-08**: Parsed `captures/ble/all-key-binding-functions.pcapng`:
  - Observed repeated button writes only for slots `0x04`/`0x05`:
    - header `08 04 01 <slot>` with len `0x0a`
    - payload `01 <slot> 01 00 0000 0000 0000`
  - Added mapping for layer-clear/default entry (`layer=0x01`, `action=0x00`)
    and implemented helper/CLI in `razer_ble.py`:
    - `set_button_clear_layer`
    - `--button-clear-layer SLOT:LAYER`
  - No unique turbo/media/macro payloads were present in this capture.
- **2026-03-08**: BT poll-rate feasibility probe:
  - Live BT HID command path `--poll-rate 1000` still fails.
  - Focused vendor-key probes for `00:84..87` and wide `00:80..97` families found no `00 85`/`00 05` equivalent key.
  - Cross-capture key scan (`captures/ble/*.pcapng`) shows no `0085xxxx`/`0005xxxx` headers.
  - Current conclusion: on this BT firmware, poll-rate is likely not exposed over vendor GATT (not merely hidden by Synapse UI).
- **2026-03-08**: Added button-rebind mapping from `captures/ble/basic-rebind.pcapng`:
  - Header key `08 04 01 <slot>` with op `0x0a` and 10-byte payload writes
  - Documented observed payload families for default mouse, keyboard, and extended remap
  - Added raw and convenience rebind helpers to `razer_ble.py`
- **2026-03-08**: Decoded Synapse vendor GATT frame structure from `captures/ble/filteredcap.pcapng`:
  - Identified dominant 8-byte request frame format (203/217 writes) with echoed request ID
  - Documented 20-byte response header format on notify handle 0x3F:
    request echo, data length, status (`0x02`/`0x03`/`0x05`), payload bytes
  - Confirmed long responses use additional notifications when `length > 12`
  - Live CoreBluetooth validation on connected BSK V3 X HS:
    confirmed writable `05 82` path and writable `10 85/10 05` 1-byte setting path
  - Additional live mapping: `05 81` raw battery (`0xF2` ~= 94.9%) matches Battery Service 94%
  - `05 80` identified as a companion 1-byte status flag (observed `0x01`)
  - `05 84` stable 16-bit scalar (`0x012C`) confirmed readable
  - Confirmed DPI stage write path:
    `0B 04 01 00` + 38-byte payload (20+18) successfully updates slot DPI
- **2026-03-07**: Analysis of Windows BLE GATT capture (`captures/ble/filteredcap.pcapng`):
  - Confirmed handle mapping: `0x3D` write, `0x3F` notify, `0x40` CCCD
  - Revised earlier conclusion: vendor GATT is used for BLE config traffic (not lighting-only)
  - Confirmed ATT Write Requests (0x12) and request/notify correlation model
  - Serial and DPI-related response patterns identified from capture
- **2026-03-06**: Added Windows BLE driver architecture findings:
  - Documented `RzDev_00ba.sys`, `RZCONTROL`, and `HidOverGatt` stack relationships
  - Mapped services/handles from Windows enumeration and descriptor artifacts
- **2026-03-06**: Early comprehensive BLE vendor-GATT experiments:
  - Documented working/non-working command families and recovery behavior
  - Recorded HID report limitations over BLE for direct feature/output paths
- **2026-03-06**: Added initial BLE protocol section (Battery Service, vendor GATT service, passive HID reports).
- **2024-03-05**: Initial documentation based on OpenRazer and Basilisk V3 X HyperSpeed testing.
