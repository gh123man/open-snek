# Capture Corpus

This directory stores BLE protocol captures used to derive and validate `razer_ble.py` behavior.

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

- `ble/basic-rebind.pcapng`
  - Button remap workflow across multiple slots.
  - Confirms two-step write flow:
    - header select `op=0x0a`, key `08 04 01 <slot>`
    - 10-byte action payload write.

- `ble/right-click-bind.pcapng`
  - Focused slot `0x02` (right-click) transitions.
  - Confirms payloads for left-click remap, keyboard remap, and explicit right-click restore.

- `ble/vendor-key-sweeps-2026-03-08.md`
  - In-session automated BLE vendor key sweep report.
  - Documents confirmed mappings, candidate keys, and safety findings from read/writeback probing.

## Notes

- Captures are intentionally action-scoped for faster diffing.
- Keep new captures in `captures/ble/` and add an entry here with what changed and what was validated.
