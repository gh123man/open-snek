# BLE Hypershift Stream Support

## Status

OpenSnek now has initial support for the Bluetooth Hypershift / DPI-clutch press stream on the capture-validated Basilisk V3 X HyperSpeed Bluetooth profile.

Current shipped support includes:

- `OpenSnek/Sources/OpenSnekCore/DeviceSupport.swift` defines a `PassiveButtonInputDescriptor` alongside the existing passive-DPI descriptor.
- `OpenSnek/Sources/OpenSnekCore/DeviceSupport.swift` gives the Basilisk V3 X HyperSpeed Bluetooth profile a capture-backed passive button descriptor for slot `0x06`, usage `0x01:0x02`, report ID `0x04`, subtype `0x04`.
- `OpenSnek/Sources/OpenSnekHardware/PassiveButtonEventMonitor.swift` classifies passive button reports as `pressed`, `released`, or `other`.
- `OpenSnek/Sources/OpenSnek/Bridge/BridgeClient.swift` arms passive HID listeners for both the DPI stream and any capture-backed passive button streams on the device profile.
- `OpenSnek/Sources/OpenSnek/Services/BackendSession.swift` and `OpenSnek/Sources/OpenSnek/Services/AppStateRuntimeController.swift` propagate passive button edges through the existing backend-state update path.
- `OpenSnek/Sources/OpenSnek/UI/DeviceDetailView.swift` shows the read-only button row and a live `Held` badge while the button is pressed.

That means the current app can now:

- listen for passive DPI stage changes
- mark the stream as healthy from heartbeat traffic
- stop fast polling once a real DPI event is observed
- subscribe to the separate Hypershift-specific HID stream on the validated V3 X Bluetooth path
- decode press/release edges conservatively from the observed payload pattern
- expose a live UI pressed/held indicator on the read-only button row

It still cannot:

- trigger clutch behavior directly from passive HID input
- expose Hypershift stream health in diagnostics
- remap the button through a validated BLE vendor command family

## Capture-Backed Findings

### Handle `0x0027`: the Hypersense button stream

Six independent captures now confirm a passive HID notify stream on ATT handle `0x0027` that carries the Hypersense / Hypershift / DPI-clutch button:

| Capture | Press byte | Synapse binding | Notes |
|---|---|---|---|
| `full-hid-hypershift-cap.pcapng` | `0x59` | DPI clutch | older capture |
| `hs-full-caputre.pcapng` | `0x59` | DPI clutch | |
| `bt-reconnect-1.pcapng` | `0x59` | DPI clutch | includes connection setup |
| `bt-reconnect-2.pcapng` | `0x59` | DPI clutch | includes connection setup |
| `hypershift-hold-2026-03-22.pcapng` | `0x52` | different binding | March 22 focused hold |

Frame format:

```text
byte 0   report ID (always 0x04)
byte 1   action byte (0x00 = release, nonzero = press)
bytes 2-7  zero padding
```

- Press: `04 <action> 00 00 00 00 00 00`
- Release: `04 00 00 00 00 00 00 00`
- The action byte (`byte 1`) is **not** a fixed physical-button identifier. It changes depending on the Synapse-assigned function (`0x59` when DPI clutch is assigned, `0x52` under a different assignment). OpenSnek should detect press vs release only by testing `byte 1 != 0x00` vs `byte 1 == 0x00`.

### How Synapse intercepts the button

Across all captures, Synapse's behavior is consistent:

1. The mouse sends an unsolicited HID notification on `0x0027` — no polling, no vendor read loop.
2. On press (`byte 1 != 0`), Synapse immediately issues a DPI-stage write/readback (`0B 04 01 00` / `0B 84 01 00`) to apply the clutch DPI. This arrives within ~20-30 ms of the HID notification.
3. On release (`byte 1 == 0`), Synapse either writes the DPI back or does nothing depending on the binding. No vendor write is issued on the release edge itself.
4. No `08 04 01 06` vendor button-remap write appears in any capture. The button is entirely software-read; Synapse never writes to slot `0x06`.

### How to intercept the Hypersense button (for OpenSnek)

The stream is part of the standard HID-over-GATT (HOGP) profile, not the vendor GATT service. The OS subscribes to it during Bluetooth pairing/connection setup — no explicit CCCD enable by the application is needed for this handle.

**On macOS (CoreBluetooth / IOKit):**

The `0x0027` handle is an HID Input Report characteristic within the HID Service (`0x1812`). macOS exposes this through `IOHIDDeviceRegisterInputReportCallback`. OpenSnek already uses this callback path for the passive DPI stream on handle `0x002b` (report ID `0x05`).

To intercept the Hypersense button:

1. Subscribe to HID input reports on the same BLE HID device already used for passive DPI.
2. Filter for **report ID `0x04`** (byte 0 of the `0x0027` payload).
3. Read **byte 1**: nonzero = press, zero = release.
4. The report arrives on a separate HID interface/element from the DPI stream (report ID `0x05`) and the mouse movement stream (handle `0x001b`).

No vendor GATT interaction, CCCD write, or polling is needed. The button event arrives passively as an HID input report, just like mouse movement.

**On Windows:**

Windows HOGP driver subscribes to `0x0027` during Bluetooth connection setup before BTVS/Wireshark can capture. This is confirmed by the reconnect captures: `0x0027` notifications arrive without any visible application-side CCCD write for that handle. The only explicit CCCD enable visible in captures is for the vendor notify handle `0x0040`.

### Related handles

