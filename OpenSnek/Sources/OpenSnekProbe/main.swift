import Foundation
import OpenSnekCore

enum OpenSnekProbe {
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            throw ProbeError.usage(usageText)
        }

        switch command {
        case "dpi-read":
            let bridge = ProbeBridge()
            let snapshot = try await bridge.readDpi()
            print("active=\(snapshot.active + 1) count=\(snapshot.count) values=\(snapshot.values)")
        case "dpi-set":
            let bridge = ProbeBridge()
            let parsed = try parseSetArgs(Array(args.dropFirst()))
            let snapshot = try await bridge.setDpi(
                active: parsed.active,
                values: parsed.values,
                verifyRetries: parsed.verifyRetries,
                verifyDelayMs: parsed.verifyDelayMs
            )
            print("applied active=\(snapshot.active + 1) values=\(snapshot.values)")
        case "dpi-cycle":
            let bridge = ProbeBridge()
            let parsed = try parseCycleArgs(Array(args.dropFirst()))
            for i in 0..<parsed.loops {
                let values = parsed.sequence[i % parsed.sequence.count]
                let snapshot = try await bridge.setDpi(
                    active: parsed.active,
                    values: values,
                    verifyRetries: parsed.verifyRetries,
                    verifyDelayMs: parsed.verifyDelayMs
                )
                print("loop \(i + 1): active=\(snapshot.active + 1) values=\(snapshot.values)")
                if parsed.sleepMs > 0 {
                    try await Task.sleep(nanoseconds: UInt64(parsed.sleepMs) * 1_000_000)
                }
            }
        case "usb-info":
            let usb = try USBProbeClient()
            print("usb \(usb.describe())")
        case "usb-button-read":
            let parsed = try parseUSBButtonReadArgs(Array(args.dropFirst()))
            let usb = try USBProbeClient()
            print("usb \(usb.describe())")
            let slot = UInt8(max(0, min(255, parsed.slot)))
            for profile in parsed.profiles {
                if let block = try usb.readButtonFunction(profile: profile, slot: slot, hypershift: parsed.hypershift) {
                    print("profile=\(profile) slot=\(parsed.slot) hypershift=\(parsed.hypershift) \(describeUSBFunctionBlock(block))")
                } else {
                    print("profile=\(profile) slot=\(parsed.slot) hypershift=\(parsed.hypershift) read_failed")
                }
            }
        case "usb-button-set":
            let parsed = try parseUSBButtonSetArgs(Array(args.dropFirst()))
            let usb = try USBProbeClient()
            print("usb \(usb.describe())")
            let wrote = try usb.writeButtonBinding(
                profiles: parsed.profiles,
                slot: parsed.slot,
                kind: parsed.kind,
                hidKey: parsed.hidKey,
                turboEnabled: parsed.turboEnabled,
                turboRate: parsed.turboRate
            )
            guard wrote else {
                throw ProbeError.protocolError("USB button write did not return success")
            }
            let slot = UInt8(max(0, min(255, parsed.slot)))
            for profile in parsed.profiles {
                if let block = try usb.readButtonFunction(profile: profile, slot: slot, hypershift: 0x00) {
                    print("readback profile=\(profile) slot=\(parsed.slot) \(describeUSBFunctionBlock(block))")
                }
            }
        case "usb-button-set-raw":
            let parsed = try parseUSBButtonSetRawArgs(Array(args.dropFirst()))
            let usb = try USBProbeClient()
            print("usb \(usb.describe())")
            let slot = UInt8(max(0, min(255, parsed.slot)))
            var wroteAny = false
            for profile in parsed.profiles {
                if try usb.writeButtonFunction(profile: profile, slot: slot, hypershift: 0x00, functionBlock: parsed.functionBlock) {
                    wroteAny = true
                }
            }
            guard wroteAny else {
                throw ProbeError.protocolError("USB raw button write did not return success")
            }
            for profile in parsed.profiles {
                if let block = try usb.readButtonFunction(profile: profile, slot: slot, hypershift: 0x00) {
                    print("readback profile=\(profile) slot=\(parsed.slot) \(describeUSBFunctionBlock(block))")
                }
            }
        default:
            throw ProbeError.usage(usageText)
        }
    }

    private static var usageText: String {
        """
        Usage:
          OpenSnekProbe dpi-read
          OpenSnekProbe dpi-set --values 1600,6400 [--active 1] [--verify-retries 6] [--verify-delay-ms 120]
          OpenSnekProbe dpi-cycle --sequence 800,6400;1600,6400 --loops 10 [--active 1] [--sleep-ms 120]
          OpenSnekProbe usb-info
          OpenSnekProbe usb-button-read --slot 4 [--profile default|direct|both]
          OpenSnekProbe usb-button-set --slot 4 --kind right_click [--profile both] [--hid-key 4] [--turbo on|off] [--turbo-rate 142]
          OpenSnekProbe usb-button-set-raw --slot 4 --hex 01010200000000 [--profile default|direct|both]

        USB button kinds:
          default left_click right_click middle_click scroll_up scroll_down mouse_back mouse_forward keyboard_simple clear_layer
        """
    }

    private static func parseSetArgs(_ args: [String]) throws -> (values: [Int], active: Int, verifyRetries: Int, verifyDelayMs: Int) {
        let flags = parseFlags(args)
        guard let valuesRaw = flags["--values"] else {
            throw ProbeError.usage("Missing --values\n\(usageText)")
        }
        let values = try parseValues(valuesRaw)
        let active = max(0, (Int(flags["--active"] ?? "1") ?? 1) - 1)
        let verifyRetries = Int(flags["--verify-retries"] ?? "6") ?? 6
        let verifyDelayMs = Int(flags["--verify-delay-ms"] ?? "120") ?? 120
        return (values, active, verifyRetries, verifyDelayMs)
    }

    private static func parseCycleArgs(_ args: [String]) throws -> (sequence: [[Int]], loops: Int, active: Int, sleepMs: Int, verifyRetries: Int, verifyDelayMs: Int) {
        let flags = parseFlags(args)
        guard let raw = flags["--sequence"] else {
            throw ProbeError.usage("Missing --sequence\n\(usageText)")
        }
        let sequence = try raw.split(separator: ";").map { try parseValues(String($0)) }
        guard !sequence.isEmpty else { throw ProbeError.usage("Empty --sequence") }
        let loops = max(1, Int(flags["--loops"] ?? "10") ?? 10)
        let active = max(0, (Int(flags["--active"] ?? "1") ?? 1) - 1)
        let sleepMs = max(0, Int(flags["--sleep-ms"] ?? "120") ?? 120)
        let verifyRetries = Int(flags["--verify-retries"] ?? "6") ?? 6
        let verifyDelayMs = Int(flags["--verify-delay-ms"] ?? "120") ?? 120
        return (sequence, loops, active, sleepMs, verifyRetries, verifyDelayMs)
    }

    private static func parseUSBButtonReadArgs(_ args: [String]) throws -> (slot: Int, profiles: [UInt8], hypershift: UInt8) {
        let flags = parseFlags(args)
        guard let slotRaw = flags["--slot"], let slot = Int(slotRaw) else {
            throw ProbeError.usage("Missing --slot\n\(usageText)")
        }
        let profiles = try parseUSBProfiles(flags["--profile"], defaultProfiles: [0x01])
        let hypershift = UInt8(max(0, min(1, Int(flags["--hypershift"] ?? "0") ?? 0)))
        return (slot, profiles, hypershift)
    }

    private static func parseUSBButtonSetArgs(_ args: [String]) throws -> (slot: Int, kind: String, hidKey: Int, turboEnabled: Bool, turboRate: Int, profiles: [UInt8]) {
        let flags = parseFlags(args)
        guard let slotRaw = flags["--slot"], let slot = Int(slotRaw) else {
            throw ProbeError.usage("Missing --slot\n\(usageText)")
        }
        guard let kindRaw = flags["--kind"]?.lowercased() else {
            throw ProbeError.usage("Missing --kind\n\(usageText)")
        }
        let validKinds: Set<String> = [
            "default", "left_click", "right_click", "middle_click",
            "scroll_up", "scroll_down", "mouse_back", "mouse_forward",
            "keyboard_simple", "clear_layer",
        ]
        guard validKinds.contains(kindRaw) else {
            throw ProbeError.usage("Invalid --kind '\(kindRaw)'\n\(usageText)")
        }

        let hidKey = max(0, min(255, Int(flags["--hid-key"] ?? "4") ?? 4))
        let turboEnabled = parseBoolean(flags["--turbo"] ?? "off")
        let turboRate = max(1, min(255, Int(flags["--turbo-rate"] ?? "142") ?? 142))
        let profiles = try parseUSBProfiles(flags["--profile"], defaultProfiles: [0x01, 0x00])
        return (slot, kindRaw, hidKey, turboEnabled, turboRate, profiles)
    }

    private static func parseUSBButtonSetRawArgs(_ args: [String]) throws -> (slot: Int, functionBlock: [UInt8], profiles: [UInt8]) {
        let flags = parseFlags(args)
        guard let slotRaw = flags["--slot"], let slot = Int(slotRaw) else {
            throw ProbeError.usage("Missing --slot\n\(usageText)")
        }
        guard let hexRaw = flags["--hex"] else {
            throw ProbeError.usage("Missing --hex\n\(usageText)")
        }
        let functionBlock = try parseHexBytes(hexRaw)
        guard functionBlock.count == 7 else {
            throw ProbeError.usage("--hex must decode to exactly 7 bytes")
        }
        let profiles = try parseUSBProfiles(flags["--profile"], defaultProfiles: [0x01, 0x00])
        return (slot, functionBlock, profiles)
    }

    private static func parseUSBProfiles(_ raw: String?, defaultProfiles: [UInt8]) throws -> [UInt8] {
        guard let raw else { return defaultProfiles }
        let normalized = raw.lowercased()
        switch normalized {
        case "default", "persistent", "1":
            return [0x01]
        case "direct", "0":
            return [0x00]
        case "both", "all":
            return [0x01, 0x00]
        default:
            throw ProbeError.usage("Invalid --profile '\(raw)' (expected default/direct/both)")
        }
    }

    private static func parseFlags(_ args: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var i = 0
        while i < args.count {
            let key = args[i]
            if key.hasPrefix("--"), i + 1 < args.count {
                result[key] = args[i + 1]
                i += 2
            } else {
                i += 1
            }
        }
        return result
    }

    private static func parseValues(_ raw: String) throws -> [Int] {
        let values = raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let clipped = values.prefix(5).map { max(100, min(30_000, $0)) }
        guard !clipped.isEmpty else {
            throw ProbeError.usage("Invalid DPI values: \(raw)")
        }
        return clipped
    }

    private static func parseBoolean(_ raw: String) -> Bool {
        switch raw.lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    private static func parseHexBytes(_ raw: String) throws -> [UInt8] {
        let normalized = raw
            .replacingOccurrences(of: "0x", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
        guard normalized.count % 2 == 0 else {
            throw ProbeError.usage("Invalid hex byte string: \(raw)")
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(normalized.count / 2)
        var idx = normalized.startIndex
        while idx < normalized.endIndex {
            let next = normalized.index(idx, offsetBy: 2)
            let chunk = normalized[idx..<next]
            guard let value = UInt8(chunk, radix: 16) else {
                throw ProbeError.usage("Invalid hex byte string: \(raw)")
            }
            bytes.append(value)
            idx = next
        }
        return bytes
    }

    private static func describeUSBFunctionBlock(_ block: [UInt8]) -> String {
        ButtonBindingSupport.describeUSBFunctionBlock(block)
    }
}

do {
    try await OpenSnekProbe.run()
    Foundation.exit(EXIT_SUCCESS)
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    Foundation.exit(EXIT_FAILURE)
}
