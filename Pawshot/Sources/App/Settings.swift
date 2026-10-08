import AppKit
import CoreGraphics
import Foundation
import Observation
import os
import UniformTypeIdentifiers

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
        case penHotKey = "hotkey.pen"
        case restartHotKey = "hotkey.restart"
        case badTakeHotKey = "hotkey.badTake"
        case spotlightHotKey = "hotkey.spotlight"
        case blurHotKey = "hotkey.blur"
        case muteHotKey = "hotkey.mute"
        case recordingGoal = "recording.goal"
        case recordsMicrophone = "recording.microphone"
        case microphoneDevice = "recording.microphoneDevice"
        case recordsSystemAudio = "recording.systemAudio"
        case recordsAtNativeResolution = "recording.nativeResolution"
        case lastRecordingAreas = "recording.lastAreas"
        case recordingFramesPerSecond = "recording.fps"
        case recordingToolbarAnchor = "recording.toolbarAnchor"
        case videoPreset = "video.preset"
        case showsKeystrokes = "recording.keystrokes"
        case showsClicks = "video.clicks"
        case videoEditorOpenCount = "stats.videoEditorOpenCount"
        case captureCount = "stats.captureCount"
        case language = "app.language"
        case warnsBeforeQuitting = "app.warnsBeforeQuitting"
        case welcomeCompleted = "app.welcomeCompleted"
        case lastSeenVersion = "app.lastSeenVersion"
        case collectsLogs = "app.collectsLogs"
        case customColor = "editor.customColor"
        case recentColors = "editor.recentColors"
        case defaultShapeColor = "editor.defaultShapeColor"
        case defaultPencilColor = "editor.defaultPencilColor"
        case defaultTextColor = "editor.defaultTextColor"
        case customShapeColor = "editor.customShapeColor"
        case customPencilColor = "editor.customPencilColor"
        case customTextColor = "editor.customTextColor"
        case labelFont = "editor.labelFont"
        case toolsPlacement = "editor.toolsPlacement"
        case overlayToolsScale = "editor.overlayToolsScale"
        case saveFolder = "export.folder"
        case imageFormat = "export.imageFormat"
    }

    /// Told when a hotkey changed, so `AppDelegate` can re-register it.
    @ObservationIgnored var onHotKeysChange: (() -> Void)?

    /// Told when the labels' family changed, so open editors re-set their labels at once.
    @ObservationIgnored var onLabelFontChange: (() -> Void)?

    /// Told when the tools move between under the shot and over it, so open editors refit.
    @ObservationIgnored var onToolsPlacementChange: (() -> Void)?

    /// Told when a card changes, so open editors can use its colour for their next annotation.
    @ObservationIgnored var onDefaultAnnotationColorChange: ((AnnotationColorGroup) -> Void)?

    /// Told while the settings window is recording a new combination.
    ///
    /// Carbon delivers a registered hotkey before the key press reaches any view, so a recorder
    /// asked to replace `⌘⇧2` would trigger a capture instead. `AppDelegate` unregisters
    /// everything for the duration of the recording.
    @ObservationIgnored var onHotKeyRecordingChange: ((Bool) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    private static var logger: Logger {
        .pawshot("settings")
    }

    private var revision = 0

    /// The language the running process picked its strings in — they are read once, at launch.
    @ObservationIgnored let launchLanguage: AppLanguage

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        launchLanguage = defaults.string(forKey: Key.language.rawValue).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    var regionHotKey: HotKeyBinding? {
        get { binding(for: .regionHotKey, default: .regionDefault) }
        set { store(newValue, for: .regionHotKey, default: .regionDefault) }
    }

    var fullScreenHotKey: HotKeyBinding? {
        get { binding(for: .fullScreenHotKey, default: .fullScreenDefault) }
        set { store(newValue, for: .fullScreenHotKey, default: .fullScreenDefault) }
    }

    var recordRegionHotKey: HotKeyBinding? {
        get { binding(for: .recordRegionHotKey, default: .recordRegionDefault) }
        set { store(newValue, for: .recordRegionHotKey, default: .recordRegionDefault) }
    }

    var recordFullScreenHotKey: HotKeyBinding? {
        get { binding(for: .recordFullScreenHotKey, default: .recordFullScreenDefault) }
        set { store(newValue, for: .recordFullScreenHotKey, default: .recordFullScreenDefault) }
    }

    /// Switches the pen while recording. Only registered during a take.
    var penHotKey: HotKeyBinding? {
        get { binding(for: .penHotKey, default: .penDefault) }
        set { store(newValue, for: .penHotKey, default: .penDefault) }
    }

    /// Starts the take over. Only registered during a take.
    var restartHotKey: HotKeyBinding? {
        get { binding(for: .restartHotKey, default: .restartDefault) }
        set { store(newValue, for: .restartHotKey, default: .restartDefault) }
    }

    /// Marks the last seconds as a bad take. Only registered during a take.
    var badTakeHotKey: HotKeyBinding? {
        get { binding(for: .badTakeHotKey, default: .badTakeDefault) }
        set { store(newValue, for: .badTakeHotKey, default: .badTakeDefault) }
    }

    /// Held: a spotlight around the cursor. Only registered during a take.
    var spotlightHotKey: HotKeyBinding? {
        get { binding(for: .spotlightHotKey, default: .spotlightDefault) }
        set { store(newValue, for: .spotlightHotKey, default: .spotlightDefault) }
    }

    /// Held: the picture is hidden. Only registered during a take.
    var blurHotKey: HotKeyBinding? {
        get { binding(for: .blurHotKey, default: .blurDefault) }
        set { store(newValue, for: .blurHotKey, default: .blurDefault) }
    }

    /// Held: the microphone records silence. Only registered during a take.
    var muteHotKey: HotKeyBinding? {
        get { binding(for: .muteHotKey, default: .muteDefault) }
        set { store(newValue, for: .muteHotKey, default: .muteDefault) }
    }

    /// How long a take is meant to be, in seconds; 0 aims for nothing. The pill shows the time
    /// against it and a bar that fills up — the take is never stopped by it.
    var recordingGoal: TimeInterval {
        get {
            _ = revision
            return defaults.double(forKey: Key.recordingGoal.rawValue)
        }
        set {
            Self.logger.notice("recording goal → \(Int(newValue), privacy: .public) s")
            defaults.set(newValue, forKey: Key.recordingGoal.rawValue)
            revision += 1
        }
    }

    /// Every hotkey the app registers, for the "the same combination can't do two things" check.
    /// The recording-time ones count too: they would collide the moment a take starts. One cleared
    /// with the field's × isn't here — it registers nothing.
    var allHotKeys: [HotKeyBinding] {
        [
            regionHotKey, fullScreenHotKey, recordRegionHotKey, recordFullScreenHotKey,
            penHotKey, restartHotKey, badTakeHotKey,
            spotlightHotKey, blurHotKey, muteHotKey,
        ].compactMap(\.self)
    }

    /// ⌘Q has to be held to quit, with a toast saying so — Chrome's "Warn Before Quitting". On by
    /// default; off, ⌘Q quits at once, as in any other app.
    var warnsBeforeQuitting: Bool {
        get { flag(.warnsBeforeQuitting, default: true) }
        set { setFlag(newValue, for: .warnsBeforeQuitting) }
    }

    /// "Get Started" was pressed in the welcome window. Until then it opens by itself at every
    /// launch — closing it some other way is not an answer.
    var welcomeCompleted: Bool {
        get { flag(.welcomeCompleted, default: false) }
        set { setFlag(newValue, for: .welcomeCompleted) }
    }

    /// The version whose "What's New" was last shown — or the one "Get Started" was pressed in, so
    /// a fresh install is not told about changes it never lived through (`WhatsNew`).
    var lastSeenVersion: String? {
        get {
            _ = revision
            return defaults.string(forKey: Key.lastSeenVersion.rawValue)
        }
        set {
            Self.logger.notice("\(Key.lastSeenVersion.rawValue, privacy: .public) → \(newValue ?? "nil", privacy: .public)")
            defaults.set(newValue, forKey: Key.lastSeenVersion.rawValue)
            revision += 1
        }
    }

    /// Pawshot writes its log and keeps the stacks of its stalls, for Save Logs to send. On by
    /// default: a bug met before switching it on would leave nothing behind. Off, every logger
    /// goes quiet at once (`Logger.pawshot`).
    var collectsLogs: Bool {
        get { flag(.collectsLogs, default: true) }
        set {
            // Logged while the log is on: before the switch goes off, after it goes on.
            let key = Key.collectsLogs.rawValue
            if !newValue {
                Self.logger.notice("\(key, privacy: .public) → false")
            }
            defaults.set(newValue, forKey: key)
            revision += 1
            if newValue {
                Self.logger.notice("\(key, privacy: .public) → true")
            }
        }
    }

    /// The microphone goes into recordings. Off by default: the app asks for nothing until the
    /// user turns it on.
    var recordsMicrophone: Bool {
        get { flag(.recordsMicrophone, default: false) }
        set { setFlag(newValue, for: .recordsMicrophone) }
    }

    /// The microphone picked in the recording toolbar's Options, by its unique id. `nil` until one
    /// is picked: the system's default input is used, as it always was. A stored device that is
    /// no longer plugged in falls back to the default too — `MicrophoneDevices.resolved`.
    var microphoneDeviceID: String? {
        get {
            _ = revision
            return defaults.string(forKey: Key.microphoneDevice.rawValue)
        }
        set {
            let described = newValue ?? "system default"
            Self.logger.notice("microphone device → \(described, privacy: .public)")
            if let newValue {
                defaults.set(newValue, forKey: Key.microphoneDevice.rawValue)
            } else {
                defaults.removeObject(forKey: Key.microphoneDevice.rawValue)
            }
            revision += 1
        }
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
    /// next ⇧⌘3 starts with it. Per display: the same rectangle means nothing on another one.
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

    /// The frame rates a take can be recorded at. 60 is the default, as it always was.
    static let recordingFrameRates = [15, 24, 30, 60]

    /// How many frames a second a take records. Lower makes a lighter file — the bitrate and the
    /// key frames are counted from it. A stored value not in `recordingFrameRates` reads as 60.
    var recordingFramesPerSecond: Int {
        get {
            _ = revision
            guard let stored = defaults.object(forKey: Key.recordingFramesPerSecond.rawValue) as? Int else { return 60 }
            guard Self.recordingFrameRates.contains(stored) else {
                Self.logger.error("recording fps \(stored, privacy: .public) is not offered, 60 is used")
                return 60
            }
            return stored
        }
        set {
            Self.logger.notice("recording fps → \(newValue, privacy: .public)")
            defaults.set(newValue, forKey: Key.recordingFramesPerSecond.rawValue)
            revision += 1
        }
    }

    /// Where the recording overlay's toolbar was left: the middle of its row of buttons, as
    /// fractions of the screen (0…1, origin top left). One for every screen. `nil` — the toolbar
    /// sits at the bottom in the middle.
    var recordingToolbarAnchor: CGPoint? {
        get {
            _ = revision
            return defaults.string(forKey: Key.recordingToolbarAnchor.rawValue).map(NSPointFromString)
        }
        set {
            let described = newValue.map { String(format: "%.3f, %.3f", $0.x, $0.y) } ?? "default"
            Self.logger.notice("recording toolbar anchor → \(described, privacy: .public)")
            if let newValue {
                defaults.set(NSStringFromPoint(newValue), forKey: Key.recordingToolbarAnchor.rawValue)
            } else {
                defaults.removeObject(forKey: Key.recordingToolbarAnchor.rawValue)
            }
            revision += 1
        }
    }

    /// Shortcuts pressed during a recording are shown in the video. Off by default: it needs Input
    /// Monitoring, the one permission that reads the keyboard, and nobody should grant that by
    /// accident.
    var showsKeystrokes: Bool {
        get { flag(.showsKeystrokes, default: false) }
        set { setFlag(newValue, for: .showsKeystrokes) }
    }

    /// Orange rings where the mouse clicked, in the exported video. What the video editor starts
    /// with; its own switch still turns them on or off for one recording. Off by default: any
    /// effect turns a quick copy of the file into a full re-encode.
    var showsClicks: Bool {
        get { flag(.showsClicks, default: false) }
        set { setFlag(newValue, for: .showsClicks) }
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
            Self.logger.notice("video preset → \(newValue.rawValue, privacy: .public)")
            defaults.set(newValue.rawValue, forKey: Key.videoPreset.rawValue)
            revision += 1
        }
    }

    /// The interface language. Kept under a key of our own and mirrored into `AppleLanguages`,
    /// which is what the bundle actually reads — but only at launch, hence `launchLanguage`.
    /// `AppleLanguages` can't be read back for this: through `UserDefaults` it falls through to
    /// the system's own list whenever the app has none. `AppleLocale` goes along with it: the
    /// strings follow `AppleLanguages`, but numbers, dates and durations follow the locale, and
    /// without it a Russian Statistics tab said "41 days".
    var language: AppLanguage {
        get {
            _ = revision
            return defaults.string(forKey: Key.language.rawValue).flatMap(AppLanguage.init(rawValue:)) ?? .system
        }
        set {
            Self.logger.notice("language → \(newValue.rawValue, privacy: .public)")
            defaults.set(newValue.rawValue, forKey: Key.language.rawValue)
            if newValue == .system {
                defaults.removeObject(forKey: AppLanguage.appleLanguagesKey)
                defaults.removeObject(forKey: AppLanguage.appleLocaleKey)
            } else {
                defaults.set([newValue.rawValue], forKey: AppLanguage.appleLanguagesKey)
                defaults.set(newValue.localeIdentifier, forKey: AppLanguage.appleLocaleKey)
            }
            revision += 1
        }
    }

    /// The editor's fifth colour, the one of one's own. Kept between launches, so key 5 means the
    /// same colour tomorrow.
    var customColor: NSColor {
        get {
            _ = revision
            return defaults.string(forKey: Key.customColor.rawValue).flatMap(ColorHex.color) ?? .systemPurple
        }
        set {
            defaults.set(ColorHex.string(newValue), forKey: Key.customColor.rawValue)
            revision += 1
        }
    }

    var defaultAnnotationColors: AnnotationDefaultColors {
        AnnotationDefaultColors(
            shapes: defaultAnnotationColor(for: .shapes),
            pencil: defaultAnnotationColor(for: .pencil),
            text: defaultAnnotationColor(for: .text)
        )
    }

    func defaultAnnotationColor(for group: AnnotationColorGroup) -> NSColor {
        _ = revision
        return defaults.string(forKey: defaultColorKey(for: group).rawValue)
            .flatMap(ColorHex.color) ?? AnnotationStyle.Palette.colors[0]
    }

    func customAnnotationColor(for group: AnnotationColorGroup) -> NSColor {
        _ = revision
        return defaults.string(forKey: customColorKey(for: group).rawValue)
            .flatMap(ColorHex.color) ?? .systemPurple
    }

    func setDefaultAnnotationColor(_ color: NSColor, for group: AnnotationColorGroup) {
        let hex = ColorHex.string(color)
        Self.logger.notice("default \(group.rawValue, privacy: .public) colour → \(hex, privacy: .public)")
        defaults.set(hex, forKey: defaultColorKey(for: group).rawValue)
        revision += 1
        onDefaultAnnotationColorChange?(group)
    }

    /// The custom swatch in each card keeps its own colour even after a preset is chosen.
    func pickCustomAnnotationColor(_ color: NSColor, for group: AnnotationColorGroup) {
        defaults.set(ColorHex.string(color), forKey: customColorKey(for: group).rawValue)
        rememberRecentColor(color)
        setDefaultAnnotationColor(color, for: group)
    }

    private func defaultColorKey(for group: AnnotationColorGroup) -> Key {
        switch group {
        case .shapes: .defaultShapeColor
        case .pencil: .defaultPencilColor
        case .text: .defaultTextColor
        }
    }

    private func customColorKey(for group: AnnotationColorGroup) -> Key {
        switch group {
        case .shapes: .customShapeColor
        case .pencil: .customPencilColor
        case .text: .customTextColor
        }
    }

    /// The family labels are set in; `nil` is the system font. Applies at once: `AppDelegate`
    /// hands it to `LabelFont` and to every open editor through `onLabelFontChange`. The words
    /// "system" and "formular" are what earlier builds stored, and both mean the system font now.
    var labelFontFamily: String? {
        get {
            _ = revision
            guard let stored = defaults.string(forKey: Key.labelFont.rawValue),
                  stored != "system", stored != "formular"
            else { return nil }
            return stored
        }
        set {
            Self.logger.notice("label font → \(newValue ?? "system", privacy: .public)")
            if let newValue {
                defaults.set(newValue, forKey: Key.labelFont.rawValue)
            } else {
                defaults.removeObject(forKey: Key.labelFont.rawValue)
            }
            revision += 1
            onLabelFontChange?()
        }
    }

    /// Where the editor's tools and colours sit: in a strip under the shot, or floating over its
    /// bottom edge.
    var toolsPlacement: ToolsPlacement {
        get {
            _ = revision
            return defaults.string(forKey: Key.toolsPlacement.rawValue).flatMap(ToolsPlacement.init(rawValue:)) ?? .below
        }
        set {
            Self.logger.notice("tools placement → \(newValue.rawValue, privacy: .public)")
            defaults.set(newValue.rawValue, forKey: Key.toolsPlacement.rawValue)
            revision += 1
            onToolsPlacementChange?()
        }
    }

    /// Where ⌘S puts shots and videos. The Desktop until another folder is chosen; a folder that
    /// is gone by now falls back to it rather than failing every save.
    var saveFolder: URL {
        get {
            _ = revision
            if let path = defaults.string(forKey: Key.saveFolder.rawValue) {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                    return URL(fileURLWithPath: path, isDirectory: true)
                }
                Self.reportOnce("save folder \(path) is gone: saving to the Desktop")
            }
            return Self.desktop
        }
        set {
            Self.logger.notice("save folder → \(newValue.path, privacy: .public)")
            defaults.set(newValue.path, forKey: Key.saveFolder.rawValue)
            revision += 1
        }
    }

    /// The folder as the Finder names it — "Desktop" reads «Рабочий стол» in Russian.
    var saveFolderName: String {
        FileManager.default.displayName(atPath: saveFolder.path)
    }

    static var desktop: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// The format ⌘S and a dragged shot are written in. Videos keep their own (the editor's P).
    var imageFormat: ImageFormat {
        get {
            _ = revision
            return defaults.string(forKey: Key.imageFormat.rawValue).flatMap(ImageFormat.init(rawValue:)) ?? .png
        }
        set {
            Self.logger.notice("image format → \(newValue.rawValue, privacy: .public)")
            defaults.set(newValue.rawValue, forKey: Key.imageFormat.rawValue)
            revision += 1
        }
    }

    /// How big the tools are drawn over the shot, dragged by their edge; 1 is their own size. The
    /// editor keeps it within `SelectionGeometry.toolsScale`.
    var overlayToolsScale: CGFloat {
        get {
            _ = revision
            return defaults.object(forKey: Key.overlayToolsScale.rawValue) as? CGFloat ?? 1
        }
        set {
            defaults.set(newValue, forKey: Key.overlayToolsScale.rawValue)
            revision += 1
        }
    }

    /// The last colours picked in the colour picker, newest first.
    var recentColors: [NSColor] {
        _ = revision
        return (defaults.stringArray(forKey: Key.recentColors.rawValue) ?? []).compactMap(ColorHex.color)
    }

    /// Picks a colour of one's own: it becomes key 5 and goes to the front of the recent ones.
    func pickCustomColor(_ color: NSColor) {
        rememberRecentColor(color)
        defaults.set(ColorHex.string(color), forKey: Key.customColor.rawValue)
        revision += 1
    }

    private func rememberRecentColor(_ color: NSColor) {
        let hex = ColorHex.string(color)
        let recent = [hex] + (defaults.stringArray(forKey: Key.recentColors.rawValue) ?? []).filter { $0 != hex }
        defaults.set(Array(recent.prefix(8)), forKey: Key.recentColors.rawValue)
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
        Self.logger.notice("shortcuts reset to defaults")
        defaults.removeObject(forKey: Key.regionHotKey.rawValue)
        defaults.removeObject(forKey: Key.fullScreenHotKey.rawValue)
        defaults.removeObject(forKey: Key.recordRegionHotKey.rawValue)
        defaults.removeObject(forKey: Key.recordFullScreenHotKey.rawValue)
        defaults.removeObject(forKey: Key.penHotKey.rawValue)
        defaults.removeObject(forKey: Key.restartHotKey.rawValue)
        defaults.removeObject(forKey: Key.badTakeHotKey.rawValue)
        defaults.removeObject(forKey: Key.spotlightHotKey.rawValue)
        defaults.removeObject(forKey: Key.blurHotKey.rawValue)
        defaults.removeObject(forKey: Key.muteHotKey.rawValue)
        revision += 1
        onHotKeysChange?()
    }

    // MARK: - Storage

    /// What a shortcut cleared with the field's × is stored as. Kept apart from a missing key,
    /// which means "the default" — Restore Defaults removes the keys and brings every one back.
    static let clearedMarker = Data("none".utf8)

    /// `nil` for a shortcut cleared on purpose. A stored binding that no longer decodes is treated
    /// as absent: the app falls back to the default instead of starting without a hotkey at all.
    private func binding(for key: Key, default fallback: HotKeyBinding) -> HotKeyBinding? {
        _ = revision
        guard let data = defaults.data(forKey: key.rawValue) else { return fallback }
        if data == Self.clearedMarker {
            return nil
        }
        do {
            return try JSONDecoder().decode(HotKeyBinding.self, from: data)
        } catch {
            Self.reportOnce("shortcut \(key.rawValue) doesn't decode, using the default \(fallback.logString): \(String(describing: error))")
            return fallback
        }
    }

    /// Fallbacks that happen on every read, logged once per process — the getters run on every
    /// redraw.
    private static var reported: Set<String> = []

    private static func reportOnce(_ message: String) {
        guard reported.insert(message).inserted else { return }
        logger.error("\(message, privacy: .public)")
    }

    private func store(_ binding: HotKeyBinding?, for key: Key, default fallback: HotKeyBinding) {
        let data: Data
        if let binding {
            guard let encoded = try? JSONEncoder().encode(binding) else {
                Self.logger.error("shortcut \(key.rawValue, privacy: .public) not stored: it doesn't encode")
                return
            }
            data = encoded
        } else {
            data = Self.clearedMarker
        }
        let old = self.binding(for: key, default: fallback)?.logString ?? "none"
        let new = binding?.logString ?? "none"
        Self.logger.notice("shortcut \(key.rawValue, privacy: .public): \(old, privacy: .public) → \(new, privacy: .public)")

        defaults.set(data, forKey: key.rawValue)
        revision += 1
        onHotKeysChange?()
    }

    private func flag(_ key: Key, default value: Bool) -> Bool {
        _ = revision
        return defaults.object(forKey: key.rawValue) as? Bool ?? value
    }

    private func setFlag(_ value: Bool, for key: Key) {
        Self.logger.notice("\(key.rawValue, privacy: .public) → \(value, privacy: .public)")
        defaults.set(value, forKey: key.rawValue)
        revision += 1
    }
}

/// The languages Pawshot speaks; `system` follows macOS.
enum AppLanguage: String, CaseIterable {
    case system
    case english = "en"
    case russian = "ru"

    static let appleLanguagesKey = "AppleLanguages"
    static let appleLocaleKey = "AppleLocale"

    /// "ru_GB": the interface's language with the Mac's own region, so the units and month names
    /// match the interface while the region keeps its calendar.
    var localeIdentifier: String {
        Locale.current.region.map { "\(rawValue)_\($0.identifier)" } ?? rawValue
    }
}

/// Where the editor's capsule of tools and colours sits.
/// A saved shot's file format. PNG keeps every pixel; JPEG and HEIC are a fraction of the size
/// for a photo-like shot and blur text edges a little.
enum ImageFormat: String, CaseIterable {
    case png
    case jpeg
    case heic

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .heic: "heic"
        }
    }

    var type: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        }
    }

    /// As on the picker; the names are the formats' own and stay untranslated.
    var name: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        }
    }
}

enum ToolsPlacement: String, CaseIterable {
    /// A strip of its own under the shot: nothing of the shot is covered.
    case below
    /// Floating over the shot's bottom edge, the way markup looks on an iPhone.
    case overlay
}
