# USB/BLE Feature Parity

This document is the single source of truth for feature parity between the USB HID protocol and BLE protocol paths in `open-snek`.

## Scope

Target device baseline:
- Basilisk V3 X HyperSpeed (`USB PID 0x00B9`, `BT PID 0x00BA`)

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
| Device mode | `00:84/04` | `01 82 00 00` (read), `01 02 00 00` (write candidate) | `razer_usb.py` + `razer_ble.py` | PARTIAL | BT read fallback enabled; BT write path disabled for safety. OpenSnekMac writes/reads mode on USB and shows the card only when readback is available. |
| DPI XY | `04:85/05` | passive HID read; live apply via vendor stage writes | both scripts | PARTIAL | direct BT HID `set_dpi` is not reliable on validated stack |
| DPI stages + active stage | `04:86/06` | `0B84`/`0B04`, `op=0x26` | both scripts | DONE | OpenSnekMac normalizes active-stage via stage IDs and preserves USB stage IDs on writes to avoid off-by-one stage mapping. |
| Poll rate | `00:85/05` | HID fallback only | both scripts | PARTIAL | Need BLE vendor equivalent |
| Battery level | `07:80` | Battery Service + observed vendor read | both scripts | PARTIAL | Charging-state parity still incomplete on BLE |
| Idle time | `07:83/03` | `05 84 00 00` / `05 04 00 00` | both scripts | DONE | BT vendor fallback implemented |
| Low battery threshold | `07:81/01` | `05 82 00 00` / `05 02 00 00` | both scripts | DONE | BT vendor fallback implemented. OpenSnekMac supports read/write on USB + BT, and hides USB control when unsupported. |
| Scroll mode | `02:94/14` | unknown vendor key | both scripts (HID path) | PARTIAL | USB semantics validated via OpenRazer. OpenSnekMac reads/writes on USB and hides the control when unsupported. |
| Scroll acceleration | `02:96/16` | unknown vendor key | both scripts (HID path) | PARTIAL | BLE vendor mapping missing. OpenSnekMac reads/writes on USB and hides the control when unsupported. |
| Scroll smart reel | `02:97/17` | unknown vendor key | both scripts (HID path) | PARTIAL | BLE vendor mapping missing. OpenSnekMac reads/writes on USB and hides the control when unsupported. |
| Scroll LED brightness | `0F:84/04` (`VARSTORE`, `LED=0x01`) | unknown vendor key | both scripts (HID path) | PARTIAL | USB validated; BLE vendor key not mapped |
| Scroll LED effects | `0F:02` (none/spectrum/wave/static/reactive/breath) | unknown vendor key | both scripts (HID path) | PARTIAL | USB validated on Basilisk V3 X |
| Button remapping | class `0x02`, `0x8C/0x0C` button-function block | vendor `08 04 01 <slot>` + 10-byte payload | BLE implemented + USB validated (`OpenSnekMac` + `OpenSnekProbe`) | PARTIAL | USB uses `profile,slot,hypershift` + 7-byte function block (`class,len,data[5]`); mouse + simple keyboard remaps validate on `0x00B9`, including default restore behavior and readback. BLE slot `0x06` remains rejected (`status 0x03`); macro/media catalogs still pending on both paths. |
| Lighting/effects | class `0x0F` (OpenRazer documented) | mode (`10 03`) + scalar (`10 85`/`10 05`) + frame stream (`10 04`) | USB scroll LED effects + BLE mode/scalar/frame writes | PARTIAL | OpenSnekMac is transport-scoped: USB exposes full profile/effect controls; BLE remains static-only (brightness + color). |
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

## Validated BT Profile (Basilisk V3 X HyperSpeed BT PID `0x00BA`, macOS stack)

Validated in-session over Bluetooth:
- HID path (`--disable-vendor-gatt`): probe works, config command reads return `None`, writes return `False`
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
- Vendor GATT button remap slot `0x06` returns error status (`0x03`) and is treated as unsupported in current tooling/UI.
- `scroll-up-down-rebind.pcapng` confirms slot `0x09`/`0x0A` wheel-button mappings on BLE (`p0=0x0901` / `0x0A01`).
- `right-click-turbo.pcapng` confirms mouse turbo payloads on BLE (`action=0x0E`, slot `0x02`) with changing rate field.
- `basic-rebind.pcapng` includes a keyboard turbo-form payload (`action=0x0D`, key + rate fields).

`razer_ble.py` now uses vendor battery raw as BT fallback in `get_battery()` when vendor GATT is enabled.

## Validation Checklist

Per feature validation should include:
1. set operation ACK/success
2. read-back value match
3. persistence check after reconnect/power-cycle (when applicable)
4. behavior verification on hardware (button/scroll/lighting effects)

## References

- `USB_PROTOCOL.md`
- `BLE_PROTOCOL.md`
- `BLE_REVERSE_ENGINEERING.md`
- OpenRazer driver protocol builders (`driver/razerchromacommon.c/.h`)
