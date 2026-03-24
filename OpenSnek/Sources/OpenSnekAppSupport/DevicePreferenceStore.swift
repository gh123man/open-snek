import Foundation
import OpenSnekCore

public struct OpenSnekButtonProfile: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var bindings: [Int: ButtonBindingDraft]

    public init(id: UUID = UUID(), name: String, bindings: [Int: ButtonBindingDraft]) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bindings = bindings
    }
}

public final class DevicePreferenceStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let openSnekButtonProfilesKey = "openSnekButtonProfiles"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadOpenSnekButtonProfiles() -> [OpenSnekButtonProfile] {
        guard
            let data = defaults.data(forKey: openSnekButtonProfilesKey),
            let decoded = try? JSONDecoder().decode([OpenSnekButtonProfile].self, from: data)
        else {
            return []
        }
        return decoded
    }

    @discardableResult
    public func saveOpenSnekButtonProfile(name: String, bindings: [Int: ButtonBindingDraft]) -> OpenSnekButtonProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = OpenSnekButtonProfile(
            name: trimmed.isEmpty ? "Untitled Profile" : trimmed,
            bindings: bindings
        )
        var profiles = loadOpenSnekButtonProfiles()
        profiles.append(profile)
        persistOpenSnekButtonProfiles(profiles)
        return profile
    }

    @discardableResult
    public func updateOpenSnekButtonProfile(
        id: UUID,
        name: String? = nil,
        bindings: [Int: ButtonBindingDraft]? = nil
    ) -> OpenSnekButtonProfile? {
        var profiles = loadOpenSnekButtonProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            profiles[index].name = trimmed.isEmpty ? profiles[index].name : trimmed
        }
        if let bindings {
            profiles[index].bindings = bindings
        }
        persistOpenSnekButtonProfiles(profiles)
        return profiles[index]
    }

    public func deleteOpenSnekButtonProfile(id: UUID) {
        let filtered = loadOpenSnekButtonProfiles().filter { $0.id != id }
        persistOpenSnekButtonProfiles(filtered)
    }

    public func persistLightingColor(_ color: RGBColor, device: MouseDevice, zoneID: String? = nil) {
        let key = lightingColorKey(device: device, zoneID: zoneID)
        defaults.set([color.r, color.g, color.b], forKey: key)
    }

    public func loadPersistedLightingColor(device: MouseDevice, zoneID: String? = nil) -> RGBColor? {
        let values = lightingColorKeys(device: device, zoneID: zoneID)
            .lazy
            .compactMap { self.defaults.array(forKey: $0) as? [Int] }
            .first
        guard let values, values.count == 3 else { return nil }
        return RGBColor(
            r: max(0, min(255, values[0])),
            g: max(0, min(255, values[1])),
            b: max(0, min(255, values[2]))
        )
    }

    public func persistLightingZoneID(_ zoneID: String, device: MouseDevice) {
        let key = "lightingZone.\(DevicePersistenceKeys.key(for: device))"
        defaults.set(zoneID, forKey: key)
    }

    public func loadPersistedLightingZoneID(device: MouseDevice) -> String? {
        let key = "lightingZone.\(DevicePersistenceKeys.key(for: device))"
        let legacyKey = "lightingZone.\(DevicePersistenceKeys.legacyKey(for: device))"
        let zoneID = defaults.string(forKey: key) ?? defaults.string(forKey: legacyKey)
        guard let trimmed = zoneID?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    public func persistLightingEffect(_ effect: LightingEffectPatch, device: MouseDevice) {
        let key = "lightingEffect.\(DevicePersistenceKeys.key(for: device))"
        let persisted = PersistedLightingEffect(
            kindRaw: effect.kind.rawValue,
            waveDirectionRaw: effect.waveDirection.rawValue,
            reactiveSpeed: max(1, min(4, effect.reactiveSpeed)),
            secondaryRGB: [effect.secondary.r, effect.secondary.g, effect.secondary.b]
        )
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        defaults.set(data, forKey: key)
    }

    public func loadPersistedLightingEffect(device: MouseDevice) -> (
        kind: LightingEffectKind,
        waveDirection: LightingWaveDirection,
        reactiveSpeed: Int,
        secondaryColor: RGBColor
    )? {
        let key = "lightingEffect.\(DevicePersistenceKeys.key(for: device))"
        let legacyKey = "lightingEffect.\(DevicePersistenceKeys.legacyKey(for: device))"
        let data = defaults.data(forKey: key) ?? defaults.data(forKey: legacyKey)
        guard
            let data,
            let decoded = try? JSONDecoder().decode(PersistedLightingEffect.self, from: data),
            let kind = LightingEffectKind(rawValue: decoded.kindRaw)
        else {
            return nil
        }

        let direction = LightingWaveDirection(rawValue: decoded.waveDirectionRaw) ?? .left
        let speed = max(1, min(4, decoded.reactiveSpeed))
        let fallback = [0, 170, 255]
        let values = (0..<3).map { idx -> Int in
            if idx < decoded.secondaryRGB.count {
                return decoded.secondaryRGB[idx]
            }
            return fallback[idx]
        }
        let color = RGBColor(
            r: max(0, min(255, values[0])),
            g: max(0, min(255, values[1])),
            b: max(0, min(255, values[2]))
        )
        return (kind: kind, waveDirection: direction, reactiveSpeed: speed, secondaryColor: color)
    }

    public func persistButtonBinding(_ binding: ButtonBindingPatch, device: MouseDevice, profile: Int? = nil) {
        var persisted = loadPersistedButtonBindings(device: device, profile: profile)
        persisted[binding.slot] = ButtonBindingSupport.normalizedDefaultRepresentation(
            for: binding.slot,
            draft: ButtonBindingDraft(
                kind: binding.kind,
                hidKey: binding.kind == .keyboardSimple ? max(4, min(231, binding.hidKey ?? 4)) : 4,
                turboEnabled: binding.kind.supportsTurbo ? binding.turboEnabled : false,
                turboRate: max(1, min(255, binding.turboRate ?? 0x8E)),
                clutchDPI: binding.kind == .dpiClutch ? DeviceProfiles.clampDPI(binding.clutchDPI ?? ButtonBindingSupport.defaultBasiliskDPIClutchDPI, device: device) : nil
            ),
            profileID: device.profile_id
        )
        savePersistedButtonBindings(device: device, bindings: persisted, profile: profile)
    }

    public func savePersistedButtonBindings(device: MouseDevice, bindings: [Int: ButtonBindingDraft], profile: Int? = nil) {
        let key = buttonBindingsKey(device: device, profile: profile)
        let encoded = bindings.reduce(into: [String: PersistedButtonBinding]()) { partialResult, pair in
            partialResult[String(pair.key)] = PersistedButtonBinding(
                kindRaw: pair.value.kind.rawValue,
                hidKey: pair.value.hidKey,
                turboEnabled: pair.value.turboEnabled,
                turboRate: pair.value.turboRate,
                clutchDPI: pair.value.clutchDPI
            )
        }
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        defaults.set(data, forKey: key)
        defaults.synchronize()
    }

    public func loadPersistedButtonBindings(device: MouseDevice, profile: Int? = nil) -> [Int: ButtonBindingDraft] {
        let key = buttonBindingsKey(device: device, profile: profile)
        let legacyKey = buttonBindingsLegacyKey(device: device, profile: profile)
        let data = defaults.data(forKey: key) ?? legacyKey.flatMap { defaults.data(forKey: $0) }
        guard
            let data,
            let decoded = try? JSONDecoder().decode([String: PersistedButtonBinding].self, from: data)
        else {
            return [:]
        }

        let allowedSlots = Set((device.button_layout?.visibleSlots ?? ButtonSlotDescriptor.defaults).map(\.slot))
        return decoded.reduce(into: [Int: ButtonBindingDraft]()) { partialResult, pair in
            guard
                let slot = Int(pair.key),
                let kind = ButtonBindingKind(rawValue: pair.value.kindRaw),
                allowedSlots.contains(slot)
            else {
                return
            }
            partialResult[slot] = ButtonBindingSupport.normalizedDefaultRepresentation(
                for: slot,
                draft: ButtonBindingDraft(
                    kind: kind,
                    hidKey: max(4, min(231, pair.value.hidKey)),
                    turboEnabled: kind.supportsTurbo ? pair.value.turboEnabled : false,
                    turboRate: max(1, min(255, pair.value.turboRate)),
                    clutchDPI: kind == .dpiClutch ? DeviceProfiles.clampDPI(pair.value.clutchDPI ?? ButtonBindingSupport.defaultBasiliskDPIClutchDPI, device: device) : nil
                ),
                profileID: device.profile_id
            )
        }
    }

    private func buttonBindingsKey(device: MouseDevice, profile: Int?) -> String {
        let base = "buttonBindings.\(DevicePersistenceKeys.key(for: device))"
        guard let profile else { return base }
        return "\(base).profile\(max(1, profile))"
    }

    private func buttonBindingsLegacyKey(device: MouseDevice, profile: Int?) -> String? {
        let legacyBase = "buttonBindings.\(DevicePersistenceKeys.legacyKey(for: device))"
        let currentBase = "buttonBindings.\(DevicePersistenceKeys.key(for: device))"
        if let profile, profile > 1 {
            return nil
        }
        return defaults.data(forKey: currentBase) == nil ? legacyBase : currentBase
    }

    private func lightingColorKeys(device: MouseDevice, zoneID: String?) -> [String] {
        let normalizedZoneID = normalizedLightingZoneID(zoneID)
        var keys: [String] = []
        if let normalizedZoneID {
            keys.append(lightingColorKey(device: device, zoneID: normalizedZoneID))
            keys.append(lightingColorKey(device: device, zoneID: normalizedZoneID, useLegacyKey: true))
        }
        keys.append(lightingColorKey(device: device, zoneID: nil))
        keys.append(lightingColorKey(device: device, zoneID: nil, useLegacyKey: true))
        return keys
    }

    private func lightingColorKey(device: MouseDevice, zoneID: String?, useLegacyKey: Bool = false) -> String {
        let deviceKey = useLegacyKey ? DevicePersistenceKeys.legacyKey(for: device) : DevicePersistenceKeys.key(for: device)
        guard let normalizedZoneID = normalizedLightingZoneID(zoneID) else {
            return "lightingColor.\(deviceKey)"
        }
        return "lightingColor.\(deviceKey).zone.\(normalizedZoneID)"
    }

    private func normalizedLightingZoneID(_ zoneID: String?) -> String? {
        guard let zoneID else { return nil }
        let trimmed = zoneID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed != "all" else { return nil }
        return trimmed
    }

    private func persistOpenSnekButtonProfiles(_ profiles: [OpenSnekButtonProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: openSnekButtonProfilesKey)
    }
}

private struct PersistedButtonBinding: Codable {
    let kindRaw: String
    let hidKey: Int
    let turboEnabled: Bool
    let turboRate: Int
    let clutchDPI: Int?
}

private struct PersistedLightingEffect: Codable {
    let kindRaw: String
    let waveDirectionRaw: Int
    let reactiveSpeed: Int
    let secondaryRGB: [Int]
}
