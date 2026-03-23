# Hypersense DPI Clutch — Design Document

## Problem

The Basilisk V3 X HyperSpeed has a "Hypersense" button (slot `0x06`) that Synapse uses as a DPI clutch: hold to temporarily change DPI, release to restore. The button is software-read-only — the mouse firmware does not expose it through the `08 04 01 <slot>` vendor remap family, so OpenSnek cannot reassign it. But OpenSnek can *listen* to it and react.

The capture-backed protocol path is now fully understood (see `docs/research/BLE_HYPERSHIFT_STREAM_SUPPORT.md`). This document describes how to wire up the runtime clutch behavior in the current codebase.

## Protocol Summary

The button arrives as a **passive HID input report** through standard HOGP on ATT handle `0x0027`:

```text
report ID: 0x04
press:     04 <action> 00 00 00 00 00 00   (byte 1 != 0)
release:   04 00 00 00 00 00 00 00          (byte 1 == 0)
```

The OS subscribes automatically — no CCCD write, no polling. On macOS this surfaces through `IOHIDDeviceRegisterInputReportCallback`, the same callback path already used for the passive DPI stream (report ID `0x05` on handle `0x002b`).

When Synapse receives a press, it reacts by writing the existing DPI-stage table (`0B 04 01 00`) with only the **active stage token** changed to select the clutch DPI. On release, it writes the table again to restore the previous active stage. No special clutch API exists.

## Existing Infrastructure

### Already built

| Component | Location | What it does |
|---|---|---|
| `PassiveDPIInputDescriptor` | `DeviceSupport.swift` | Declares HID usage, report ID, subtype for a passive stream |
| `PassiveDPIParser` | `PassiveDPIParser.swift` | Classifies HID reports by report ID + subtype |
| `PassiveDPIEventMonitor` | `USBPassiveDPIEventMonitor.swift` | IOKit HID listener; dispatches parsed events |
| `BridgeClient.passiveDpiEventStream()` | `BridgeClient.swift` | AsyncStream that propagates parsed DPI events |
| `BridgeClient.btSetDpiStages()` | `BridgeClient+Bluetooth.swift` | Full DPI-stage write with snapshot preservation and stale-read masking |
| `btDpiSnapshotByDeviceID` | `BridgeClient.swift` | Cached DPI snapshot (active, count, slots, stageIDs, marker) |
| `ButtonBindingDraft.clutchDPI` | `DeviceSupport.swift` | Optional clutch DPI value already on the binding model |
| `ButtonSlotAccess.softwareReadOnly` | `DeviceSupport.swift` | Slot 6 is already declared as software-read-only on Bluetooth profiles |
| `BackendSession` passive event loop | `BackendSession.swift` | Listens to `passiveDpiEventStream` / `passiveDpiHeartbeatStream` and pushes state updates |
| `AppStateDeviceController` | `AppStateDeviceController.swift` | Manages transport status lifecycle for passive streams |

### Not yet built

| Component | What's needed |
|---|---|
| A passive HID subscription for report ID `0x04` | New descriptor + monitor target alongside the existing `0x05` DPI stream |
| A clutch state machine | Receives press/release edges and drives DPI writes |
| A clutch DPI configuration surface | User sets the target DPI for clutch hold |
| Clutch transport diagnostics | Separate from DPI transport status |

## Design

### 1. Add a passive button input descriptor to the device profile

Extend `DeviceProfile` with an optional descriptor for the Hypersense button stream, parallel to the existing `passiveDPIInput`:

```swift
// DeviceSupport.swift

public struct PassiveButtonInputDescriptor: Hashable, Codable, Sendable {
    public let usagePage: Int      // 0x01
    public let usage: Int          // 0x02
    public let reportID: UInt8     // 0x04
    public let minInputReportSize: Int
}

public struct DeviceProfile: Hashable, Sendable {
    // ... existing fields ...
    public let passiveButtonInput: PassiveButtonInputDescriptor?
}
```

Set this on the Basilisk V3 X Bluetooth profile:

```swift
passiveButtonInput: PassiveButtonInputDescriptor(
    usagePage: 0x01,
    usage: 0x02,
    reportID: 0x04,
    minInputReportSize: 8
)
```

### 2. Add a passive button event classifier

Create a lightweight parser, similar to `PassiveDPIParser`, that classifies report ID `0x04` reports:

```swift
// PassiveButtonParser.swift (new, in OpenSnekHardware)

public enum PassiveButtonEdge: Sendable {
    case pressed    // byte 1 != 0x00
    case released   // byte 1 == 0x00
}

public enum PassiveButtonParser {
    public static func classify(
        report: Data,
        descriptor: PassiveButtonInputDescriptor
    ) -> PassiveButtonEdge? {
        // Find the report-ID-prefixed payload (same normalization as PassiveDPIParser)
        // Return .pressed if byte after report ID != 0, .released if == 0
        // Return nil if report doesn't match descriptor
    }
}
```

