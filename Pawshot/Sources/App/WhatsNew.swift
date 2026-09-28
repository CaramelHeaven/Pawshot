import Foundation

/// What the window after an update says (`WhatsNewView`): every version the person skipped, not
/// just the last one — updating from 0.4.6 to 0.4.9 tells about 0.4.7, 0.4.8 and 0.4.9. A new
/// entry goes on top with every raise of `MARKETING_VERSION` — AGENTS.md, Releasing — and
/// `WhatsNewTests` fails until it does. Older entries stay, translations and all.
enum WhatsNew {
    struct Entry: Equatable {
        let version: String
        /// Plain words for a person, not a changelog. Empty for a release with nothing to tell.
        let text: String
    }

    /// Newest first. The history starts at 0.4.7, the first version with this window.
    static var history: [Entry] {
        [
            Entry(version: "0.4.9", text: String(localized: """
            R now draws a circle, a triangle and a diamond as well: pick one next to the line \
            widths, or press R again. A drawn shape switches the same way.

            The fill follows the opacity slider while you drag it, not only when you let go.

            Every shortcut in Settings now has a cross on its right: remove the shortcut \
            altogether, and the action stays in the paw's menu.

            If a shortcut never reaches Pawshot — macOS or another app takes it first — the field \
            now says so instead of staying silent.

            A shortcut field waiting for keys now lets go when you switch to another window. Until \
            now, Pawshot's shortcuts stopped working meanwhile.
            """)),
            Entry(version: "0.4.8", text: String(localized: """
            This window now opens in front of your other windows. After the last update it could hide \
            behind them.
            """)),
            Entry(version: "0.4.7", text: String(localized: """
            Settings now has a Statistics tab: how many shots you've taken, what you draw with most, \
            how many days in a row. It's all counted on this Mac only.

            Collect Logs can now be switched off — in the welcome window and in Settings → General → \
            Diagnostics.

            If something breaks, the logs reach the developer with one button: Send by Email…, in the \
            same place.
            """)),
        ]
    }

    /// What someone coming from `since` hasn't been told, newest first. `nil` is an update from
    /// 0.4.6 or older, which stored no version: everything there is. Versions compare as numbers,
    /// so 0.4.10 comes after 0.4.9.
    static func entries(in history: [Entry], since: String?) -> [Entry] {
        history.filter { entry in
            !entry.text.isEmpty
                && since.map { entry.version.compare($0, options: .numeric) == .orderedDescending } ?? true
        }
    }

    /// Once per version, and only after an update: a fresh install hasn't pressed "Get Started"
    /// yet and hears from the welcome window instead. No stored version with the welcome done is
    /// an update from 0.4.6, which stored none.
    static func shouldShow(lastSeen: String?, welcomeCompleted: Bool, current: String, history: [Entry]) -> Bool {
        welcomeCompleted && lastSeen != current && !entries(in: history, since: lastSeen).isEmpty
    }

    @MainActor
    static var showsAtLaunch: Bool {
        let settings = Settings.shared
        return shouldShow(
            lastSeen: settings.lastSeenVersion,
            welcomeCompleted: settings.welcomeCompleted,
            current: AboutPanel.version,
            history: history
        )
    }
}
