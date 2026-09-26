import CoreGraphics
import Foundation
import Observation

/// What the app remembers between launches. Deliberately thin: only the values that are really
/// stored, each with a default, so a fresh install and a broken value behave the same way.
///
/// `UserDefaults` comes in as a parameter — tests get their own suite and never touch the owner's
/// real settings.
///
/// Observable so the menu, the settings window and the welcome window redraw when a value changes.
/// The values themselves live in `UserDefaults`, which Observation can't see into; every getter
/// reads `revision` and every setter bumps it, and that is what the views end up tracking.
@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    enum Key: String {
        case regionHotKey = "hotkey.region"
        case fullScreenHotKey = "hotkey.fullScreen"
        case recordRegionHotKey = "hotkey.recordRegion"
        case recordFullScreenHotKey = "hotkey.recordFullScreen"
        case zoomMarkHotKey = "hotkey.zoomMark"
        case penHotKey = "hotkey.pen"
        case restartHotKey = "hotkey.restart"
        case recordsMicrophone = "recording.microphone"
        case recordsSystemAudio = "recording.systemAudio"
        case recordsAtNativeResolution = "recording.nativeResolution"
        case lastRecordingAreas = "recording.lastAreas"
        case videoPreset = "video.preset"
        case showsKeystrokes = "recording.keystrokes"
        case showsClicks = "video.clicks"
        case showsZooms = "video.zooms"
        case videoEditorOpenCount = "stats.videoEditorOpenCount"
        case captureCount = "stats.captureCount"
    }

    /// Told when a hotkey changed, so `AppDelegate` can re-register it.
    @ObservationIgnored var onHotKeysChange: (() -> Void)?

    /// Told while the settings window is recording a new combination.
    ///
    /// Carbon delivers a registered hotkey before the key press reaches any view, so a recorder
    /// asked to replace `⌘⇧2` would trigger a capture instead. `AppDelegate` unregisters
    /// everything for the duration of the recording.
    @ObservationIgnored var onHotKeyRecordingChange: ((Bool) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    private var revision = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var regionHotKey: HotKeyBinding {
        get { binding(for: .regionHotKey) ?? .regionDefault }
        set { store(newValue, for: .regionHotKey) }
    }

    var fullScreenHotKey: HotKeyBinding {
        get { binding(for: .fullScreenHotKey) ?? .fullScreenDefault }
        set { store(newValue, for: .fullScreenHotKey) }
    }

    var recordRegionHotKey: HotKeyBinding {
        get { binding(for: .recordRegionHotKey) ?? .recordRegionDefault }
        set { store(newValue, for: .recordRegionHotKey) }
    }

    var recordFullScreenHotKey: HotKeyBinding {
        get { binding(for: .recordFullScreenHotKey) ?? .recordFullScreenDefault }
        set { store(newValue, for: .recordFullScreenHotKey) }
    }

    /// Marks a zoom while recording. Only registered during a take.
    var zoomMarkHotKey: HotKeyBinding {
        get { binding(for: .zoomMarkHotKey) ?? .zoomMarkDefault }
        set { store(newValue, for: .zoomMarkHotKey) }
    }

    /// Switches the pen while recording. Only registered during a take.
    var penHotKey: HotKeyBinding {
        get { binding(for: .penHotKey) ?? .penDefault }
        set { store(newValue, for: .penHotKey) }
    }

    /// Starts the take over. Only registered during a take.
    var restartHotKey: HotKeyBinding {
        get { binding(for: .restartHotKey) ?? .restartDefault }
        set { store(newValue, for: .restartHotKey) }
    }

    /// Every hotkey the app registers, for the "the same combination can't do two things" check.
    /// The recording-time ones count too: they would collide the moment a take starts.
    var allHotKeys: [HotKeyBinding] {
        [
            regionHotKey, fullScreenHotKey, recordRegionHotKey, recordFullScreenHotKey,
            zoomMarkHotKey, penHotKey, restartHotKey,
        ]
    }

    /// The microphone goes into recordings. Off by default: the app asks for nothing until the
    /// user turns it on.
    var recordsMicrophone: Bool {
        get { flag(.recordsMicrophone, default: false) }
        set { setFlag(newValue, for: .recordsMicrophone) }
    }

    /// What the Mac plays goes into recordings. On by default: it needs no extra permission.
    var recordsSystemAudio: Bool {
        get { flag(.recordsSystemAudio, default: true) }
        set { setFlag(newValue, for: .recordsSystemAudio) }
    }

    /// The display's own pixels in a recording (2x on Retina), or one pixel per point (1x) — half
    /// the width, a quarter of the file. X on the recording overlay switches it.
    var recordsAtNativeResolution: Bool {
        get { flag(.recordsAtNativeResolution, default: true) }
        set { setFlag(newValue, for: .recordsAtNativeResolution) }
    }

    /// The region last recorded on a display, in that display's points (origin top left) — the
    /// dashed ghost ↩ records again. Per display: the same rectangle means nothing on another one.
    func lastRecordingArea(on displayID: CGDirectDisplayID) -> CGRect? {
        _ = revision
        let areas = defaults.dictionary(forKey: Key.lastRecordingAreas.rawValue) as? [String: String]
        guard let stored = areas?[String(displayID)] else { return nil }
        let rect = NSRectFromString(stored)
        return rect.isEmpty ? nil : rect
    }

    func setLastRecordingArea(_ rect: CGRect, on displayID: CGDirectDisplayID) {
        var areas = defaults.dictionary(forKey: Key.lastRecordingAreas.rawValue) as? [String: String] ?? [:]
        areas[String(displayID)] = NSStringFromRect(rect)
        defaults.set(areas, forKey: Key.lastRecordingAreas.rawValue)
        revision += 1
    }

    /// Shortcuts pressed during a recording are shown in the video. Off by default: it needs Input
    /// Monitoring, the one permission that reads the keyboard, and nobody should grant that by
    /// accident.
    var showsKeystrokes: Bool {
        get { flag(.showsKeystrokes, default: false) }
        set { setFlag(newValue, for: .showsKeystrokes) }
    }

    /// Orange rings where the mouse clicked, in the exported video. What the video editor starts
    /// with; its own switch still turns them off for one recording.
    var showsClicks: Bool {
        get { flag(.showsClicks, default: true) }
        set { setFlag(newValue, for: .showsClicks) }
    }

    /// The zooms marked with ⇧⌘6 while recording, in the exported video. Same terms as the clicks.
    var showsZooms: Bool {
        get { flag(.showsZooms, default: true) }
        set { setFlag(newValue, for: .showsZooms) }
    }

    /// How many times the video editor has opened: its key hints show for the first few.
    var videoEditorOpenCount: Int {
        _ = revision
        return defaults.integer(forKey: Key.videoEditorOpenCount.rawValue)
    }

    func recordVideoEditorOpen() {
        defaults.set(videoEditorOpenCount + 1, forKey: Key.videoEditorOpenCount.rawValue)
        revision += 1
    }

    /// What a recording leaves the video editor as. P there cycles it.
    var videoPreset: VideoPreset {
        get {
            _ = revision
            return defaults.string(forKey: Key.videoPreset.rawValue).flatMap(VideoPreset.init(rawValue:)) ?? .original
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.videoPreset.rawValue)
            revision += 1
        }
    }

    /// How many shots reached the editor. Drives the key hints on the first captures and the line
    /// in the About window.
    var captureCount: Int {
        _ = revision
        return defaults.integer(forKey: Key.captureCount.rawValue)
    }

    func recordCapture() {
        defaults.set(captureCount + 1, forKey: Key.captureCount.rawValue)
        revision += 1
    }

    func resetHotKeysToDefaults() {
        defaults.removeObject(forKey: Key.regionHotKey.rawValue)
        defaults.removeObject(forKey: Key.fullScreenHotKey.rawValue)
        defaults.removeObject(forKey: Key.recordRegionHotKey.rawValue)
        defaults.removeObject(forKey: Key.recordFullScreenHotKey.rawValue)
        defaults.removeObject(forKey: Key.zoomMarkHotKey.rawValue)
        defaults.removeObject(forKey: Key.penHotKey.rawValue)
        defaults.removeObject(forKey: Key.restartHotKey.rawValue)
        revision += 1
        onHotKeysChange?()
    }

    // MARK: - Storage

    /// A stored binding that no longer decodes is treated as absent: the app falls back to the
    /// default instead of starting without a hotkey at all.
    private func binding(for key: Key) -> HotKeyBinding? {
        _ = revision
        guard let data = defaults.data(forKey: key.rawValue) else { return nil }
        return try? JSONDecoder().decode(HotKeyBinding.self, from: data)
    }

    private func store(_ binding: HotKeyBinding, for key: Key) {
        guard let data = try? JSONEncoder().encode(binding) else { return }

        defaults.set(data, forKey: key.rawValue)
        revision += 1
        onHotKeysChange?()
    }

    private func flag(_ key: Key, default value: Bool) -> Bool {
        _ = revision
        return defaults.object(forKey: key.rawValue) as? Bool ?? value
    }

    private func setFlag(_ value: Bool, for key: Key) {
        defaults.set(value, forKey: key.rawValue)
        revision += 1
    }
}