| Handle | Report ID | Content | Stream type |
|---|---|---|---|
| `0x001b` | none | Mouse movement/buttons (X/Y deltas) | HID input — continuous |
| `0x0027` | `0x04` | Hypersense button press/release | HID input — event-driven |
| `0x002b` | `0x05` | DPI stage changes + heartbeat (`0x10` subtype) | HID input — event-driven |
| `0x002f` | unknown | Fires once with `00 00 00 00 00 00 00 00` on connection | HID input — one-shot |
| `0x003d` | n/a | Vendor write characteristic | Vendor GATT |
| `0x003f` | n/a | Vendor notify characteristic | Vendor GATT |

### Connection-time behavior

The reconnect captures (`bt-reconnect-1`, `bt-reconnect-2`) show that immediately after Bluetooth connection completes:

1. The `0x002b` heartbeat stream starts immediately with `05 10 00 00 00 00 00 00`.
2. Handle `0x0027` may emit a stray release (`04 00 00 00 00 00 00 00`) before any button press. OpenSnek should not treat this as a meaningful release edge.
3. Handle `0x002f` may emit a single all-zeros frame.
4. Synapse then performs its initialization sequence (device info reads, serial number, battery, etc.) on the vendor path before reacting to button events.

### Negative findings

- No `08 04 01 06` vendor write appears in any capture. Slot `0x06` is confirmed software-read-only on the BLE vendor path.
- The earlier `hypershift-hold-2026-03-22.md` noted a press byte change from `0x59` to `0x52` and inferred it was mapping-dependent. The reconnect captures now confirm this: all captures where DPI clutch was the active Synapse binding show `0x59`; the March 22 capture with a different binding shows `0x52`.

## What OpenSnek Still Needs To Support

### 1. Runtime behavior for clutch press/release

Supporting the stream is not just capture and decode. The app needs a policy for what to do on press and release.

For the current Synapse-like DPI clutch behavior, OpenSnek would need:

- on press:
  - determine the configured clutch DPI
  - cache the pre-clutch active DPI/stage state
  - apply the clutch target DPI, likely through the existing BLE DPI-stage write path
- on release:
  - restore the previous active DPI/stage state

Needed safeguards:

- latest-wins semantics for repeated rapid presses
- release handling that is robust if a readback is stale
- reconnect-safe clearing of any “button still held” state

### 2. A separate transport-status surface

Current diagnostics only describe the passive DPI stream through `OpenSnek/Sources/OpenSnek/Services/AppStateTypes.swift`:

- `listening`
- `streamActive`
- `realTimeHID`
- `pollingFallback`

Needed:

- a second status for Hypershift stream readiness, separate from DPI
- diagnostics/UI wording such as:
  - `Hypershift HID listening`
  - `Hypershift HID active`
  - `Hypershift HID unavailable`

Why:

- a device can have healthy passive DPI streaming while Hypershift remains unsupported
- mixing the two into one status would be misleading

### 3. Device-profile metadata for additional supported products

Needed:

- initially only on capture-validated devices
- likely separate validation for:
  - Basilisk V3 X HyperSpeed Bluetooth (`0x00BA`)
  - any future Bluetooth devices that show the same stream shape

Why:

- OpenSnek intentionally gates passive HID features behind capture-backed profile data
- this avoids subscribing to the wrong HID interface on unrelated devices

### 4. Test coverage beyond the initial landing

Minimum tests needed before shipping:

- parser tests for press and release frames
- regression tests proving DPI packets still parse unchanged
- backend tests for press -> apply clutch -> release -> restore flow
- duplicate-event / reconnect-state tests

### 5. Windows HID GATT enumeration (optional, for full descriptor mapping)

The reconnect captures confirmed that Windows subscribes to `0x0027` during Bluetooth connection setup before BTVS can capture. The stream is standard HOGP, not vendor GATT. The button is already interceptable on macOS without any additional discovery.

For completeness, running `tools/python/enumerate_hid_gatt.py` would map the exact characteristic UUID and Report Reference descriptor for `0x0027`, `0x002b`, and `0x002f`. This is nice-to-have documentation, not a blocker for implementation.

Script:

- `tools/python/enumerate_hid_gatt.py`

Commands:

```bash
python tools/python/enumerate_hid_gatt.py XX:XX:XX:XX:XX:XX
# or
python tools/python/enumerate_hid_gatt.py --name "BSK V3 X"
```

## Recommended Follow-Up Order

1. ~~Capture the stream from connection start and identify the characteristic/descriptor path.~~ Done — reconnect captures confirmed passive HOGP delivery on `0x0027`, report ID `0x04`.
2. Add clutch press/release runtime behavior using the existing BLE DPI-stage write path.
3. Add separate Hypershift transport diagnostics.
4. Expand profile coverage only after capture-backed validation on each device.
5. Add reconnect and duplicate-edge hardening tests.
6. Optionally run `enumerate_hid_gatt.py` to document the exact characteristic UUID for `0x0027`.

## Bottom Line

The Hypersense button's Bluetooth path is now fully understood. It is a passive HID input report on ATT handle `0x0027` (report ID `0x04`), delivered through standard HOGP — not the vendor GATT service. The OS subscribes to it automatically during Bluetooth connection. No polling, no vendor commands, no CCCD writes from the application.

To intercept it, OpenSnek subscribes to HID input reports on the BLE device (same callback path already used for passive DPI), filters for report ID `0x04`, and reads byte 1 for press/release. The existing `PassiveButtonInputDescriptor` and `PassiveButtonEventMonitor` are already wired for this.

What is still missing is the runtime policy that turns validated press/release edges into clutch apply/restore behavior, plus diagnostics and broader device validation.
