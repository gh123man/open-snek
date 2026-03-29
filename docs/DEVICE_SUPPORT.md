# Device Support Matrix

This page is the shipped OpenSnek support matrix by device and transport.

This pass is derived from the implementation, not just protocol notes:
- device/profile metadata: [`OpenSnek/Sources/OpenSnekCore/DeviceSupport.swift`](../OpenSnek/Sources/OpenSnekCore/DeviceSupport.swift)
- USB state + writes: [`OpenSnek/Sources/OpenSnek/Bridge/BridgeClient+USB.swift`](../OpenSnek/Sources/OpenSnek/Bridge/BridgeClient+USB.swift)
- Bluetooth state + writes: [`OpenSnek/Sources/OpenSnek/Bridge/BridgeClient+Bluetooth.swift`](../OpenSnek/Sources/OpenSnek/Bridge/BridgeClient+Bluetooth.swift)
- UI exposure and feature gating: [`OpenSnek/Sources/OpenSnek/UI/DeviceDetailView.swift`](../OpenSnek/Sources/OpenSnek/UI/DeviceDetailView.swift) and [`OpenSnek/Sources/OpenSnek/Services/EditorStore.swift`](../OpenSnek/Sources/OpenSnek/Services/EditorStore.swift)

This matrix tracks shipped hardware-facing support. Internal editor/workspace plumbing does not count as shipped device support unless the hardware behavior is actually exposed and supported in the app.

Use [docs/protocol/PARITY.md](./protocol/PARITY.md) for lower-level reverse-engineering notes and capture-backed protocol gaps.

## Status Key

Overall transport status:
- `Validated`: the shipped profile is locally validated in `DeviceSupport.swift`
- `Mapped`: the shipped profile exists, but the profile metadata is still marked unvalidated
- `No transport`: that device does not offer that transport

Feature rows:
- `Shipped`: implemented in the backend and surfaced by the current app for that device/transport
- `Limited`: shipped, but with reduced scope such as static-only lighting or documented read-only button slots
- `Mapped`: comes from a shipped but still unvalidated mapped profile
- `Not shipped`: the app intentionally does not claim or expose this hardware feature as supported yet
- `Hidden`: the current bridge/UI does not surface that feature on this transport
- `Scalar only`: the profile does not ship independent X/Y DPI editing
- `Single slot`: no multi-slot onboard button-profile workflow exists for that device/transport

## Quick Summary

| Device | USB | BT | Biggest Gaps |
|---|---|---|---|
| Basilisk V3 X HyperSpeed | `Validated` | `Validated` | Bluetooth keeps lighting to static color, hides poll-rate and threshold controls, and leaves the Hypershift/sniper path read-only |
| Basilisk V3 | `Mapped` | `No transport` | The whole USB profile is still the unvalidated mapped profile |
| Basilisk V3 Pro | `Validated` | `Validated` | Bluetooth keeps lighting static-only, hides poll-rate and threshold controls, and does not ship clutch/profile-button remap |
| Basilisk V3 35K | `Validated` | `No transport` | Onboard hardware profiles are still not shipped, and a few buttons remain unsupported footnotes instead of editable controls |

## Basilisk V3 X HyperSpeed

USB PID `0x00B9`, Bluetooth PID `0x00BA`

