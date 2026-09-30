import AVFoundation
import CoreAudio
import os

/// The microphones a recording can take its voice from, and which of them it takes.
///
/// A device is known by its unique id — the same string `AVCaptureDevice`, ScreenCaptureKit's
/// `microphoneCaptureDeviceID` and CoreAudio's device UID use — so one stored string serves the
/// recording, the level meter and the list in the toolbar's Options.
enum MicrophoneDevices {
    private static var logger: Logger {
        .pawshot("recording")
    }

    struct Device: Equatable, Identifiable, Sendable {
        let id: String
        let name: String
    }

    /// Every input the system offers, in its own order. Listing them needs no microphone access.
    static func all() -> [Device] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    static var systemDefaultID: String? {
        AVCaptureDevice.default(for: .audio)?.uniqueID
    }

    /// The device a take records from: the stored one while it is still plugged in, otherwise
    /// whatever the system uses by default. `nil` when there is no input at all.
    static func resolved(stored: String?, among devices: [Device], systemDefault: String?) -> String? {
        if let stored, devices.contains(where: { $0.id == stored }) {
            return stored
        }
        if let systemDefault, devices.contains(where: { $0.id == systemDefault }) {
            return systemDefault
        }
        return devices.first?.id
    }

    /// CoreAudio's number for a device's unique id: what `AVAudioEngine`'s input unit is pointed at.
    static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var cfUID = uid as CFString
        let status = withUnsafePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                pointer,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            logger.error("no CoreAudio device for a stored microphone (status \(status, privacy: .public))")
            return nil
        }
        return deviceID
    }
}
