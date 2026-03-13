# USB/BLE Feature Parity

This document is the single source of truth for feature parity between the USB HID protocol and BLE protocol paths in `open-snek`.

## Scope

Target device baseline:
- Basilisk V3 X HyperSpeed (`USB PID 0x00B9`, `BT PID 0x00BA`)
- Basilisk V3 Pro (`USB PID 0x00AB`)
- Basilisk V3 Pro Bluetooth (`BT PID 0x00AC`)
- Basilisk V3 35K (`USB PID 0x00CB`)

Transport paths:
- USB/2.4GHz: 90-byte HID report protocol
- BLE: vendor GATT (`...1524`/`...1525`) + selective HID fallback

## Parity Matrix

Legend:
- `DONE`: implemented and documented on both paths
- `PARTIAL`: implemented but transport-dependent or not fully mapped
- `USB_ONLY`: available only on USB path
- `BLE_ONLY`: available only on BLE path
- `UNKNOWN`: protocol not fully decoded

| Feature | USB Protocol | BLE Protocol | Script Support | Status | Notes |
|---|---|---|---|---|---|
| Serial read | `00:82` | key `01 83 00 00` | `razer_usb.py` + `razer_ble.py` (USB HID + BT vendor fallback) | DONE | BT vendor fallback implemented |
| Firmware read | `00:81` | unknown vendor key | `razer_usb.py` + `razer_ble.py` (HID path) | PARTIAL | HID over BT may fail on some stacks |
| Device mode | `00:84/04` | `01 82 00 00` (read), `01 02 00 00` (write candidate) | `razer_usb.py` + `razer_ble.py` | PARTIAL | BT read fallback enabled; BT write path disabled for safety. OpenSnek writes/reads mode on USB and shows the card only when readback is available. |
| DPI XY | `04:85/05` | passive HID read/listen; live apply via vendor stage writes | both scripts | PARTIAL | direct BT HID `set_dpi` is not reliable on validated stack, but OpenSnek now uses validated passive BT HID reports for immediate on-device DPI-change updates |
| DPI stages + active stage | `04:86/06` | `0B84`/`0B04`, `op=0x26` | both scripts | DONE | OpenSnek normalizes active-stage via stage IDs and preserves USB stage IDs on writes to avoid off-by-one stage mapping. |
| Poll rate | `00:85/05` | HID fallback only | both scripts | PARTIAL | Need BLE vendor equivalent |
| Battery level | `07:80` | Battery Service + observed vendor read | both scripts | PARTIAL | Charging-state parity still incomplete on BLE |
| Idle time | `07:83/03` | `05 84 00 00` / `05 04 00 00` | both scripts | DONE | BT vendor fallback implemented |
| Low battery threshold | `07:81/01` | `05 82 00 00` / `05 02 00 00` | both scripts | DONE | BT vendor fallback implemented. OpenSnek supports read/write on USB + BT, and hides USB control when unsupported. |
| Scroll mode | `02:94/14` | unknown vendor key | both scripts (HID path) | PARTIAL | USB semantics validated via OpenRazer. OpenSnek reads/writes on USB and hides the control when unsupported. |
| Scroll acceleration | `02:96/16` | unknown vendor key | both scripts (HID path) | PARTIAL | BLE vendor mapping missing. OpenSnek reads/writes on USB and hides the control when unsupported. |
| Scroll smart reel | `02:97/17` | unknown vendor key | both scripts (HID path) | PARTIAL | BLE vendor mapping missing. OpenSnek reads/writes on USB and hides the control when unsupported. |
| Scroll LED brightness | `0F:84/04` (`VARSTORE`, `LED=0x01`) | unknown vendor key | both scripts (HID path) | PARTIAL | USB validated; BLE vendor key not mapped |
| Scroll LED effects | `0F:02` (none/spectrum/wave/static/reactive/breath) | unknown vendor key | both scripts (HID path) | PARTIAL | USB validated on Basilisk V3 X; multi-zone IDs are also validated on Basilisk V3 Pro / 35K |
| Button remapping | class `0x02`, `0x8C/0x0C` button-function block | vendor `08 04 01 <slot>` + 10-byte payload | BLE implemented + USB validated (`OpenSnek` + `OpenSnekProbe`) | PARTIAL | USB uses `profile,slot,hypershift` + 7-byte function block (`class,len,data[5]`); mouse + simple keyboard remaps validate on `0x00B9`, including default restore behavior and readback. BLE slot `0x06` remains rejected (`status 0x03`); macro/media catalogs still pending on both paths. |
| Lighting/effects | class `0x0F` (OpenRazer documented) | mode (`10 03`) + scalar (`10 85`/`10 05`) + frame stream (`10 04`) | USB scroll LED effects + BLE mode/scalar/frame writes | PARTIAL | Capture review shows a shared BLE stream path for advanced effects, but OpenSnek keeps Bluetooth app controls static-only for now because the streamed profiles are software-driven and not yet good enough to ship. |
| Profiles | partially documented in ecosystem | unknown | none | UNKNOWN | Needs capture-backed mapping |

