import XCTest
@testable import OpenSnek

final class HardwareUSBStartupHydrationTests: XCTestCase {
    private struct PersistedBinding: Codable {
        let kindRaw: String
        let hidKey: Int
        let turboEnabled: Bool
        let turboRate: Int
    }

    private func requireHardwareRunEnabled() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OPEN_SNEK_HW"] == "1" else {
            throw XCTSkip("Set OPEN_SNEK_HW=1 to run USB startup hydration tests.")
        }
        guard env["OPEN_SNEK_USB"] == "1" else {
            throw XCTSkip("Set OPEN_SNEK_USB=1 to run USB startup hydration tests.")
        }
    }

    private func cacheKey(for device: MouseDevice) -> String {
        if let serial = device.serial?.trimmingCharacters(in: .whitespacesAndNewlines),
           !serial.isEmpty {
            return "buttonBindings.serial:\(serial.lowercased())"
        }
        return String(
            format: "buttonBindings.vp:%04x:%04x:%@",
            device.vendor_id,
            device.product_id,
            device.transport.rawValue
        )
    }

    func testUSBStartupHydratesButtonBindingsFromDeviceOverCache() async throws {
        try requireHardwareRunEnabled()

        let client = BridgeClient()
        let devices = try await client.listDevices()
        guard let usb = devices.first(where: { $0.transport != .bluetooth }) else {
            throw XCTSkip("No USB device found for startup hydration test.")
        }

        let slot = 4 // Back button
        let defaultProfileBlock = try await client.debugUSBReadButtonBinding(device: usb, slot: slot, profile: 0x01)
        let directProfileBlock = try await client.debugUSBReadButtonBinding(device: usb, slot: slot, profile: 0x00)
        guard defaultProfileBlock != nil || directProfileBlock != nil else {
            throw XCTSkip("USB button readback unavailable on this device/handle.")
        }

        let restoreOriginal: () async -> Void = {
            if let defaultProfileBlock {
                _ = try? await client.debugUSBSetButtonBindingRaw(
                    device: usb,
                    slot: slot,
                    profile: 0x01,
                    functionBlock: defaultProfileBlock
                )
            }
            if let directProfileBlock {
                _ = try? await client.debugUSBSetButtonBindingRaw(
                    device: usb,
                    slot: slot,
                    profile: 0x00,
                    functionBlock: directProfileBlock
                )
            }
        }

        let cacheKey = cacheKey(for: usb)
        let previousCached = UserDefaults.standard.data(forKey: cacheKey)

        do {
            // Set a real device-side mapping.
            let patch = DevicePatch(
                buttonBinding: ButtonBindingPatch(
                    slot: slot,
                    kind: .rightClick,
                    hidKey: nil
                )
            )
            _ = try await client.apply(device: usb, patch: patch)

            // Seed conflicting cache (left click) to ensure startup prefers device readback over cache.
            let conflicting = [
                String(slot): PersistedBinding(
                    kindRaw: ButtonBindingKind.leftClick.rawValue,
                    hidKey: 4,
                    turboEnabled: false,
                    turboRate: 0x8E
                )
            ]
            let conflictingData = try JSONEncoder().encode(conflicting)
            UserDefaults.standard.set(conflictingData, forKey: cacheKey)

            let appState = await MainActor.run { AppState() }
            await appState.refreshDevices()
            await MainActor.run { appState.selectedDeviceID = usb.id }
            await appState.refreshState()

            let hydratedKind = await MainActor.run { appState.buttonBindingKind(for: slot) }
            XCTAssertEqual(hydratedKind, .rightClick, "Startup hydration should prefer USB readback over stale cache")
        } catch {
            await restoreOriginal()
            if let previousCached {
                UserDefaults.standard.set(previousCached, forKey: cacheKey)
            } else {
                UserDefaults.standard.removeObject(forKey: cacheKey)
            }
            throw error
        }

        await restoreOriginal()
        if let previousCached {
            UserDefaults.standard.set(previousCached, forKey: cacheKey)
        } else {
            UserDefaults.standard.removeObject(forKey: cacheKey)
        }
    }
}
