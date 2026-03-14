import Foundation

struct ReleaseVersion: Comparable, Equatable {
    enum PreReleaseIdentifier: Comparable, Equatable {
        case numeric(Int)
        case textual(String)

        static func < (lhs: PreReleaseIdentifier, rhs: PreReleaseIdentifier) -> Bool {
            switch (lhs, rhs) {
            case let (.numeric(left), .numeric(right)):
                return left < right
            case let (.textual(left), .textual(right)):
                return left.localizedStandardCompare(right) == .orderedAscending
            case (.numeric, .textual):
                return true
            case (.textual, .numeric):
                return false
            }
        }
    }

    let components: [Int]
    let preRelease: [PreReleaseIdentifier]

    static func parse(_ rawValue: String) -> ReleaseVersion? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withoutPrefix = trimmed.replacingOccurrences(
            of: #"^[vV]"#,
            with: "",
            options: .regularExpression
        )
        let coreAndSuffix = withoutPrefix.split(separator: "-", maxSplits: 1).map(String.init)
        guard let core = coreAndSuffix.first, !core.isEmpty else { return nil }
        let parts = core.split(separator: ".")
        guard !parts.isEmpty else { return nil }

        var parsed: [Int] = []
        parsed.reserveCapacity(parts.count)
        for part in parts {
            guard let value = Int(part) else { return nil }
            parsed.append(value)
        }

        let preRelease: [PreReleaseIdentifier]
        if coreAndSuffix.count > 1 {
            let suffix = coreAndSuffix[1]
            let identifiers = suffix.split(separator: ".")
            guard !identifiers.isEmpty else { return nil }
            preRelease = identifiers.map { identifier in
                if let numeric = Int(identifier) {
                    return .numeric(numeric)
                }
                return .textual(String(identifier))
            }
        } else {
            preRelease = []
        }

        return ReleaseVersion(components: parsed, preRelease: preRelease)
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }

        if lhs.preRelease.isEmpty && rhs.preRelease.isEmpty {
            return false
        }
        if lhs.preRelease.isEmpty {
            return false
        }
        if rhs.preRelease.isEmpty {
            return true
        }

        let preReleaseCount = max(lhs.preRelease.count, rhs.preRelease.count)
        for index in 0..<preReleaseCount {
            if index >= lhs.preRelease.count { return true }
            if index >= rhs.preRelease.count { return false }
            let left = lhs.preRelease[index]
            let right = rhs.preRelease[index]
            if left != right {
                return left < right
            }
        }

        return false
    }

    static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

struct ReleaseAvailability: Equatable {
    let latestVersion: String
    let releaseURL: URL
}

struct ReleaseUpdateChecker: Sendable {
    private struct LatestReleaseResponse: Decodable {
        let tag_name: String
        let html_url: String?
    }

    static let releasesPageURL = URL(string: "https://github.com/gh123man/OpenSnek/releases")!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func checkForUpdate(currentVersion: String) async throws -> ReleaseAvailability? {
        guard let current = ReleaseVersion.parse(currentVersion) else { return nil }

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/gh123man/OpenSnek/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("OpenSnek/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            return nil
        }

        let release = try JSONDecoder().decode(LatestReleaseResponse.self, from: data)
        guard let latest = ReleaseVersion.parse(release.tag_name), latest > current else { return nil }

        let latestVersion = release.tag_name.replacingOccurrences(of: #"^[vV]"#, with: "", options: .regularExpression)
        let releaseURL = release.html_url.flatMap(URL.init(string:)) ?? Self.releasesPageURL
        return ReleaseAvailability(latestVersion: latestVersion, releaseURL: releaseURL)
    }

    static func currentAppVersion(bundle: Bundle = .main) -> String? {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}