## Current Priorities

1. Decode remaining BLE vendor keys for USB-equivalent controls:
- poll rate
- scroll mode / acceleration / smart reel
- firmware

2. Expand USB button-remap action taxonomy:
- validate advanced classes (consumer/media, macro families, analog variants)
- tighten profile-layer semantics (`direct` vs persistent) and document per-device differences

3. Build common feature abstraction:
- one logical setting model with transport-specific encoders
- predictable fallback ordering per feature

## Validated Device Profile (Basilisk V3 X HyperSpeed, USB PID `0x00B9`)

Validated in-session over USB:
- working: serial, firmware, device mode read/write, poll-rate read/write, idle-time read/write, low-battery-threshold read/write, DPI/stages, battery
- working: scroll LED brightness + effects (none/spectrum/wave/static/reactive/breath single/dual/random)
- working: button remap read/write on class `0x02` (`0x8C`/`0x0C`) for tested slots (`0x01..0x05`, `0x09`, `0x0A`, `0x60`) with readback confirmation via `OpenSnekProbe` and hardware XCTest harness
- unsupported (returns `None`): scroll mode, scroll acceleration, scroll smart reel
- legacy non-analog remap write (`0x02:0x0D`) remains unreliable on this model and is now treated as fallback-only

CLI behavior has been updated to skip unsupported scroll controls with warnings instead of failing runs.

## Validated Device Profile (Basilisk V3 35K, USB PID `0x00CB`)

Validated in-session over USB:
- working: serial, firmware, device mode read/write, poll-rate read/write, DPI/stages, battery, core USB telemetry
- working: matrix brightness/effect writes on all validated LED IDs (`0x01` scroll wheel, `0x04` logo, `0x0A` underglow)
- working: button remap read/write/readback on standard slots plus the additional wheel-tilt (`0x34`, `0x35`) and top DPI-button (`0x60`) slots
- observed non-remappable controls on `0x00CB`: scroll-mode (`0x0E`, protocol-read-only), sensitivity clutch (`0x0F`, software-read-only via report-4 `0x51`), profile button (`0x6A`, software-read-only via report-4 `0x50`)
- observed alternate USB DPI-button payload on slot `0x60`: `04 02 0F 7B 00 00 00`
- shipped client behavior: normalize `0x60` to a user-facing `DPI Cycle` action and allow binding `DPI Cycle` to any writable USB slot
- client note: `0x02:0x8C` response layout is not identical to `0x00B9`; clients must validate echoed `profile`/`slot` bytes before choosing the 35K function-block offset
- observed profile summary getter on `0x00CB`: `0x00:0x87` -> `<active,0x00,count>`; active-profile write path remains unresolved

## Validated Device Profile (Basilisk V3 Pro, USB PID `0x00AB`)

Validated in-session over USB:
- working: serial, firmware, device mode read/write, poll-rate read/write, DPI/stages, battery, core USB telemetry
- working: matrix brightness/effect writes on all validated LED IDs (`0x01` scroll wheel, `0x04` logo, `0x0A` underglow)
- working: button remap read/write/readback on the shared writable Basilisk slots, wheel-tilt (`0x34`, `0x35`), and the sensitivity clutch / DPI clutch (`0x0F`)
- observed V3 Pro clutch default block on `0x0F`: `06 05 05 01 90 01 90`
- observed V3 Pro clutch DPI parameterization: writing `06 05 05 03 20 03 20` read back cleanly as an 800-DPI clutch payload on slot `0x04`
- observed V3 Pro clutch remap portability: the same block was written/read back successfully on slot `0x04`, so Open Snek treats `DPI Clutch` as a V3 Pro USB remap action and not only as the native clutch button's default
- observed profile-button default block on `0x6A`: `12 01 01 00 00 00 00`
- observed profile-button remap behavior on `0x6A`: right-click writes/readback can succeed, but repeated write/readback cycles later returned timeout/no-response frames; Open Snek keeps this slot hidden until the USB ACK/readback path is reliable
- observed non-match on `0x60`: it does not read back like the 35K top DPI-button block and is not exposed as a validated V3 Pro slot
- client note: `0x02:0x8C` response layout on the observed extended slots matches the 35K-style offset (`response[11..<18]`) rather than the Basilisk V3 X shape
- observed profile summary getter on `0x00AB`: `0x00:0x87` -> `<active,0x00,count=3>`; active-profile write path remains unresolved

