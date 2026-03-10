# Contributing

`OpenSnek` is intentionally structured so new device support can land without rewriting the app shell. The main rule is simple: if you change protocol behavior, update the protocol docs and tests in the same change.

## Before You Start

Read these first:

- [docs/protocol/PROTOCOL.md](docs/protocol/PROTOCOL.md)
- [docs/protocol/USB_PROTOCOL.md](docs/protocol/USB_PROTOCOL.md)
- [docs/protocol/BLE_PROTOCOL.md](docs/protocol/BLE_PROTOCOL.md)
- [docs/protocol/PARITY.md](docs/protocol/PARITY.md)
- [OpenSnek/README.md](OpenSnek/README.md)

## Repo Areas

- `OpenSnek/Sources/OpenSnekCore`
  - shared device models, device profiles, button layouts, persistence keys
- `OpenSnek/Sources/OpenSnekProtocols`
  - shared BLE vendor framing and USB HID report helpers
- `OpenSnek/Sources/OpenSnekHardware`
  - shared transport/session code
- `OpenSnek/Sources/OpenSnek`
  - app bridge, app services, SwiftUI
- `OpenSnek/Sources/OpenSnekProbe`
  - fast CLI/probe workflows for protocol validation
- `captures/`
  - raw protocol captures and reverse-engineering reference data

## Adding a New Device

The preferred workflow is:

1. Identify the device precisely.
   - Record USB vendor/product IDs.
   - Record Bluetooth vendor/product IDs if BLE is supported.
   - Record marketing name, serial behavior, and any firmware/build strings the device reports.

2. Capture baseline behavior before writing code.
   - Capture untouched/default state.
   - Capture one setting change at a time.
   - Capture both write traffic and the readback/refresh that follows.
   - Keep separate captures for USB and BLE if both transports exist.

3. Add or extend the device profile in `OpenSnek/Sources/OpenSnekCore/DeviceSupport.swift`.
   - Add a `DeviceProfileID`.
   - Register identities for each supported transport.
   - Define button layout and visible/writable slots.
   - Define capability flags honestly. Do not expose UI controls unless the protocol path is proven.

4. Reuse shared transport/protocol layers before adding new ones.
   - USB report framing belongs in `OpenSnekProtocols` or `OpenSnekHardware`.
   - BLE vendor exchange sequencing belongs in `OpenSnekHardware`.
   - Device-specific orchestration belongs in the profile/bridge layer.
   - Do not duplicate transport helpers in `OpenSnekProbe` or app code.

5. Only add new UI when the device truly exposes a new feature family.
   - If the device is just another mouse with the same capabilities, the app should work from profile metadata alone.
   - If you find yourself branching the UI on raw PID/transport strings, stop and move that logic into profile capabilities instead.

6. Add tests with the code change.
   - Add pure parsing/building tests in `OpenSnekTests`.
   - Add profile-resolution tests for new identities/capabilities.
   - Add transport/protocol tests for newly decoded payloads.
   - If hardware is available, run the hardware-gated tests and report the outcome.

7. Update docs in the same change.
   - Update protocol docs if bytes/commands/interpretation changed.
   - Update [CHANGELOG.md](CHANGELOG.md) for user-visible behavior.
   - Update this guide if the onboarding workflow changes.

## How to Interpret Captures

The fastest way to decode a new command path is controlled comparison.

### General rules

- Change exactly one setting per capture segment.
- Keep a default read, a write, and a readback close together.
- Label captures with what changed and what transport was used.
- Prefer official-app captures or captures taken from a known-good control path.

### USB captures

Look for:

- HID feature report request/response pairs
- command class and command ID bytes
- transaction ID behavior
- status byte and checksum behavior
- payload bytes that change when the UI changes one setting

Useful questions:

- Is this a true read/write path or just telemetry?
- Does the response echo the request before returning the real payload?
- Are stage IDs stable tokens or UI indices?
- Does the device require a follow-up read to settle?

When adding USB support, keep framing logic in `OpenSnek/Sources/OpenSnekProtocols/USBHIDProtocol.swift` or shared USB session files, not inline in app/probe code.

### BLE captures

Look for:

- ordered write/notify exchanges on the vendor characteristic
- request IDs or sequence bytes
- key-family bytes that distinguish feature groups
- payload length changes and selector bytes
- the readback notification that proves what the device accepted

Useful questions:

- Is the operation serialized, or are multiple writes being interleaved?
- Is a byte a slot ID, stage ID, effect selector, or a value count?
- Does the readback use the same payload shape as the write?
- Is the effect native on-device, or only software-driven frame streaming?

When adding BLE support, keep operations sequential per connection. Do not introduce parallel writes that race the vendor session.

## Capture-to-Code Workflow

Use this loop:

1. Decode the bytes in docs or notes.
2. Add the pure payload builder/parser first.
3. Write a unit test with the captured bytes.
4. Reuse the shared transport/session layer.
5. Add bridge/profile integration.
6. Validate with `OpenSnekProbe` before relying on the full app UI.
7. Validate readback, not just write ACKs.

## Validation Commands

Core package tests:

```bash
swift test --package-path OpenSnek
```

App/probe builds:

```bash
swift build --package-path OpenSnek
xcodebuild -project OpenSnek/OpenSnek.xcodeproj -scheme OpenSnek -destination 'platform=macOS' build
xcodebuild -project OpenSnek/OpenSnek.xcodeproj -scheme OpenSnekProbe -destination 'platform=macOS' build
```

BLE probe iteration:

```bash
swift run --package-path OpenSnek OpenSnekProbe dpi-read
swift run --package-path OpenSnek OpenSnekProbe dpi-set --values 1600,6400 --active 2
```

Hardware-gated reliability checks:

```bash
OPEN_SNEK_HW=1 swift test --package-path OpenSnek --filter HardwareDpiReliabilityTests
OPEN_SNEK_HW=1 swift test --package-path OpenSnek --filter HardwareUSBButtonRemapTests
```

## Pull Requests

- Keep changes scoped by behavior.
- Include protocol docs and tests with protocol changes.
- Call out capture files used for validation.
- State whether hardware validation was `pass`, `fail`, or `skipped`.
