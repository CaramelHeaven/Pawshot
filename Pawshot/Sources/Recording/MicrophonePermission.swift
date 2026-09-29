import AppKit
import AVFoundation
import os

/// Microphone access (TCC). Asked for only when the user turns the microphone on — never at launch
/// and never for a recording that doesn't use it.
@MainActor
enum MicrophonePermission {
    private static var logger: Logger {
        .pawshot("permission")
    }

    static var status: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    )

    static var isGranted: Bool {
        status == .authorized
    }

    /// From a button: the system prompt the first time, System Settings after a refusal.
    static func request() {
        if status == .notDetermined {
            Task { _ = await resolve(wanted: true) }
        } else if let settingsURL {
            let raw = status.rawValue
            logger.notice("microphone: opening System Settings (status \(raw, privacy: .public))")
            NSWorkspace.shared.open(settingsURL)
        }
    }

    /// Whether a recording that wants the microphone may have it. Shows the system prompt the first
    /// time; a refusal records without the microphone rather than not at all.
    static func resolve(wanted: Bool) async -> Bool {
        guard wanted else { return false }
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            logger.notice("microphone asked for: \(granted ? "granted" : "refused", privacy: .public)")
            return granted
        default:
            let raw = status.rawValue
            logger.notice("microphone wanted but not allowed (status \(raw, privacy: .public)): recording without it")
            return false
        }
    }
}
