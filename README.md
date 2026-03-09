# open-snek

`OpenSnek` is a native macOS app for configuring supported Razer mice without Synapse.

## Quick Start

From the repo root:

```bash
./run.sh
```

That rebuilds and launches the app bundle through the canonical macOS path in `OpenSnek/scripts/run_macos_app.sh`.

If you want to reuse the current app bundle without rebuilding:

```bash
./run.sh --no-build
```

## Build

```bash
swift build --package-path OpenSnek
```

## Test

```bash
swift test --package-path OpenSnek
```

## Xcode

```bash
./OpenSnek/scripts/generate_xcodeproj.sh --open
```

## Supported Device

Validated on:
- Razer Basilisk V3 X HyperSpeed
  - USB PID `0x00B9`
  - Bluetooth PID `0x00BA` (VID `0x068E`)

## More

- App build, run, probe, and validation details: [OpenSnek/README.md](OpenSnek/README.md)
- Protocol documentation: [docs/protocol/PROTOCOL.md](docs/protocol/PROTOCOL.md)
- Supported Python tooling: [tools/python/README.md](tools/python/README.md)
- BLE capture corpus: [captures/README.md](captures/README.md)
