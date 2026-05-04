import Foundation

public enum DeveloperRuntimeOptions {
    public static let pollingEnabledDefaultsKey = "developer.runtimePollingEnabled"
    public static let passiveHIDUpdatesEnabledDefaultsKey = "developer.passiveHIDUpdatesEnabled"
    public static let rememberWindowSizeEnabledDefaultsKey = "developer.rememberWindowSizeEnabled"
    public static let settingStorageEnabledDefaultsKey = "developer.settingStorageEnabled"

    public static func pollingEnabled(defaults: UserDefaults = .standard) -> Bool {
        storedBool(
            forKey: pollingEnabledDefaultsKey,
            defaults: defaults,
            fallback: true
        )
    }

    public static func passiveHIDUpdatesEnabled(defaults: UserDefaults = .standard) -> Bool {
        storedBool(
            forKey: passiveHIDUpdatesEnabledDefaultsKey,
            defaults: defaults,
            fallback: true
        )
    }

    public static func rememberWindowSizeEnabled(defaults: UserDefaults = .standard) -> Bool {
        storedBool(
            forKey: rememberWindowSizeEnabledDefaultsKey,
            defaults: defaults,
            fallback: true
        )
    }

    public static func settingStorageEnabled(defaults: UserDefaults = .standard) -> Bool {
        storedBool(
            forKey: settingStorageEnabledDefaultsKey,
            defaults: defaults,
            fallback: true
        )
    }

    private static func storedBool(
        forKey key: String,
        defaults: UserDefaults,
        fallback: Bool
    ) -> Bool {
#if DEBUG
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
#else
        return fallback
#endif
    }
}
