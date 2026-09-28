import AppKit
import CoreGraphics

/// Input Monitoring (TCC), for the shortcut captions in a video: reading keys takes a listen-only
/// event tap, and the tap needs it. Clicks don't.
@MainActor
enum InputMonitoringPermission {
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    )

    static var isGranted: Bool {
        CGPreflightListenEventAccess()
    }

    /// Puts Pawshot into the list in System Settings and opens it there: the switch is the user's
    /// to flip.
    static func request() {
        _ = CGRequestListenEventAccess()
        if let settingsURL {
            NSWorkspace.shared.open(settingsURL)
        }
    }
}