| Feature Area | USB | BT | Notes |
|---|---|---|---|
| Overall transport status | `Validated` | `Validated` | Both transports ship today |
| DPI stages + active stage | `Shipped` | `Shipped` | Bluetooth state comes from `readBluetoothState()` plus the passive DPI tracker |
| Independent X/Y DPI | `Scalar only` | `Scalar only` | This profile ships scalar DPI only because `supportsIndependentXYDPI` is false on both transports |
| Poll rate | `Shipped` | `Hidden` | USB uses the shared `getPollRate` / `setPollRate` path; Bluetooth state hard-codes `poll_rate: nil` and `capabilities.poll_rate: false` |
| Sleep timeout | `Shipped` | `Shipped` | USB reads `getIdleTime`; Bluetooth reads `powerTimeoutGet` and exposes the power-management card |
| Low battery threshold | `Shipped` | `Hidden` | USB reads `getLowBatteryThreshold`; Bluetooth never puts a threshold value into `MouseState`, so the UI never renders the threshold card |
| Battery telemetry | `Shipped` | `Shipped` | Bluetooth uses vendor battery reads; the AA-powered BT path intentionally reports `charging = false` |
| Lighting: brightness + static color | `Shipped` | `Shipped` | The profile ships one lighting zone (`0x01`) on both transports |
| Lighting: extra effects | `Shipped` | `Limited` | USB exposes `off`, `static`, `spectrum`, `wave`, `reactive`, `pulseSingle`, `pulseDual`, and `pulseRandom`; Bluetooth is static-only because the BT profile advertises only `.staticColor` |
| Button remap: shipped editable slots | `Shipped` | `Shipped` | USB and BT writable slots are `1-5`, `9`, `10`, and `96` from the profile metadata |
| Button remap: unsupported slots | `Shipped` | `Hidden` | USB has no extra unsupported slots documented on this profile; Bluetooth slot `6` Hypershift/sniper is not surfaced as a control and only appears in the unsupported-buttons footnote |
| Scroll controls | `Shipped` | `Hidden` | USB has shared `get/setScrollMode`, `get/setScrollAcceleration`, and `get/setScrollSmartReel`; Bluetooth never populates those state fields and the UI excludes BT scroll controls |
| Onboard hardware profiles | `Single slot` | `Single slot` | Both transports ship with `onboardProfileCount = 1`, so there is no hardware multi-profile surface to expose here |

## Basilisk V3

USB PID `0x0099`, no Bluetooth transport

| Feature Area | USB | BT | Notes |
|---|---|---|---|
| Overall transport status | `Mapped` | `No transport` | The shipped USB profile is derived from OpenRazer plus the 35K layout, not yet locally validated in OpenSnek |
| DPI stages + active stage | `Mapped` | `No transport` | The mapped USB profile clamps DPI to `26,000` |
| Independent X/Y DPI | `Scalar only` | `No transport` | The mapped V3 USB profile ships with `supportsIndependentXYDPI = false` |
| Poll rate | `Mapped` | `No transport` | Uses the shared USB poll-rate read/write path through the mapped profile |
| Sleep timeout | `Mapped` | `No transport` | Uses the shared USB idle-time path through the mapped profile |
| Low battery threshold | `Mapped` | `No transport` | Uses the shared USB threshold path through the mapped profile |
| Battery telemetry | `Mapped` | `No transport` | Uses the shared USB battery path through the mapped profile |
| Lighting: brightness + static color | `Mapped` | `No transport` | The mapped profile ships the same three zones as the 35K (`0x01`, `0x04`, `0x0A`) |
| Lighting: extra effects | `Mapped` | `No transport` | The mapped USB profile advertises `off`, `static`, `spectrum`, and `wave` |
| Button remap: shipped editable slots | `Mapped` | `No transport` | The mapped USB profile exposes writable slots `1-5`, `9`, `10`, `15`, `52`, `53`, and `96` |
| Button remap: unsupported slots | `Hidden` | `No transport` | The mapped profile documents slot `14` and slot `106` as unsupported footnote entries rather than editable controls |
| Scroll controls | `Mapped` | `No transport` | The mapped profile rides the same shared USB scroll-control implementation as the other USB Basilisk profiles |
| Onboard hardware profiles | `Not shipped` | `No transport` | OpenSnek does not currently claim shipped onboard hardware-profile support for the wired V3 |

## Basilisk V3 Pro

USB PIDs `0x00AA` / `0x00AB`, Bluetooth PID `0x00AC`

