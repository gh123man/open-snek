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
            let usb = try USBProbeClient(productID: try parseOptionalUSBPID(Array(args.dropFirst())))
            print("usb \(usb.describe())")
        case "usb-lighting-info":
            let parsed = try parseUSBLightingZoneArgs(Array(args.dropFirst()))
            let usb = try USBProbeClient(productID: parsed.productID)
            print("usb \(usb.describe())")
            print("supported-effects=\(usb.supportedLightingEffects().map(\.rawValue).joined(separator: ","))")
            let zones = usb.availableLightingZones()
            if zones.isEmpty {
                print("zones: all -> [0x01]")
            } else {
                for zone in zones {
                    let ledIDs = zone.ledIDs.map { String(format: "0x%02x", $0) }.joined(separator: ",")
                    print("zone id=\(zone.id) label=\"\(zone.label)\" ledIDs=[\(ledIDs)]")
                }
            }
            guard let reads = try usb.readLightingBrightness(zoneID: parsed.zoneID) else {
                throw invalidUSBLightingZone(zoneID: parsed.zoneID, usb: usb)
            }
            for read in reads {
                print(describeUSBLightingReadResult(read))
            }
        case "usb-lighting-read":
            let parsed = try parseUSBLightingZoneArgs(Array(args.dropFirst()))
            let usb = try USBProbeClient(productID: parsed.productID)
            print("usb \(usb.describe())")
            guard let reads = try usb.readLightingBrightness(zoneID: parsed.zoneID) else {
                throw invalidUSBLightingZone(zoneID: parsed.zoneID, usb: usb)
            }
            for read in reads {
                print(describeUSBLightingReadResult(read))
            }
        case "usb-lighting-brightness":
            let parsed = try parseUSBLightingBrightnessArgs(Array(args.dropFirst()))
            let usb = try USBProbeClient(productID: parsed.productID)
            print("usb \(usb.describe())")
            guard let writes = try usb.writeLightingBrightness(value: parsed.value, zoneID: parsed.zoneID) else {
                throw invalidUSBLightingZone(zoneID: parsed.zoneID, usb: usb)
            }
            for write in writes {
                print(describeUSBLightingWriteResult(write, operation: "brightness"))
            }
            guard let reads = try usb.readLightingBrightness(zoneID: parsed.zoneID) else {
                throw invalidUSBLightingZone(zoneID: parsed.zoneID, usb: usb)
            }
            for read in reads {
                print(describeUSBLightingReadResult(read))
            }
            guard writes.allSatisfy(\.succeeded) else {
                throw ProbeError.protocolError("One or more USB lighting brightness writes failed")
            }
        case "usb-lighting-effect":
            let parsed = try parseUSBLightingEffectArgs(Array(args.dropFirst()))
            let usb = try USBProbeClient(productID: parsed.productID)
            print("usb \(usb.describe())")
            let supportedEffects = usb.supportedLightingEffects()
            guard supportedEffects.contains(parsed.effect.kind) else {
                throw ProbeError.usage(
                    "Unsupported --kind '\(parsed.effect.kind.rawValue)' for this device (supported: \(supportedEffects.map(\.rawValue).joined(separator: ",")))"
                )
            }
            guard let writes = try usb.writeLightingEffect(effect: parsed.effect, zoneID: parsed.zoneID) else {
                throw invalidUSBLightingZone(zoneID: parsed.zoneID, usb: usb)
            }
            for write in writes {
                print(describeUSBLightingWriteResult(write, operation: parsed.effect.kind.rawValue))
            }
            guard writes.allSatisfy(\.succeeded) else {
                throw ProbeError.protocolError("One or more USB lighting effect writes failed")
            }
        case "usb-input-listen":
            let parsed = try parseUSBInputListenArgs(Array(args.dropFirst()))
            let probe = try USBInputReportProbe(productID: parsed.productID)
            print("usb-input-listen candidates=\(probe.candidateCount) duration=\(String(format: "%.1f", parsed.durationSeconds))s")
            for line in probe.describeCandidates() {
                print(line)
            }
            let reportCount = try await probe.capture(
                duration: parsed.durationSeconds,
                maxReports: parsed.maxReports
            ) { event in
                let hex = event.report.map { String(format: "%02x", $0) }.joined(separator: " ")
                let passiveNote: String
                if let passive = event.passiveDPI {
                    passiveNote = " passiveDpi=\(passive.dpiX)x\(passive.dpiY)"
                } else {
                    passiveNote = ""
                }
                print(
                    String(
                        format: "[+%.3fs] candidate[%d] usage=%@ input=%d feature=%d report[%d]=%@%@",
                        event.elapsedSeconds,
                        event.candidateIndex,
                        event.usageLabel,
                        event.maxInputReportSize,
                        event.maxFeatureReportSize,
                        event.report.count,
                        hex,
                        passiveNote
                    )
                )
            }
            print("usb-input-listen complete reports=\(reportCount)")
        case "usb-input-values":
            let parsed = try parseUSBInputListenArgs(Array(args.dropFirst()))
            let probe = try USBInputValueProbe(productID: parsed.productID)
            print("usb-input-values candidates=\(probe.candidateCount) duration=\(String(format: "%.1f", parsed.durationSeconds))s")
            for line in probe.describeCandidates() {
                print(line)
            }
            let eventCount = try await probe.capture(
                duration: parsed.durationSeconds,
                maxEvents: parsed.maxReports
            ) { event in
                print(
                    String(
                        format: "[+%.3fs] candidate[%d] deviceUsage=%@ element=%@ reportID=%d value=%d",
                        event.elapsedSeconds,
                        event.candidateIndex,
                        event.deviceUsageLabel,
                        event.elementUsageLabel,
                        event.reportID,
                        event.integerValue
                    )
                )
            }
            print("usb-input-values complete events=\(eventCount)")
        case "usb-button-read":
            let parsed = try parseUSBButtonReadArgs(Array(args.dropFirst()))
            let usb = try USBProbeClient(productID: parsed.productID)
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
            let usb = try USBProbeClient(productID: parsed.productID)
            print("usb \(usb.describe())")
            let wrote = try usb.writeButtonBinding(
                profiles: parsed.profiles,
                slot: parsed.slot,
                kind: parsed.kind,
                hidKey: parsed.hidKey,
                turboEnabled: parsed.turboEnabled,
                turboRate: parsed.turboRate,
                clutchDPI: parsed.clutchDPI
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
            let usb = try USBProbeClient(productID: parsed.productID)
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
        case "usb-raw":
            let parsed = try parseUSBRawArgs(Array(args.dropFirst()))
            let usb = try USBProbeClient(productID: parsed.productID)
            print("usb \(usb.describe())")
            let response = try usb.rawCommand(
                classID: parsed.classID,
                cmdID: parsed.cmdID,
                size: parsed.size,
                args: parsed.args,
                allowTxnRescan: !parsed.noTxnRescan,
                responseAttempts: parsed.responseAttempts,
                responseDelayUs: parsed.responseDelayUs
            )
            if let response {
                let hex = response.map { String(format: "%02x", $0) }.joined(separator: " ")
                print("response[\(response.count)]: \(hex)")
            } else {
                print("response: nil")
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
          OpenSnekProbe usb-info [--pid 0x00ab]
          OpenSnekProbe usb-lighting-info [--zone all|scroll_wheel|logo|underglow] [--pid 0x00ab]
          OpenSnekProbe usb-lighting-read [--zone all|scroll_wheel|logo|underglow] [--pid 0x00ab]
          OpenSnekProbe usb-lighting-brightness --value 128 [--zone all|scroll_wheel|logo|underglow] [--pid 0x00ab]
          OpenSnekProbe usb-lighting-effect --kind static [--color 00ff00] [--secondary ff00ff] [--direction left|right] [--speed 2] [--zone all|scroll_wheel|logo|underglow] [--pid 0x00ab]
          OpenSnekProbe usb-input-listen [--pid 0x00ab] [--duration 15] [--max-reports 0]
          OpenSnekProbe usb-input-values [--pid 0x00ab] [--duration 15] [--max-reports 0]
          OpenSnekProbe usb-button-read --slot 4 [--profile default|direct|both] [--pid 0x00ab]
          OpenSnekProbe usb-button-set --slot 4 --kind right_click [--profile both] [--hid-key 4] [--turbo on|off] [--turbo-rate 142] [--clutch-dpi 400] [--pid 0x00ab]
          OpenSnekProbe usb-button-set-raw --slot 4 --hex 01010200000000 [--profile default|direct|both] [--pid 0x00ab]
          OpenSnekProbe usb-raw --class 0x02 --cmd 0x8C --size 0x0A [--args 01,04,00,00,00,00,00,00,00,00] [--pid 0x00ab]

        USB button kinds:
          default dpi_cycle dpi_clutch left_click right_click middle_click scroll_up scroll_down mouse_back mouse_forward keyboard_simple clear_layer

        USB lighting kinds:
          off static spectrum wave reactive pulse_random pulse_single pulse_dual
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

    private static func parseUSBButtonReadArgs(_ args: [String]) throws -> (slot: Int, profiles: [UInt8], hypershift: UInt8, productID: Int?) {
        let flags = parseFlags(args)
        guard let slotRaw = flags["--slot"], let slot = Int(slotRaw) else {
            throw ProbeError.usage("Missing --slot\n\(usageText)")
        }
        let profiles = try parseUSBProfiles(flags["--profile"], defaultProfiles: [0x01])
        let hypershift = UInt8(max(0, min(1, Int(flags["--hypershift"] ?? "0") ?? 0)))
        return (slot, profiles, hypershift, try parseOptionalUSBPID(args))
    }

    private static func parseUSBButtonSetArgs(_ args: [String]) throws -> (slot: Int, kind: String, hidKey: Int, turboEnabled: Bool, turboRate: Int, clutchDPI: Int?, profiles: [UInt8], productID: Int?) {
        let flags = parseFlags(args)
        guard let slotRaw = flags["--slot"], let slot = Int(slotRaw) else {
            throw ProbeError.usage("Missing --slot\n\(usageText)")
        }
        guard let kindRaw = flags["--kind"]?.lowercased() else {
            throw ProbeError.usage("Missing --kind\n\(usageText)")
        }
        let validKinds: Set<String> = [
            "default", "dpi_cycle", "dpi_clutch", "left_click", "right_click", "middle_click",
            "scroll_up", "scroll_down", "mouse_back", "mouse_forward",
            "keyboard_simple", "clear_layer",
        ]
        guard validKinds.contains(kindRaw) else {
            throw ProbeError.usage("Invalid --kind '\(kindRaw)'\n\(usageText)")
        }

        let hidKey = max(0, min(255, Int(flags["--hid-key"] ?? "4") ?? 4))
        let turboEnabled = parseBoolean(flags["--turbo"] ?? "off")
        let turboRate = max(1, min(255, Int(flags["--turbo-rate"] ?? "142") ?? 142))
        let clutchDPI = Int(flags["--clutch-dpi"] ?? "").map { max(100, min(30_000, $0)) }
        let profiles = try parseUSBProfiles(flags["--profile"], defaultProfiles: [0x01, 0x00])
        return (slot, kindRaw, hidKey, turboEnabled, turboRate, clutchDPI, profiles, try parseOptionalUSBPID(args))
    }

    private static func parseUSBButtonSetRawArgs(_ args: [String]) throws -> (slot: Int, functionBlock: [UInt8], profiles: [UInt8], productID: Int?) {
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
        return (slot, functionBlock, profiles, try parseOptionalUSBPID(args))
    }

    private static func parseUSBInputListenArgs(_ args: [String]) throws -> (durationSeconds: TimeInterval, maxReports: Int?, productID: Int?) {
        let flags = parseFlags(args)
        let durationSeconds = max(0.5, Double(flags["--duration"] ?? "15") ?? 15.0)
        let maxReportsRaw = max(0, Int(flags["--max-reports"] ?? "0") ?? 0)
        let maxReports = maxReportsRaw > 0 ? maxReportsRaw : nil
        return (durationSeconds, maxReports, try parseOptionalUSBPID(args))
    }

    private static func parseUSBLightingZoneArgs(_ args: [String]) throws -> (zoneID: String?, productID: Int?) {
        let flags = parseFlags(args)
        return (parseLightingZoneID(flags["--zone"]), try parseOptionalUSBPID(args))
    }

    private static func parseUSBLightingBrightnessArgs(_ args: [String]) throws -> (value: Int, zoneID: String?, productID: Int?) {
        let flags = parseFlags(args)
        guard let valueRaw = flags["--value"], let value = Int(valueRaw) else {
            throw ProbeError.usage("Missing --value\n\(usageText)")
        }
        return (max(0, min(255, value)), parseLightingZoneID(flags["--zone"]), try parseOptionalUSBPID(args))
    }

    private static func parseUSBLightingEffectArgs(_ args: [String]) throws -> (effect: LightingEffectPatch, zoneID: String?, productID: Int?) {
        let flags = parseFlags(args)
        guard let kindRaw = flags["--kind"], let kind = parseLightingEffectKind(kindRaw) else {
            throw ProbeError.usage("Missing or invalid --kind\n\(usageText)")
        }

        let primary = try parseRGBPatch(flags["--color"]) ?? RGBPatch(r: 0, g: 255, b: 0)
        let secondary = try parseRGBPatch(flags["--secondary"]) ?? RGBPatch(r: 0, g: 170, b: 255)
        let direction = try parseLightingDirection(flags["--direction"] ?? "left")
        let speed = max(1, min(4, Int(flags["--speed"] ?? "2") ?? 2))
        let effect = LightingEffectPatch(
            kind: kind,
            primary: primary,
            secondary: secondary,
            waveDirection: direction,
            reactiveSpeed: speed
        )
        return (effect, parseLightingZoneID(flags["--zone"]), try parseOptionalUSBPID(args))
    }

    private static func parseUSBRawArgs(_ args: [String]) throws -> (classID: UInt8, cmdID: UInt8, size: UInt8, args: [UInt8], noTxnRescan: Bool, responseAttempts: Int, responseDelayUs: useconds_t, productID: Int?) {
        let flags = parseFlags(args)
        guard let classRaw = flags["--class"], let classID = parseUInt8(classRaw) else {
            throw ProbeError.usage("Missing or invalid --class\n\(usageText)")
        }
        guard let cmdRaw = flags["--cmd"], let cmdID = parseUInt8(cmdRaw) else {
            throw ProbeError.usage("Missing or invalid --cmd\n\(usageText)")
        }
        let parsedArgs = try parseCSVBytes(flags["--args"] ?? "")
        let size = parseUInt8(flags["--size"] ?? "") ?? UInt8(parsedArgs.count)
        let noTxnRescan = parseBoolean(flags["--no-txn-rescan"] ?? "off")
        let responseAttempts = max(1, Int(flags["--response-attempts"] ?? "12") ?? 12)
        let responseDelayUs = useconds_t(max(1_000, Int(flags["--response-delay-us"] ?? "40000") ?? 40_000))
        return (classID, cmdID, size, parsedArgs, noTxnRescan, responseAttempts, responseDelayUs, try parseOptionalUSBPID(args))
    }

    private static func parseOptionalUSBPID(_ args: [String]) throws -> Int? {
        let flags = parseFlags(args)
        guard let raw = flags["--pid"] else { return nil }
        guard let value = parseUInt16(raw) else {
            throw ProbeError.usage("Invalid --pid '\(raw)'")
        }
        return Int(value)
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

    private static func parseLightingZoneID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty || normalized == "all" ? nil : normalized
    }

    private static func parseLightingEffectKind(_ raw: String) -> LightingEffectKind? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "off":
            return .off
        case "static", "static_color", "staticcolor":
            return .staticColor
        case "spectrum":
            return .spectrum
        case "wave":
            return .wave
        case "reactive":
            return .reactive
        case "pulse_random", "pulserandom", "random":
            return .pulseRandom
        case "pulse_single", "pulsesingle", "single":
            return .pulseSingle
        case "pulse_dual", "pulsedual", "dual":
            return .pulseDual
        default:
            return nil
        }
    }

    private static func parseLightingDirection(_ raw: String) throws -> LightingWaveDirection {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "left", "1":
            return .left
        case "right", "2":
            return .right
        default:
            throw ProbeError.usage("Invalid --direction '\(raw)' (expected left/right)")
        }
    }

    private static func parseRGBPatch(_ raw: String?) throws -> RGBPatch? {
        guard let raw else { return nil }
        let bytes = try parseHexBytes(raw)
        guard bytes.count == 3 else {
            throw ProbeError.usage("Invalid RGB hex '\(raw)' (expected 6 hex chars)")
        }
        return RGBPatch(r: Int(bytes[0]), g: Int(bytes[1]), b: Int(bytes[2]))
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

    private static func parseCSVBytes(_ raw: String) throws -> [UInt8] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try trimmed
            .split(separator: ",")
            .map { chunk in
                let token = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let value = parseUInt8(token) else {
                    throw ProbeError.usage("Invalid byte value '\(token)'")
                }
                return value
            }
    }

    private static func parseUInt8(_ raw: String) -> UInt8? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("0x") {
            return UInt8(trimmed.dropFirst(2), radix: 16)
        }
        return UInt8(trimmed, radix: 10)
    }

    private static func parseUInt16(_ raw: String) -> UInt16? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("0x") {
            return UInt16(trimmed.dropFirst(2), radix: 16)
        }
        return UInt16(trimmed, radix: 10)
    }

    private static func describeUSBFunctionBlock(_ block: [UInt8]) -> String {
        ButtonBindingSupport.describeUSBFunctionBlock(block)
    }

    private static func invalidUSBLightingZone(zoneID: String?, usb: USBProbeClient) -> ProbeError {
        let requested = zoneID ?? "all"
        return .usage("Invalid --zone '\(requested)' (available: \(usb.lightingZoneChoices().joined(separator: ",")))")
    }

    private static func describeUSBLightingReadResult(_ result: USBLightingReadResult) -> String {
        let brightness = result.brightness.map(String.init) ?? "read_failed"
        return "brightness zone=\(result.target.zoneID) label=\"\(result.target.zoneLabel)\" led=0x\(String(format: "%02x", result.target.ledID)) value=\(brightness)"
    }

    private static func describeUSBLightingWriteResult(_ result: USBLightingWriteResult, operation: String) -> String {
        let hex = result.args.map { String(format: "%02x", $0) }.joined(separator: " ")
        let status = result.succeeded ? "ok" : "error"
        return "write-\(operation) zone=\(result.target.zoneID) label=\"\(result.target.zoneLabel)\" led=0x\(String(format: "%02x", result.target.ledID)) args=\(hex) status=\(status)"
    }
}

do {
    try await OpenSnekProbe.run()
    Foundation.exit(EXIT_SUCCESS)
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    Foundation.exit(EXIT_FAILURE)
}