### 3. Subscribe to button reports alongside DPI reports

In `BridgeClient`, the existing `listDevices()` call arms passive DPI targets via `PassiveDPIEventMonitor.replaceTargets()`. Extend this to also register targets for the button stream.

Since both streams arrive on the same HID device (same VID/PID, same BLE connection), the existing `IOHIDDeviceRegisterInputReportCallback` already receives *all* input reports from the device. The change is in the **dispatch logic**: the callback currently only classifies reports against the DPI descriptor. It should also check report ID `0x04` against the button descriptor.

**Option A (recommended): Extend `PassiveDPIEventMonitor` to also emit button edges.**

The monitor already has the IOKit callback registered. Add a second classification branch in the callback:

```swift
// In the IOKit input report callback:
if let dpiResult = PassiveDPIParser.classify(report, descriptor: dpiDescriptor) {
    // existing DPI handling
} else if let buttonDescriptor = context.buttonDescriptor,
          let edge = PassiveButtonParser.classify(report, descriptor: buttonDescriptor) {
    // new: emit button edge
    context.buttonCallback?(deviceID, edge, Date())
}
```

This avoids registering a second IOKit callback on the same device.

**Option B: Create a separate `PassiveButtonEventMonitor`.**

Cleaner separation of concerns, but would require a second IOKit callback registration on the same HID device, which adds complexity for no functional benefit.

### 4. Add a button edge AsyncStream to BridgeClient

```swift
// BridgeClient.swift

struct PassiveButtonEvent: Sendable {
    let deviceID: String
    let edge: PassiveButtonEdge
    let observedAt: Date
}

func passiveButtonEventStream() -> AsyncStream<PassiveButtonEvent>
```

Wired the same way as `passiveDpiEventStream()` — continuations stored in the actor, yielded from the monitor callback.

### 5. Implement the clutch state machine

This is the core new logic. It belongs in `BridgeClient` (or a dedicated helper type owned by `BridgeClient`) because it needs direct access to `btDpiSnapshotByDeviceID` and `btSetDpiStages()`.

```swift
// ClutchController.swift (new, or inline in BridgeClient)

actor ClutchController {
    struct ClutchState {
        let preClutchActive: Int
        let preClutchValues: [Int]
        let appliedAt: Date
    }

    private var activeClutchByDeviceID: [String: ClutchState] = [:]

    func handlePress(deviceID: String, clutchDPI: Int, bridge: BridgeClient) async {
        // 1. Read current DPI snapshot from cache (btDpiSnapshotByDeviceID)
        //    - If no cached snapshot, read fresh via btGetDpiStages()
        //    - If read fails, drop the event (don't clutch with unknown state)
        //
        // 2. Save pre-clutch state:
        //    ClutchState(preClutchActive: snapshot.active, preClutchValues: snapshot.values)
        //
        // 3. Write clutch DPI:
        //    - Build a single-value stage list [clutchDPI] or
        //      reuse the existing stage table with active changed to a slot holding clutchDPI
        //    - Call btSetDpiStages(device, active: clutchIndex, values: clutchValues)
        //
        // 4. Store clutch state in activeClutchByDeviceID
    }

    func handleRelease(deviceID: String, bridge: BridgeClient) async {
        // 1. Look up activeClutchByDeviceID[deviceID]
        //    - If nil (no press recorded), ignore
        //
        // 2. Restore pre-clutch state:
        //    btSetDpiStages(device, active: saved.preClutchActive, values: saved.preClutchValues)
        //
        // 3. Remove from activeClutchByDeviceID
    }

    func clearOnDisconnect(deviceID: String) {
        activeClutchByDeviceID.removeValue(forKey: deviceID)
    }
}
```

#### Clutch DPI write strategy

Synapse writes the full 5-stage table with only the active token changed. OpenSnek should do the same:

1. Take the cached snapshot (`btDpiSnapshotByDeviceID[deviceID]`).
2. On press: find or create a stage slot that holds `clutchDPI`. Write the full table with that slot as active.
3. On release: write the full table with the original active stage restored.

This preserves stage IDs and the marker byte, matching Synapse's observed behavior exactly.

#### Edge cases

| Scenario | Behavior |
|---|---|
| Rapid press-press (no release between) | Latest-wins: save new pre-clutch state only if no active clutch; if clutch already active, just update the clutch DPI target |
| Release without press | Ignore — `activeClutchByDeviceID` will be empty |
| Stray release on connection | Ignore — same as above; connection-time `04 00` is harmless |
| Disconnect while held | `clearOnDisconnect()` drops the clutch state; next connection starts clean |
| DPI write fails | Log and clear clutch state — don't leave the user stuck at clutch DPI |
| Pre-clutch read fails | Drop the press event; don't clutch without a known restore point |

