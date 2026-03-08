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
| Serial read | `00:82` | observed key `01 83 00 00` | `razer_usb.py` + `razer_ble.py` (HID path) | PARTIAL | Need stable BLE vendor mapping |
| Firmware read | `00:81` | unknown vendor key | `razer_usb.py` + `razer_ble.py` (HID path) | PARTIAL | HID over BT may fail on some stacks |
| Device mode | `00:84/04` | unknown vendor key | `razer_usb.py` + `razer_ble.py` (HID path) | PARTIAL | Mode semantics known on USB only |
| DPI XY | `04:85/05` | passive HID read, HID set fallback | both scripts | PARTIAL | BLE vendor set path not fully mapped |
| DPI stages + active stage | `04:86/06` | `0B84`/`0B04`, `op=0x26` | both scripts | DONE | Fully implemented in BLE vendor path |
| Poll rate | `00:85/05` | HID fallback only | both scripts | PARTIAL | Need BLE vendor equivalent |
| Battery level | `07:80` | Battery Service + observed vendor read | both scripts | PARTIAL | Charging-state parity still incomplete on BLE |
| Idle time | `07:83/03` | unknown vendor key | both scripts (HID path) | PARTIAL | USB clamps 60..900s |
| Low battery threshold | `07:81/01` | unknown vendor key | both scripts (HID path) | PARTIAL | USB raw clamp `0x0C..0x3F` |
| Scroll mode | `02:94/14` | unknown vendor key | both scripts (HID path) | PARTIAL | USB semantics validated via OpenRazer |
| Scroll acceleration | `02:96/16` | unknown vendor key | both scripts (HID path) | PARTIAL | BLE vendor mapping missing |
| Scroll smart reel | `02:97/17` | unknown vendor key | both scripts (HID path) | PARTIAL | BLE vendor mapping missing |
| Scroll LED brightness | `0F:84/04` (`VARSTORE`, `LED=0x01`) | unknown vendor key | both scripts (HID path) | PARTIAL | USB validated; BLE vendor key not mapped |
| Scroll LED effects | `0F:02` (none/spectrum/wave/static/reactive/breath) | unknown vendor key | both scripts (HID path) | PARTIAL | USB validated on Basilisk V3 X |
| Button remapping | class `0x02`, `0x0D/0x12` family | vendor `08 04 01 <slot>` + 10-byte payload | BLE implemented + USB experimental raw writer | PARTIAL | Need validated USB action catalog and safe helpers |
| Lighting/effects | class `0x0F` (OpenRazer documented) | raw scalar lighting (`10 85`/`10 05`) | USB scroll LED effects + BLE raw scalar | PARTIAL | No full cross-transport effect abstraction yet |
| Profiles | partially documented in ecosystem | unknown | none | UNKNOWN | Needs capture-backed mapping |

## Current Priorities

1. Decode BLE vendor keys for USB-equivalent controls:
- poll rate
- idle time
- low battery threshold
- scroll mode / acceleration / smart reel
- device mode / firmware / serial

2. Implement USB button remapping path:
- class `0x02` command family (`0x0D`/`0x12`), capture-backed payloads
- align action taxonomy with BLE `10-byte` payload model

3. Build common feature abstraction:
- one logical setting model with transport-specific encoders
- predictable fallback ordering per feature

## Validated Device Profile (Basilisk V3 X HyperSpeed, USB PID `0x00B9`)

Validated in-session over USB:
- working: serial, firmware, device mode read/write, poll-rate read/write, idle-time read/write, low-battery-threshold read/write, DPI/stages, battery
- working: scroll LED brightness + effects (none/spectrum/wave/static/reactive/breath single/dual/random)
- unsupported (returns `None`): scroll mode, scroll acceleration, scroll smart reel
- USB remap probes (`0x02:0x0D`) still return `not_supported` on this model with tested payloads

CLI behavior has been updated to skip unsupported scroll controls with warnings instead of failing runs.

## Validated BT Profile (Basilisk V3 X HyperSpeed BT PID `0x00BA`, macOS stack)

Validated in-session over Bluetooth HID path (vendor GATT disabled):
- device detection/probe: works
- HID command-path reads (`serial`, `firmware`, `dpi`, `poll_rate`, `idle`, `battery`, `scroll_led_brightness`): returned `None`
- HID command-path writes (`poll_rate`, `idle`, `low_battery_threshold`, `scroll LED controls`): returned `False`

Interpretation: on this stack, BT HID transport is present but not returning usable command responses for configuration commands.

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
