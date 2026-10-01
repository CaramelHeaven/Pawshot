import Foundation

/// A named bundle of the recording settings, picked in one move: the overlay's P key, its Options
/// panel and Settings → Recording. A profile keeps nothing of its own — it writes the ordinary
/// settings, so what is ticked in Options after it is the truth, and `current` says which profile
/// (if any) those settings add up to.
///
/// It states only what it cares about; the rest stays as the person left it. Two profiles now; a
/// third, the GIF for a chat with a size limit, waits for the video editor's own release.
enum RecordingProfile: String, CaseIterable, Identifiable {
    /// A short GIF to attach to a ticket.
    case bugReport
    /// A polished take with a voice.
    case demo

    var id: String {
        rawValue
    }

    /// What a profile sets. `nil` is "not my business".
    struct Values: Equatable {
        var microphone: Bool?
        var systemAudio: Bool?
        var nativeResolution: Bool?
        var clicks: Bool?
        var preset: VideoPreset?
    }

    var values: Values {
        switch self {
        case .bugReport:
            Values(microphone: false, systemAudio: false, clicks: true, preset: .gif)
        case .demo:
            Values(microphone: true, nativeResolution: true, preset: .original)
        }
    }

    var title: String {
        switch self {
        case .bugReport: String(localized: "Bug report")
        case .demo: String(localized: "Demo")
        }
    }

    /// What it sets, in a few words.
    var summary: String {
        switch self {
        case .bugReport: String(localized: "GIF 720p · clicks · no sound")
        case .demo: String(localized: "HEVC 2x · voice")
        }
    }

    @MainActor
    func apply(to settings: Settings) {
        let values = values
        if let microphone = values.microphone {
            settings.recordsMicrophone = microphone
        }
        if let systemAudio = values.systemAudio {
            settings.recordsSystemAudio = systemAudio
        }
        if let native = values.nativeResolution {
            settings.recordsAtNativeResolution = native
        }
        if let clicks = values.clicks {
            settings.showsClicks = clicks
        }
        if let preset = values.preset {
            settings.videoPreset = preset
        }
    }

    /// The profile the settings are exactly at, or `nil` — a setting changed by hand since, or
    /// none ever picked.
    @MainActor
    static func current(in settings: Settings) -> RecordingProfile? {
        allCases.first { profile in
            let values = profile.values
            return values.microphone.map { $0 == settings.recordsMicrophone } ?? true
                && values.systemAudio.map { $0 == settings.recordsSystemAudio } ?? true
                && values.nativeResolution.map { $0 == settings.recordsAtNativeResolution } ?? true
                && values.clicks.map { $0 == settings.showsClicks } ?? true
                && values.preset.map { $0 == settings.videoPreset } ?? true
        }
    }

    /// What P picks: the first from "custom", then round the list.
    static func next(after current: RecordingProfile?) -> RecordingProfile {
        guard let current, let index = allCases.firstIndex(of: current) else { return allCases[0] }
        return allCases[(index + 1) % allCases.count]
    }
}