## Validated BT Profile (Basilisk V3 X HyperSpeed BT PID `0x00BA`, macOS stack)

Validated in-session over Bluetooth:
- HID path (`--disable-vendor-gatt`): probe works, config command reads return `None`, writes return `False`
- passive HID DPI report on the paired BT HID interface now drives immediate Open Snek DPI-state updates; observed/app-supported frame prefixes include `05 05 02 <x_hi> <x_lo> <y_hi> <y_lo> ...` and the macOS-normalized `05 02 ...` variant
- Vendor GATT path (default-on): working for
  - idle-time raw read/write/readback
  - low-battery-threshold raw read/write/readback
  - lighting raw read/write/readback
  - battery vendor raw keys (`05 81 00 01`, `05 80 00 01`)
  - serial fallback (`01 83 00 00`)
  - device mode read fallback (`01 82 00 00`)
  - idle time fallback (`05 84 00 00` / `05 04 00 00`)
  - low battery threshold fallback (`05 82 00 00` / `05 02 00 00`)
  - button remap slots `0x01..0x05`, `0x09`, `0x0A`, `0x60`
- Vendor GATT button remap slot `0x06` returns error status (`0x03`) and is treated as a software-read-only Hypershift/sniper control on the current BLE path.
- `scroll-up-down-rebind.pcapng` confirms slot `0x09`/`0x0A` wheel-button mappings on BLE (`p0=0x0901` / `0x0A01`).
- `right-click-turbo.pcapng` confirms mouse turbo payloads on BLE (`action=0x0E`, slot `0x02`) with changing rate field.
- `basic-rebind.pcapng` includes a keyboard turbo-form payload (`action=0x0D`, key + rate fields).

`razer_ble.py` now uses vendor battery raw as BT fallback in `get_battery()` when vendor GATT is enabled.

## Validated BT Profile (Basilisk V3 Pro BT PID `0x00AC`, macOS stack)

Validated in-session over Bluetooth:
- vendor GATT path uses the same request headers and key catalog as the Basilisk V3 X HyperSpeed path, but the notify header is the shorter 8-byte variant and payload continuations may end with a short final fragment
- passive HID DPI reports are present on the paired BT HID interface with the same `05 05 02 <x_hi> <x_lo> <y_hi> <y_lo> ...` shape used by the validated V3 X Bluetooth path; a live macOS callback capture on `0x00AC` observed `900`, `2000`, and `1100` DPI stage frames
- working read/write/readback: DPI stages + active stage (`0B84`/`0B04`), sleep timeout (`05 84 00 00` / `05 04 00 00`), lighting brightness (`10 85 01 01` / `10 05 01 00`)
- working read: battery raw (`05 81 00 01`), battery status (`05 80 00 01`)
- working write ACKs on tested BLE button-remap slots: `0x01..0x05`, `0x09`, `0x0A`, `0x34`, `0x35`
- observed V3 Pro Bluetooth button-layout shape now matches the shared Basilisk family on the tested slots, so Open Snek ships the core buttons plus wheel-tilt controls on the BT profile
- not yet decoded enough to ship: sensitivity clutch (`0x0F`) restore/remap payloads, profile button (`0x6A`) restore/remap payloads
- not yet decoded enough to trust: lighting frame-color readback on `10 84 00 00`; current runtime probes return no payload even though brightness works

Validation notes:
- the required hardware XCTest gate (`OPEN_SNEK_HW=1 swift test --package-path OpenSnek --filter HardwareDpiReliabilityTests`) currently aborts under macOS TCC before CoreBluetooth can start in the unbundled test runner on this host
- the same five-step DPI stability sequence was rerun successfully through the bundled Open Snek app/service host, and every step converged for three consecutive reads before restore

## Validation Checklist

Per feature validation should include:
1. set operation ACK/success
2. read-back value match
3. persistence check after reconnect/power-cycle (when applicable)
4. behavior verification on hardware (button/scroll/lighting effects)

## References

- [USB Protocol](./USB_PROTOCOL.md)
- [BLE Protocol](./BLE_PROTOCOL.md)
- [BLE Reverse Engineering Notes](../research/BLE_REVERSE_ENGINEERING.md)
- OpenRazer driver protocol builders (`driver/razerchromacommon.c/.h`)
