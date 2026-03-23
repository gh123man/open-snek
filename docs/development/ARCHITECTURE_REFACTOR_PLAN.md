# OpenSnek Architecture Refactoring Plan

## Context

The codebase has accumulated significant duplication and monolithic files, particularly in the Python tooling (~3,800 LOC across two nearly-identical files) and several Swift service/bridge files (5 files over 1,000 LOC each). The goal is to reduce total LOC, improve serviceability, and clean up architecture — without adding features or breaking existing tests.

**Estimated total LOC reduction: ~2,500–2,800 lines**

---

## Phase 1: Python Tools — Extract Shared Base (~1,800 LOC saved)

Highest ROI. `razer_ble.py` (2,282 lines) and `razer_usb.py` (1,547 lines) duplicate ~80% of their code.

### 1.1 Create `tools/python/razer_common.py`
- Extract 47 duplicated constants (`USB_VENDOR_ID_RAZER`, `CMD_*`, `STATUS_*`, UUIDs, `KNOWN_MICE`, etc.)
- Extract shared helpers: `_parse_rgb_hex()`, `print_status()`

### 1.2 Create `RazerMouseBase` class in `razer_common.py`
- Move ~52 identical methods into base class (`_calculate_crc`, `_create_report`, `_send_command`, `get_dpi`, `set_dpi`, `get_dpi_stages`, `set_dpi_stages`, `get_poll_rate`, `set_poll_rate`, `get_battery`, scroll methods, LED methods, button methods, etc.)
- BLE subclass overrides ~8 methods that add vendor GATT fallback paths
- USB subclass overrides little to nothing

### 1.3 Extract `_CBVendorTxnDelegate` / `_CBVendorTxn` into `tools/python/cb_vendor_transport.py`
- Identical CoreBluetooth wrapper classes duplicated in both files

### 1.4 Consolidate passthrough wrappers
- Replace 5 `set_button_*_click()` wrappers with direct `set_button_mouse_button(slot, id)` calls using a lookup table
- Replace 8 `set_scroll_led_effect_*()` wrappers with single `set_scroll_led_effect(name)` using a lookup table

### 1.5 Extract shared CLI into `tools/python/razer_cli.py`
- `build_common_parser()` — shared argparse setup (~18 identical arguments)
- `dispatch_common_commands(mouse, args)` — shared command dispatch
- Each script's `main()` adds transport-specific args and dispatch only

**Files modified:** `tools/python/razer_ble.py`, `tools/python/razer_usb.py`
**Files created:** `tools/python/razer_common.py`, `tools/python/cb_vendor_transport.py`, `tools/python/razer_cli.py`

---

## Phase 2: AppStateApplyController — Collapse Repetitive Task Boilerplate (~200 LOC saved)

**File:** `OpenSnek/Sources/OpenSnek/Services/AppStateApplyController.swift` (583 lines)

### 2.1 Create generic debounced apply helper
Replace 12 separate `Task` properties + 12 `scheduleAutoApply*()` methods with:
```swift
private var applyTasks: [String: Task<Void, Never>] = [:]

func scheduleAutoApply(_ key: String, delay: UInt64 = 220_000_000, action: @escaping @Sendable () async -> Void) {
    guard !editorController.isHydrating else { return }
    markLocalEditsPending()
    applyTasks[key]?.cancel()
    applyTasks[key] = Task { ... }
}
```

### 2.2 Inline trivial `apply*()` one-liners
Methods like `applyPollRate`, `applyScrollMode` that just wrap `enqueueApply(DevicePatch(...))` can be inlined or table-driven.

---

## Phase 3: Controller `bind()` Boilerplate (~100 LOC saved)

### 3.1 Create `@WeakBound` property wrapper
Replace ~12 instances of the 6-line weak-reference + preconditionFailure pattern across 4 controllers:
```swift
@propertyWrapper
struct WeakBound<Value: AnyObject> {
    private weak var storage: Value?
    let label: String
    var wrappedValue: Value { guard let storage else { preconditionFailure("...") }; return storage }
    mutating func bind(_ value: Value) { storage = value }
}
```

