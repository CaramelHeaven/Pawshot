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
}
