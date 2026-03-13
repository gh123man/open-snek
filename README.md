<p align="center">
  <img src="OpenSnek/App/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png" alt="open-snek app icon" width="200">
</p>

<h1 align="center">Open Snek</h1>

<p align="center">
  Configure supported Razer mice on macOS without Synapse, Windows, or vendor lock-in.
</p>

![Screenshot](/docs/media/screenshot.png)

Open Snek is an open source native macOS app for configuring supported Razer mice over USB or Bluetooth.

## Highlights

- Lightweight native macOS app bundle with no unnecessary runtime bloat
- Very low idle and background overhead, so it stays out of the way when you are not using it
- Optional menu bar control for quick, on-the-fly DPI adjustments

## Motivation

Razer does not support the Basilisk V3 X HyperSpeed on macOS at all, so this project started by reverse engineering the BLE protocol from Windows traffic between the mouse and Synapse.

The goal is simple: make supported Razer mice configurable on macOS without needing Synapse, Windows, or a second machine just to change settings.

More device support is welcome, whether that comes from new hardware captures or pull requests. For USB protocol reference work, this project also builds on the excellent documentation and reverse-engineering effort from [OpenRazer](https://github.com/openrazer/openrazer).

## Features

- Change DPI, stage count, and active stage
- Adjusts supported lighting settings
- Remaps supported buttons
- Works over USB and Bluetooth where the device protocol allows it
- Avoids the need for Synapse or a separate Windows machine

## Download and Install

1. Download the latest DMG from [GitHub Releases](https://github.com/gh123man/open-snek/releases).
2. Open the DMG.
3. Drag `Open Snek.app` into `Applications`.
4. Launch `Open Snek`.

Official builds use the latest Xcode/macOS SDK. Minimum supported macOS version: macOS 14.

If macOS asks for permissions:

- For USB control, grant `Input Monitoring` to `Open Snek` in `System Settings > Privacy & Security`.
- For Bluetooth control, allow Bluetooth access when prompted.

## Supported Devices

Support is transport-specific. A mouse may be supported over USB, Bluetooth, or both, depending on what has been captured, tested, and validated in the app.

Current validated support:

Status key: `Yes` = supported and validated, `Not yet` = the transport exists on the hardware but Open Snek does not support it yet, `No` = that transport is not available on the device.

| Device | USB | Bluetooth |
|---|---|---|
| Basilisk V3 X HyperSpeed | Yes | Yes |
| Basilisk V3 Pro | Yes | Yes |
| Basilisk V3 35K | Yes | No |

Not every feature is fully supported on every listed transport yet. Some controls and readback paths are still partial while capture, testing, and validation continue.

Unsupported Razer mice still get a best-effort experience when possible. Open Snek will probe for controls that already match known behavior, show a light warning that the device is not fully supported, and avoid exposing UI for features that have not been mapped safely yet.

Support for more devices is welcome. New device support can land either through outside contributors or as more hardware becomes available for capture, testing, and validation.

## Build From Source

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

## Project Docs

- App build, run, probe, and validation details: [OpenSnek/README.md](OpenSnek/README.md)
- Device support and reverse-engineering workflow: [CONTRIBUTING.md](CONTRIBUTING.md)
- DMG release and notarization setup: [docs/release/DMG_RELEASE.md](docs/release/DMG_RELEASE.md)
- Protocol documentation: [docs/protocol/PROTOCOL.md](docs/protocol/PROTOCOL.md)
- Supported Python tooling: [tools/python/README.md](tools/python/README.md)
- BLE capture corpus: [captures/README.md](captures/README.md)

## License

This repository is licensed under the Apache License 2.0. See [LICENSE](LICENSE).
