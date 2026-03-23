# Capture Corpus

This directory stores BLE protocol captures used to derive and validate `tools/python/razer_ble.py` behavior.

## Layout

- `ble/filteredcap.pcapng`
  - First broad Synapse BLE capture.
  - Established vendor write/notify framing:
    - write handle `0x003d` (`...1524`)
    - notify handle `0x003f` (`...1525`)
    - request-id echo and status-byte ACK model.
  - Source for generic read/write framing and key-byte model (`byte4..7`).

- `ble/power-lighting.pcapng`
  - Focused capture for scalar settings.
  - Confirms raw power/sleep/lighting key pairs and payload sizes:
    - power timeout: `05 84` / `05 04` (u16)
    - sleep timeout: `05 82` / `05 02` (u8)
    - lighting value: `10 85` / `10 05` (u8)
    - lighting frame stream: `10 04` with 8-byte payload `04 00 00 00 [M][R][G][B]`
  - Confirms two-stage scalar read response pattern:
    - notify header (length/status), then
    - payload notify carrying scalar bytes.

- `ble/all-lighting-modes.pcapng`
  - Full Synapse lighting-mode walkthrough (effects + color changes).
  - Confirms:
    - dominant frame stream key `10 04` with `04 00 00 00 [M][R][G][B]`
    - mode selector write key `10 03` with payload `08 00 00 00`
  - Used to add BT frame-color and mode-raw APIs in `tools/python/razer_ble.py`.

- `ble/all-key-binding-functions.pcapng`
  - Attempted full single-button binding walkthrough in Synapse.
  - Observed repeated writes for slots `0x05` and `0x04` only:
    - header: `08 04 01 <slot>`, len `0x0a`
    - payload: `01 <slot> 01 00 0000 0000 0000`
  - This adds capture-backed evidence for layer-specific clear/default entries (`layer=0x01`, `action=0x00`).
  - No distinct turbo/media/macro payload variants were present in this trace.

- `ble/basic-rebind.pcapng`
  - Button remap workflow across multiple slots.
  - Confirms two-step write flow:
    - header select `op=0x0a`, key `08 04 01 <slot>`
    - 10-byte action payload write.

- `ble/right-click-bind.pcapng`
  - Focused slot `0x02` (right-click) transitions.
  - Confirms payloads for left-click remap, keyboard remap, and explicit right-click restore.

- `ble/right-click-turbo.pcapng`
  - Focused slot `0x02` turbo workflow for right-click.
  - Confirms turbo action payload family on BLE:
    - `01 02 00 0E 0301 8E00 0000`
    - `01 02 00 0E 0301 3E00 0000`
  - Synapse also emits slot `0x05`/`0x04` layer-clear housekeeping writes in the same apply sequence.

- `ble/hyper-shift-left-click-defualt.pcapng`
  - Additional remap workflow capture targeting hypershift-related UI flow.
  - Reconfirms Synapse writes for slots `0x04` and `0x05` using:
    - header: `08 04 01 <slot>`, len `0x0a`
    - payload: `01 <slot> 01 00 0000 0000 0000`

- `ble/hypershift-bind.pcapng`
  - Focused "hypershift bind -> right click -> default" walkthrough.
  - Vendor writes are capture-identical to `hypershift-full-hid.pcapng`:
    - slot `0x05`: `01 05 01 00 0000 0000 0000` (layer-clear)
    - slot `0x04`: `01 04 01 00 0000 0000 0000` (layer-clear)
    - slot `0x02`: `01 02 00 01 0102 0000 0000` (right click / slot-2 default)
  - No selector for slot `0x06` appears.
  - Follow-up runtime probe: direct slot `0x06` writes on `08 04 01` return error status (`0x03`).

- `ble/hypershift-full-hid.pcapng`
  - Same vendor writes as `hypershift-bind.pcapng`, but includes unfiltered HID notifies.
  - Additional HID notify stream observed on handle `0x002b` with constant 8-byte payload:
    - `05 10 00 00 00 00 00 00`
  - No extra vendor config key beyond `08 04 01 <slot>` appears in this trace.
  - No host ATT write for a slot-`0x06` button-bind command is present.

