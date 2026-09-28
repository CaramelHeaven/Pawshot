import Foundation

/// What the window after an update says (`WhatsNewView`). Rewritten with every raise of
/// `MARKETING_VERSION` — AGENTS.md, Releasing — and `WhatsNewTests` fails until it is.
enum WhatsNew {
    /// The version the text is about.
    static let version = "0.4.7"

    /// Plain words for a person, not a changelog. Empty for a release with nothing to tell, and
    /// then there is no window.
    static var text: String {
        String(localized: """
        Settings now has a Statistics tab: how many shots you've taken, what you draw with most, \
        how many days in a row. It's all counted on this Mac only.

        Collect Logs can now be switched off — in the welcome window and in Settings → General → \
        Diagnostics.

        If something breaks, the logs reach the developer with one button: Send by Email…, in the \
        same place.
        """)
    }

    /// Once per version, and only after an update: a fresh install hasn't pressed "Get Started"
    /// yet and hears from the welcome window instead. No stored version with the welcome done is
    /// an update from 0.4.6, which stored none.
    static func shouldShow(lastSeen: String?, welcomeCompleted: Bool, current: String, text: String) -> Bool {
        welcomeCompleted && lastSeen != current && !text.isEmpty
    }

    @MainActor
    static var showsAtLaunch: Bool {
        let settings = Settings.shared
        return shouldShow(
            lastSeen: settings.lastSeenVersion,
            welcomeCompleted: settings.welcomeCompleted,
            current: AboutPanel.version,
            text: text
        )
    }
}
