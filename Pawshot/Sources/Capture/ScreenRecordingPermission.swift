import AppKit
import CoreGraphics

/// Screen recording access (TCC). Without it ScreenCaptureKit hands back an empty list of displays
/// instead of a meaningful error, so the check happens upfront.
@MainActor
enum ScreenRecordingPermission {
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
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
        _ = CGRequestScreenCaptureAccess()

        if isGranted {
            return true
        }

        PermissionWindowController.show()
        return false
    }
}
