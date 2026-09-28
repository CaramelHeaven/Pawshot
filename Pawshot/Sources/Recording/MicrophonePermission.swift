import AVFoundation
import os

/// Microphone access (TCC). Asked for only when the user turns the microphone on — never at launch
/// and never for a recording that doesn't use it.
@MainActor
enum MicrophonePermission {
    static var status: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static var isGranted: Bool {
        status == .authorized
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
            Logger(subsystem: "com.caramelheaven.pawshot", category: "permission")
                .notice("microphone asked for: \(granted ? "granted" : "refused", privacy: .public)")
            return granted
        default:
            Logger(subsystem: "com.caramelheaven.pawshot", category: "permission")
                .notice("microphone wanted but not allowed: recording without it")
            return false
        }
    }
}