### 6. Wire the clutch controller into BackendSession

`BackendSession` already has the passive event loop pattern. Add a third listener:

```swift
// BackendSession.swift — in startEventListeners()

Task { [weak self] in
    let stream = await self.client.passiveButtonEventStream()
    for await event in stream {
        await self?.handlePassiveButtonEvent(event)
    }
}
```

`handlePassiveButtonEvent` looks up the device's configured `clutchDPI` (from the button binding draft or a dedicated preference) and delegates to `ClutchController.handlePress/handleRelease`.

### 7. Clutch DPI configuration

The user needs a way to set the target clutch DPI. Two options:

**Option A (simple, recommended first):** Use the existing `ButtonBindingDraft.clutchDPI` field. The slot-6 row in the UI already shows as software-read-only with a note. Add a DPI picker to that row:

```
Hypershift / Sniper    [Software read-only]    Clutch DPI: [400 ▾]
```

The `clutchDPI` value is stored in `DevicePreferenceStore` keyed by device ID, since the button can't be written to the device.

**Option B (later):** A dedicated "Clutch Settings" section in the device detail view, separate from the button table.

### 8. Clutch transport diagnostics

Add a second transport status enum for the button stream, separate from DPI:

```swift
// AppStateTypes.swift

public enum ButtonStreamTransportStatus: String, Codable, Sendable {
    case unsupported
    case listening
    case active
}
```

Track in `AppStateDeviceController` alongside `dpiUpdateTransportStatusByDeviceID`. Update to `.active` on first button edge received.

Surface in the diagnostics view:

```
DPI stream:        Real-time HID ✓
Button stream:     Active ✓
```

### 9. UI: live held indicator

The existing `BLE_HYPERSHIFT_STREAM_SUPPORT.md` mentions a live "Held" badge. This wires through the same state path:

1. `ClutchController` publishes clutch-active state.
2. `BackendSession` includes it in `BackendStateUpdate.deviceState`.
3. `AppStateDeviceController` exposes it to the view.
4. `DeviceDetailView` shows a "Held" badge on the slot-6 row while `activeClutchByDeviceID[deviceID] != nil`.

## File Change Summary

| File | Change |
|---|---|
| `OpenSnekCore/DeviceSupport.swift` | Add `PassiveButtonInputDescriptor`, add `passiveButtonInput` to `DeviceProfile`, set on V3 X BT profile |
| `OpenSnekHardware/PassiveButtonParser.swift` | **New** — report classifier for `0x04` |
| `OpenSnekHardware/USBPassiveDPIEventMonitor.swift` | Extend IOKit callback to also classify button reports |
| `OpenSnek/Bridge/BridgeClient.swift` | Add `passiveButtonEventStream()`, button event continuations, arm button targets in `listDevices()` |
| `OpenSnek/Bridge/ClutchController.swift` | **New** — clutch state machine |
| `OpenSnek/Services/BackendSession.swift` | Add button event listener, wire to `ClutchController` |
| `OpenSnek/Services/AppStateTypes.swift` | Add `ButtonStreamTransportStatus` |
| `OpenSnek/Services/AppStateDeviceController.swift` | Track button stream status |
| `OpenSnekAppSupport/DevicePreferenceStore.swift` | Store user-configured clutch DPI per device |
| `OpenSnek/UI/DeviceDetailView.swift` | Clutch DPI picker on slot-6 row, "Held" badge |

## Implementation Order

1. **`PassiveButtonInputDescriptor` + `PassiveButtonParser`** — types and unit tests. No runtime wiring yet.
2. **Extend the HID monitor** — emit button edges from the existing IOKit callback. Verify edges arrive with a debug log.
3. **`passiveButtonEventStream`** — wire through `BridgeClient`. Verify in `BackendSession` logs.
4. **`ClutchController`** — state machine with unit tests for press/release/disconnect/rapid-press.
5. **Wire clutch into `BackendSession`** — press triggers DPI write, release restores. End-to-end on real hardware.
6. **Clutch DPI preference** — persist user's target DPI.
7. **UI** — slot-6 DPI picker, held badge, button stream diagnostics.
8. **Tests** — parser tests, state machine tests, stale-read interaction tests.

## What This Does Not Cover

- Remapping slot `0x06` to a different function (the mouse firmware rejects writes to this slot over BLE).
- USB clutch behavior (already handled differently via the USB function block path).
- Other devices beyond the V3 X Bluetooth profile (need capture-backed validation per device).
- The meaning of the action byte (`0x59`, `0x52`, etc.) — OpenSnek only needs press vs release.
