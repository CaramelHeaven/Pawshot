import AVFoundation

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
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }
}
