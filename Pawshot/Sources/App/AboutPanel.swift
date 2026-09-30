import Foundation

/// What the About window says about the build. Kept apart from the view so it can be tested
/// without drawing anything.
enum AboutPanel {
    static let repositoryURL = "https://github.com/CaramelHeaven/Pawshot"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    /// "0.4.5" — the build in brackets only when it says something the version doesn't. Since
    /// Sparkle the build number is the version, and "0.4.5 (0.4.5)" read like a typo.
    static var versionLine: String {
        versionLine(version: version, build: build)
    }

    static func versionLine(version: String, build: String) -> String {
        build == version ? version : "\(version) (\(build))"
    }

    /// From Info.plist, where Finder's Get Info reads it too.
    static var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
    }

    static let contactEmail = "capi.hev@gmail.com"
}
