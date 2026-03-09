import XCTest
@testable import OpenSnekMac

final class HardwareUSBButtonRemapTests: XCTestCase {
    private func requireHardwareRunEnabled() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OPEN_SNEK_HW"] == "1" else {
            throw XCTSkip("Set OPEN_SNEK_HW=1 to run USB hardware remap tests.")
        }
    }

    func testUSBButtonRemapRightClickRoundTrip() async throws {
        try requireHardwareRunEnabled()

        let client = BridgeClient()
        let devices = try await client.listDevices()
        guard let usb = devices.first(where: { $0.transport != "bluetooth" }) else {
            throw XCTSkip("No USB device found for remap test.")
        }

        let slot = 4 // Back button (safe to temporarily remap for validation)
        let originalDefaultProfile = try await client.debugUSBReadButtonBinding(device: usb, slot: slot, profile: 0x01)
        let originalDirectProfile = try await client.debugUSBReadButtonBinding(device: usb, slot: slot, profile: 0x00)

        guard originalDefaultProfile != nil || originalDirectProfile != nil else {
            throw XCTSkip("USB button readback command unavailable on this device/handle.")
        }

        let restoreOriginal: () async -> Void = {
            if let originalDefaultProfile {
                _ = try? await client.debugUSBSetButtonBindingRaw(
                    device: usb,
                    slot: slot,
                    profile: 0x01,
                    functionBlock: originalDefaultProfile
                )
            }
            if let originalDirectProfile {
                _ = try? await client.debugUSBSetButtonBindingRaw(
                    device: usb,
                    slot: slot,
                    profile: 0x00,
                    functionBlock: originalDirectProfile
                )
            }
        }

        do {
            let patch = DevicePatch(
                buttonBinding: ButtonBindingPatch(
                    slot: slot,
                    kind: .rightClick,
                    hidKey: nil
                )
            )
            _ = try await client.apply(device: usb, patch: patch)

            let verified = try await waitForUSBMouseBinding(
                client: client,
                device: usb,
                slot: slot,
                expectedMouseButton: 0x02,
                timeout: 4.0
            )
            XCTAssertTrue(verified, "USB remap readback did not converge to right-click function block")
        } catch {
            await restoreOriginal()
            throw error
        }

        await restoreOriginal()
    }

    private func waitForUSBMouseBinding(
        client: BridgeClient,
        device: MouseDevice,
        slot: Int,
        expectedMouseButton: UInt8,
        timeout: TimeInterval
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let profileDefault = try await client.debugUSBReadButtonBinding(device: device, slot: slot, profile: 0x01)
            let profileDirect = try await client.debugUSBReadButtonBinding(device: device, slot: slot, profile: 0x00)

            if profileDefault.map({ isUSBMouseFunction($0, mouseButton: expectedMouseButton) }) == true ||
                profileDirect.map({ isUSBMouseFunction($0, mouseButton: expectedMouseButton) }) == true {
                return true
            }

            try await Task.sleep(nanoseconds: 140_000_000)
        }

        return false
    }

    private func isUSBMouseFunction(_ block: [UInt8], mouseButton: UInt8) -> Bool {
        guard block.count == 7 else { return false }
        return block[0] == 0x01 && block[1] == 0x01 && block[2] == mouseButton
    }
}