| Feature Area | USB | BT | Notes |
|---|---|---|---|
| Overall transport status | `Validated` | `Validated` | Both transports ship today |
| DPI stages + active stage | `Shipped` | `Shipped` | USB and BT both ship stage editing; the BT path also feeds passive HID DPI updates into app state |
| Independent X/Y DPI | `Shipped` | `Shipped` | `supportsIndependentXYDPI` is true on both transports |
| Poll rate | `Shipped` | `Hidden` | USB uses the shared `getPollRate` / `setPollRate` path; BT hard-codes `poll_rate: nil` and `capabilities.poll_rate: false` |
| Sleep timeout | `Shipped` | `Shipped` | USB reads idle time; BT reads `powerTimeoutGet` and exposes the same power-management card |
| Low battery threshold | `Shipped` | `Hidden` | USB reads and writes threshold values; BT does not populate `low_battery_threshold_raw`, so the current app never shows the threshold card there |
| Battery telemetry | `Shipped` | `Shipped` | BT state publishes percent and charging through `resolveBluetoothBatteryState` |
| Lighting: brightness + static color | `Shipped` | `Shipped` | USB ships three zones with advanced effects; BT ships per-zone brightness and per-zone static color on `0x01`, `0x04`, and `0x0A` |
| Lighting: extra effects | `Shipped` | `Limited` | USB advertises `off`, `static`, `spectrum`, and `wave`; BT is static-only because the BT profile advertises only `.staticColor` |
| Button remap: shipped editable slots | `Shipped` | `Shipped` | USB writable slots are `1-5`, `9`, `10`, `15`, `52`, `53`; BT writable slots are `1-5`, `9`, `10`, `52`, `53` |
| Button remap: unsupported slots | `Hidden` | `Hidden` | USB profile button `106` is kept out of the editable layout; BT clutch `15` and profile button `106` are also kept out of the editable layout and only appear as unsupported footnotes |
| Scroll controls | `Shipped` | `Hidden` | V3 Pro USB uses the shared `get/setScrollMode`, `get/setScrollAcceleration`, and `get/setScrollSmartReel` implementation, and the scroll card is rendered from those state values on USB; BT never publishes those fields and the UI excludes BT scroll controls |
| Onboard hardware profiles | `Not shipped` | `Not shipped` | OpenSnek does not currently claim shipped onboard hardware-profile support for the V3 Pro on either transport |

## Basilisk V3 35K

USB PID `0x00CB`, no Bluetooth transport

| Feature Area | USB | BT | Notes |
|---|---|---|---|
| Overall transport status | `Validated` | `No transport` | USB profile is locally validated |
| DPI stages + active stage | `Shipped` | `No transport` | Real-time passive HID updates are shipped on the USB path |
| Independent X/Y DPI | `Shipped` | `No transport` | `supportsIndependentXYDPI` is true |
| Poll rate | `Shipped` | `No transport` | Uses the shared USB poll-rate path |
| Sleep timeout | `Shipped` | `No transport` | Uses the shared USB idle-time path |
| Low battery threshold | `Shipped` | `No transport` | Uses the shared USB threshold path |
| Battery telemetry | `Shipped` | `No transport` | Uses the shared USB battery path |
| Lighting: brightness + static color | `Shipped` | `No transport` | The USB profile ships three zones: `scroll_wheel`, `logo`, and `underglow` |
| Lighting: extra effects | `Shipped` | `No transport` | The 35K USB profile advertises `off`, `static`, `spectrum`, and `wave` |
| Button remap: shipped editable slots | `Shipped` | `No transport` | Writable slots are `1-5`, `9`, `10`, `15`, `52`, `53`, and `96` |
| Button remap: unsupported slots | `Hidden` | `No transport` | Slot `14` and slot `106` are documented as unsupported footnote entries rather than editable controls |
| Scroll controls | `Shipped` | `No transport` | The 35K USB profile uses the shared `get/setScrollMode`, `get/setScrollAcceleration`, and `get/setScrollSmartReel` implementation |
| Onboard hardware profiles | `Not shipped` | `No transport` | OpenSnek does not currently claim shipped onboard hardware-profile support for the 35K |

## References

- [Protocol Index](./protocol/PROTOCOL.md)
- [USB/BLE Parity](./protocol/PARITY.md)
- [Build, Probe, and Validation Notes](../OpenSnek/README.md)
