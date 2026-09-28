import AppKit
import CoreGraphics
import os

/// Screen recording access (TCC). Without it ScreenCaptureKit hands back an empty list of displays
/// instead of a meaningful error, so the check happens upfront.
@MainActor
enum ScreenRecordingPermission {
    private static var logger: Logger {
        .pawshot("permission")
    }

    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )

    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    private static var askedFromAButton = false

    /// From a button: the system prompt the first time, System Settings on every press after it —
    /// the prompt comes once per installation, and opening both at once would be two windows for
    /// one question.
    static func request() {
        if askedFromAButton, let settingsURL {
            logger.notice("screen recording: opening System Settings")
            NSWorkspace.shared.open(settingsURL)
        } else {
            logger.notice("screen recording: asked for from a button")
            askedFromAButton = true
            _ = CGRequestScreenCaptureAccess()
        }
    }

    /// Returns `true` when capturing is already allowed. Otherwise asks the system to show the
    /// prompt and opens the permission window that walks the user through it.
    @discardableResult
    static func ensureGranted() -> Bool {
        if isGranted {
            return true
        }

        // The system prompt is shown once per app installation; after that all we can do is send
        // the user to Settings.
        logger.notice("screen recording: preflight says no, asking the system")
        _ = CGRequestScreenCaptureAccess()

        if isGranted {
            logger.notice("screen recording: granted after the request")
            return true
        }

        logger.notice("screen recording: still not allowed, showing the permission window")
        PermissionWindowController.show()
        return false
    }
}
