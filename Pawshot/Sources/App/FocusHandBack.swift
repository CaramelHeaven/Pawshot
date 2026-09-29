import AppKit
import os

/// Gives the keyboard back to the app the person was in once the last Pawshot window closes.
///
/// A menu bar agent with no windows left stays the active app: the editor opened over Safari
/// took activation, the editor closed, and typing went nowhere — the owner's report after a ⌘Q
/// tap in the editor. Every way an editor closes ends in `windowWillClose`, so that is where this
/// is called from; the app is remembered when the editor opens, right before it activates
/// Pawshot, since the overlay before it never activates anything.
@MainActor
enum FocusHandBack {
    private static var logger: Logger {
        .pawshot("app")
    }

    /// The app in front, unless it is Pawshot itself.
    static func remember() -> NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        return front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
    }

    /// Settings, another editor or What's New still open keep the focus where it is.
    static func otherWindowsStayOpen(closing window: NSWindow?, among windows: [NSWindow]) -> Bool {
        windows.contains { $0 !== window && $0.isVisible && $0.level == .normal && $0.canBecomeMain }
    }

    static func handBack(to previous: NSRunningApplication?, closing window: NSWindow?) {
        guard NSApp.isActive else { return }
        if otherWindowsStayOpen(closing: window, among: NSApp.windows) {
            logger.notice("focus kept: another Pawshot window is open")
            return
        }
        guard let previous, !previous.isTerminated else {
            logger.notice("focus not handed back: no previous app")
            return
        }
        let name = previous.localizedName ?? "?"
        previous.activate()
        logger.notice("focus handed back to \(name, privacy: .public)")
        // Activation is cooperative since macOS 14 and may be refused; only a log from a real Mac
        // tells whether it went through.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "nobody"
            if NSApp.isActive {
                logger.error("focus not handed back to \(name, privacy: .public): Pawshot still active, front \(front, privacy: .public)")
            } else {
                logger.notice("focus after 500 ms: \(front, privacy: .public) in front")
            }
        }
    }
}