**Files modified:** `AppStateDeviceController.swift`, `AppStateApplyController.swift`, `AppStateEditorController.swift`, `AppStateRuntimeController.swift`

---

## Phase 4: BridgeClient Decomposition (~200 LOC clarity improvement)

**File:** `OpenSnek/Sources/OpenSnek/Bridge/BridgeClient.swift` (1,448 lines, 32+ state vars)

### 4.1 Extract `PassiveDpiTracker` into `BridgeClient+PassiveDpiTracker.swift`
- Owns 8 passive-DPI dictionaries and all related methods (`handlePassiveDpiEvent`, `handlePassiveDpiHeartbeat`, `clearPassiveDpiObservation`, `seedBluetoothPassiveDpiExpectation`, plus `nonisolated static` pure functions)
- ~300 lines moved into focused, independently testable component

### 4.2 Create generic `BroadcastStream<T>` helper
Replace 3 continuation dictionaries + 6 stream factory/removal methods with 3 `BroadcastStream` instances.

---

## Phase 5: BackendSession File Splits (~100 LOC clarity improvement)

**File:** `OpenSnek/Sources/OpenSnek/Services/BackendSession.swift` (1,592 lines)

### 5.1 Extract `BackgroundServiceTransport.swift`
- Move `BackgroundServiceTransport`, `BackgroundServiceTransportError`, `BackgroundServiceResumeGate`, length-framed read/write helpers (~200 lines of networking infrastructure)

### 5.2 Extract `BackgroundServiceProtocol.swift`
- Move `BackendCodec`, method/envelope types, supporting types (~80 lines of protocol definitions)

Pure file splits — no behavior change.

---

## Phase 6: AppStateDeviceController — Group Per-Device State (~80 LOC saved)

**File:** `OpenSnek/Sources/OpenSnek/Services/AppStateDeviceController.swift` (1,231 lines)

### 6.1 Replace 16 per-device dictionaries with a single `PerDeviceState` struct
```swift
private struct PerDeviceState {
    var cachedState: MouseState?
    var lastUpdated: Date?
    var refreshFailureCount: Int = 0
    var stateRefreshSuppressedUntil: Date?
    var isUnavailable: Bool = false
    var dpiUpdateTransportStatus: DpiUpdateTransportStatus?
    var suppressFastDpiUntil: Date?
    var lastUSBFastDpiAt: Date?
    var lastRealtimeCorrectionAt: Date?
    var lastPassiveHeartbeatAt: Date?
    var lastFullStateRefreshAt: Date?
    var pendingLightingRestore: Bool = false
    var restoringLighting: Bool = false
}
private var deviceStates: [String: PerDeviceState] = [:]
```
Makes cleanup trivial and eliminates risk of forgetting to clear one dictionary.

---

## Phase 7: DeviceDetailView — Optional Organizational Split

**File:** `OpenSnek/Sources/OpenSnek/UI/DeviceDetailView.swift` (1,605 lines)

Low priority. The file is large but well-structured internally. Optional extraction of `DetailColumnsLayout` and subviews into separate files for readability.

---

## Implementation Order & Risk

| Phase | Risk | LOC Saved | Test Impact |
|-------|------|-----------|-------------|
| 1 (Python dedup) | Low — tools are independent | ~1,800 | No Swift tests affected |
| 2 (Apply controller) | Low — mechanical | ~200 | Run apply controller tests |
| 3 (bind() wrapper) | Low — compile-time only | ~100 | All controller tests |
| 4 (BridgeClient) | Medium — actor state moves | ~200 | Run bridge/DPI tests |
| 5 (BackendSession) | Low — file splits only | ~100 | Run session tests |
| 6 (DeviceController) | Medium — data structure change | ~80 | Run device controller tests |
| 7 (DeviceDetailView) | Very low | ~50 | UI only |

Each phase is independently testable and can be landed as a separate commit.

---

## Verification

After each phase:
1. `swift build --package-path OpenSnek` — must compile clean
2. `swift test --package-path OpenSnek` — all existing tests must pass
3. For Python phases: manually run `python3 tools/python/razer_ble.py --help` and `razer_usb.py --help` to verify CLI still works