- `ble/hypershift-hold-2026-03-22.pcapng`
  - Focused Windows capture for pressing and holding the Basilisk V3 X HyperSpeed Bluetooth Hypershift/DPI-clutch button three times while Synapse was open.
  - Confirms a separate HID-style notify stream on handle `0x0027`:
    - press: `04 52 00 00 00 00 00 00`
    - release: `04 00 00 00 00 00 00 00`
  - Each press is followed within ~20 to 30 ms by a BLE DPI-stage write/readback sequence:
    - write key `0B 04 01 00`
    - read key `0B 84 01 00`
    - capture-backed write payloads start with active tokens `0x02`, `0x03`, `0x04`
    - capture-backed readback values still decode the same 5-stage table (`400`, `700`, `1600`, `3200`, `5800` DPI)
  - No `08 04 01 06` vendor button-remap write appears in the trace, reinforcing that slot `0x06` is outside the validated BLE button-bind family.
  - Compared with the earlier `full-hid-hypershift-cap.pcapng`, the `0x0027` press byte changed from `0x59` to `0x52`, which suggests the payload is mapping-dependent rather than a fixed physical-button identifier.

- `ble/dpi-cycle-left-click-default.pcapng`
  - Focused capture for DPI-cycle control rebinding.
  - Confirms writable slot `0x60` on the same button-bind key family.
  - Observed transitions:
    - left-click payload: `01 60 00 01 0101 0000 0000`
    - restore/default payload: `01 60 00 06 0106 0000 0000`

- `ble/scroll-up-down-rebind.pcapng`
  - Focused capture for wheel-button binding transitions.
  - Confirms BLE writable slots `0x09` (scroll-up button) and `0x0A` (scroll-down button).
  - Observed transitions:
    - slot `0x09`: `01 09 00 01 0101 0000 0000` (left click) <-> `01 09 00 01 0109 0000 0000` (scroll up)
    - slot `0x0A`: `01 0A 00 01 0101 0000 0000` (left click) <-> `01 0A 00 01 010A 0000 0000` (scroll down)
  - As with other bind captures, Synapse also emits slot `0x05`/`0x04` layer-clear housekeeping writes and slot `0x02` explicit right-click restore.

- `ble/vendor-key-sweeps-2026-03-08.md`
  - In-session automated BLE vendor key sweep report.
  - Documents confirmed mappings, candidate keys, and safety findings from read/writeback probing.

- `ble/hypershift-hold-2026-03-22.md`
  - Packet-by-packet decode notes for the March 22 focused hold capture.
  - Includes the `0x0027` press/release timeline and the correlated `0B 04` / `0B 84` DPI-stage transactions.

- `ble/bt-reconnect-1.pcapng`
  - Full Bluetooth reconnect capture including connection setup, Synapse initialization, and Hypersense button presses with DPI clutch assigned.
  - Key findings:
    - Confirms `0x0027` notify handle delivers Hypersense button as a passive HID stream (HOGP, not vendor GATT).
    - Press payload: `04 59 00 00 00 00 00 00` (action byte `0x59` = DPI clutch binding).
    - Release payload: `04 00 00 00 00 00 00 00`.
    - No explicit CCCD enable for `0x0027` or `0x002b` is visible — Windows subscribes to these HID handles during Bluetooth setup before the capture window starts. Only the vendor CCCD (`0x0040`) is written by Synapse.
    - `0x002f` fires once with all-zeros on connection.
    - Stray release on `0x0027` (`04 00`) may appear before first press after connection.
    - Synapse reacts to each press with immediate vendor DPI-stage writes on the `0B 04 01 00` path.

- `ble/bt-reconnect-2.pcapng`
  - Second reconnect capture with the same DPI clutch binding.
  - Confirms `0x59` as the consistent action byte when DPI clutch is the Synapse-assigned function.
  - Same Synapse DPI-stage write reaction pattern on press.
  - Mouse movement visible on `0x001b` throughout, with `0x002b` heartbeat stream constant at `05 10 00 00 00 00 00 00`.

## Notes

- Captures are intentionally action-scoped for faster diffing.
- Keep new captures in `captures/ble/` and add an entry here with what changed and what was validated.


## Capture guide

To record a new BLE capture:

1. Install BTVS.
2. Launch BTVS. It will open Wireshark.
3. Apply this display filter to hide the noisy HID traffic and keep the ATT exchange visible:

```text
btatt && btatt.handle != 0x002b && btatt.handle != 0x001b
```

4. Open Synapse.
5. Perform the smallest action sequence that reproduces the behavior you want to capture.
6. In Wireshark, export only the relevant packets:
   `File -> Export Specified Packets`
7. Save the capture under `captures/ble/` with a short action-based name, then add a short note to this README describing what the trace validates.
