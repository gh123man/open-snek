import Foundation
import OpenSnekCore

public final class DevicePreferenceStore: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func persistLightingColor(_ color: RGBColor, device: MouseDevice) {
        let key = "lightingColor.\(DevicePersistenceKeys.key(for: device))"
        defaults.set([color.r, color.g, color.b], forKey: key)
    }

    public func loadPersistedLightingColor(device: MouseDevice) -> RGBColor? {
        let key = "lightingColor.\(DevicePersistenceKeys.key(for: device))"
        let legacyKey = "lightingColor.\(DevicePersistenceKeys.legacyKey(for: device))"
        let values = (defaults.array(forKey: key) as? [Int])
            ?? (defaults.array(forKey: legacyKey) as? [Int])
        guard let values, values.count == 3 else { return nil }
        return RGBColor(
            r: max(0, min(255, values[0])),
            g: max(0, min(255, values[1])),
            b: max(0, min(255, values[2]))
        )
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
        persisted[binding.slot] = ButtonBindingDraft(
            kind: binding.kind,
            hidKey: binding.kind == .keyboardSimple ? max(4, min(231, binding.hidKey ?? 4)) : 4,
            turboEnabled: binding.kind.supportsTurbo ? binding.turboEnabled : false,
            turboRate: max(1, min(255, binding.turboRate ?? 0x8E)),
            clutchDPI: binding.kind == .dpiClutch ? max(100, min(30_000, binding.clutchDPI ?? ButtonBindingSupport.defaultV3ProDPIClutchDPI)) : nil
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
            partialResult[slot] = ButtonBindingDraft(
                kind: kind,
                hidKey: max(4, min(231, pair.value.hidKey)),
                turboEnabled: kind.supportsTurbo ? pair.value.turboEnabled : false,
                turboRate: max(1, min(255, pair.value.turboRate)),
                clutchDPI: kind == .dpiClutch ? max(100, min(30_000, pair.value.clutchDPI ?? ButtonBindingSupport.defaultV3ProDPIClutchDPI)) : nil
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
