import AppKit
import os
import SwiftUI

/// The settings window: a tab in the toolbar per topic, a grouped form in each — the owner's О-C
/// of 2026-09-29: Screenshots and Recording side by side, as the two halves of the app. About is
/// not here; it has a window of its own.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings()
            }
            Tab("Screenshots", systemImage: "camera.viewfinder") {
                ScreenshotSettings()
            }
            Tab("Recording", systemImage: "record.circle") {
                RecordingSettings()
            }
            Tab("Shortcuts", systemImage: "keyboard") {
                ShortcutSettings()
            }
            Tab("Statistics", systemImage: "chart.bar") {
                StatsView()
            }
        }
        .frame(width: 520)
        .background(ComesForward("settings"))
    }
}

/// What the app itself does: starting, quitting, its language, its log — the owner's Г-A.
private struct GeneralSettings: View {
    @Bindable private var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: LoginItem.menuBinding) {
                    Label("Launch at Login", systemImage: "power")
                }
                .disabled(!LoginItem.isInApplicationsFolder)
                if let hint = LoginItem.hint {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: $settings.warnsBeforeQuitting) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Warn Before Quitting (⌘Q)")
                            Group {
                                if settings.warnsBeforeQuitting {
                                    Text("A tap of ⌘Q closes the window in front; hold ⌘Q to quit Pawshot.")
                                } else {
                                    Text("⌘Q quits Pawshot at once.")
                                }
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                    }
                }
                Picker(selection: $settings.language) {
                    Text("System").tag(AppLanguage.system)
                    // Each language is named in itself, so it can be found from the other one.
                    Text(verbatim: "English").tag(AppLanguage.english)
                    Text(verbatim: "Русский").tag(AppLanguage.russian)
                } label: {
                    Label("Language", systemImage: "globe")
                }
                // Menus, alerts and the system's own items read the language only at launch.
                if settings.language != settings.launchLanguage {
                    LabeledContent("Takes effect after a relaunch.") {
                        Button("Relaunch", action: PermissionView.relaunch)
                    }
                    .font(.footnote)
                }
            }
            Section {
                Toggle(isOn: LogExport.collectingBinding) {
                    Label("Collect Logs", systemImage: "doc.text")
                }
                if settings.collectsLogs {
                    LabeledContent(isCollectingLogs ? "Collecting…" : "Logs") {
                        HStack {
                            Button("Save…") { collectLogs(LogExport.saveWithPanel) }
                            Button("Send by Email…") { collectLogs(LogExport.sendByEmail) }
                        }
                        .disabled(isCollectingLogs)
                    }
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Group {
                    if settings.collectsLogs {
                        Text("Kept on this Mac only, for the last three days. Nothing leaves it until you send it: as a file, or by email to the developer.")
                    } else {
                        Text("Pawshot writes no log and keeps no stall samples. What macOS has already written stays with it until it clears it, in a few days.")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 380)
    }

    @State private var isCollectingLogs = false

    /// Gathering three days of log takes a few seconds; both buttons wait for it.
    private func collectLogs(_ action: @escaping @MainActor () async -> Void) {
        isCollectingLogs = true
        Task {
            await action()
            isCollectingLogs = false
        }
    }
}

/// Where shots go and how the editor draws on them. The font list, a few hundred families long,
/// opens from a button: it is changed rarely and used to take 180 pt of the tab for good.
private struct ScreenshotSettings: View {
    @Bindable private var settings = Settings.shared
    @State private var isPickingFont = false

    private static var logger: Logger {
        .pawshot("settings")
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    HStack {
                        Text(verbatim: settings.saveFolderName)
                            .foregroundStyle(.secondary)
                            .help(settings.saveFolder.path)
                        Button("Choose…", action: chooseSaveFolder)
                    }
                } label: {
                    Label("Save To", systemImage: "folder")
                }
                Picker(selection: $settings.imageFormat) {
                    ForEach(ImageFormat.allCases, id: \.self) { format in
                        Text(verbatim: format.name).tag(format)
                    }
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Screenshot Format")
                            Text("PNG keeps every pixel. JPEG and HEIC are several times smaller.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "photo")
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Saving")
            } footer: {
                Text("⌘S puts shots and videos here; ⇧⌘S picks a name, a folder and a format just once.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent {
                    Button {
                        isPickingFont = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(verbatim: settings.labelFontFamily ?? String(localized: "System"))
                            Image(systemName: "chevron.up.chevron.down")
                                .imageScale(.small)
                        }
                    }
                    .popover(isPresented: $isPickingFont, arrowEdge: .trailing) {
                        LabelFontPicker(selection: $settings.labelFontFamily)
                            .padding(12)
                            .frame(width: 280)
                    }
                } label: {
                    Label("Label font", systemImage: "textformat")
                }
                LabelFontPreview(family: settings.labelFontFamily)
                Picker(selection: $settings.toolsPlacement) {
                    Text("Under the shot").tag(ToolsPlacement.below)
                    Text("Over the shot").tag(ToolsPlacement.overlay)
                } label: {
                    Label("Tools and colours", systemImage: "paintpalette")
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Editor")
            } footer: {
                Text("The font and the panel change at once, in open editors too. Over the shot, drag the panel's edge to resize it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
    }

    private func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveFolder
        panel.prompt = String(localized: "Choose")
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                Self.logger.notice("save folder: panel cancelled")
                return
            }
            Settings.shared.saveFolder = url
        }
    }
}

/// The labels' family: any font installed on the Mac, each name set in its own face, with the
/// system font first and a search field over the few hundred there are.
private struct LabelFontPicker: View {
    @Binding var selection: String?
    @State private var query = ""

    private let families = NSFontManager.shared.availableFontFamilies

    private var matches: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return families }
        return families.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search fonts", text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if query.isEmpty {
                        row(nil)
                    }
                    ForEach(matches, id: \.self) { family in
                        row(family)
                    }
                }
            }
            .frame(height: 300)
            .background(RoundedRectangle(cornerRadius: 8).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.12), lineWidth: 1))
        }
    }

    private func row(_ family: String?) -> some View {
        let isOn = selection == family
        return Button {
            selection = family
        } label: {
            HStack {
                Text(family ?? String(localized: "System"))
                    .font(Font(LabelFont.font(size: 15, weight: .regular, family: family)))
                    .lineLimit(1)
                Spacer()
                if isOn {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Tokens.paw)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isOn ? Tokens.paw.opacity(0.12) : .clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A strip of a light screenshot with a label on it, the way it lands on a shot — plain and on a
/// plate — in the chosen family at the default size and weight.
private struct LabelFontPreview: View {
    let family: String?

    var body: some View {
        let font = Font(LabelFont.font(size: 17, weight: .semibold, family: family))
        let sample = String(localized: "Wrong total — $42!")
        return VStack(alignment: .leading, spacing: 8) {
            Text(sample)
                .font(font)
                .foregroundStyle(Color(nsColor: .systemRed))
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
            Text(sample)
                .font(font)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color(nsColor: .systemRed)))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.97)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.1), lineWidth: 1))
        .environment(\.colorScheme, .light)
        .accessibilityHidden(true)
    }
}

/// Everything about a recording in one place: what gets recorded, what gets drawn into the video
/// afterwards, and how big it comes out — the owner's З-C of 2026-09-29. These are only what every
/// take starts with, so each row names the key that changes it for one take; the long
/// explanations sit in the rows' tooltips.
///
/// The access rows re-check themselves every second — the answer changes in System Settings,
/// not here — and show up only for a switch that needs them.
private struct RecordingSettings: View {
    @Bindable private var settings = Settings.shared

    private static var logger: Logger {
        .pawshot("settings")
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Form {
                profiles
                sound
                shownInTheVideo
                quality
            }
            .formStyle(.grouped)
        }
        .frame(height: 520)
    }

    private var profiles: some View {
        Section {
            Picker(selection: profileBinding) {
                // What the settings below add up to when they match none; not something to pick.
                Text("Custom").tag(RecordingProfile?.none).disabled(true)
                ForEach(RecordingProfile.allCases) { profile in
                    Text(verbatim: "\(profile.title) · \(profile.summary)").tag(Optional(profile))
                }
            } label: {
                title(
                    "Profile",
                    subtitle: "Sets the sound, clicks, resolution and format below in one go",
                    icon: "slider.horizontal.3",
                    hint: KeyHint(key: "P", place: "overlay")
                )
            }
        }
    }

    private var profileBinding: Binding<RecordingProfile?> {
        Binding(
            get: { RecordingProfile.current(in: settings) },
            set: { picked in
                guard let picked else { return }
                Self.logger.notice("profile \(picked.rawValue, privacy: .public) picked in Settings")
                picked.apply(to: settings)
            }
        )
    }

    private var sound: some View {
        Section {
            Group {
                Toggle(isOn: $settings.recordsSystemAudio) {
                    title("Record what the Mac plays", icon: "speaker.wave.2", hint: KeyHint(key: "S", place: "overlay"))
                }
                Toggle(isOn: microphoneBinding) {
                    title(
                        "Record the microphone",
                        subtitle: "Shows its level before you start",
                        icon: "mic",
                        hint: KeyHint(key: "M", place: "overlay")
                    )
                }
            }
            .help(Text("""
            The Mac's sound is videos, calls and notifications. With the microphone on, Options on \
            the recording toolbar show its level before you start; if it stays silent for a second \
            and a half, it says "no signal" and a line above the toolbar says so too. Both end up \
            mixed into one track.
            """))
            if settings.recordsMicrophone {
                accessRow(
                    "Microphone access",
                    granted: MicrophonePermission.isGranted,
                    log: "microphone",
                    action: MicrophonePermission.request
                )
            }
        } header: {
            VStack(alignment: .leading, spacing: 10) {
                explanation("What every take starts with. The keys change it for one take.")
                Text("Sound")
            }
        }
    }

    private var shownInTheVideo: some View {
        let help = Text("""
        Drawn in when the video is saved, never while you record. Clicks become orange \
        rings. Shortcuts show as a caption — only combinations with ⌘, ⌥ or ⌃, so plain \
        typing and passwords never appear. Each can still be switched off for one \
        video in the editor.
        """)
        return Section {
            Toggle(isOn: $settings.showsClicks) {
                title("Clicks", icon: "cursorarrow.click", hint: KeyHint(place: "in the editor"))
            }
            .help(help)
            Toggle(isOn: keystrokesBinding) {
                title(
                    "Pressed shortcuts",
                    subtitle: "Only with ⌘, ⌥ or ⌃",
                    icon: "command",
                    hint: KeyHint(place: "in the editor")
                )
            }
            .help(help)
            if settings.showsKeystrokes {
                accessRow(
                    "Input Monitoring access",
                    granted: CGPreflightListenEventAccess(),
                    log: "input monitoring",
                    action: InputMonitoringPermission.request
                )
            }
        } header: {
            Text("Shown in the video")
        }
    }

    private var quality: some View {
        Section {
            Group {
                Picker(selection: $settings.recordsAtNativeResolution) {
                    Text("Retina, 2x").tag(true)
                    Text("Standard, 1x").tag(false)
                } label: {
                    title("Resolution", icon: "square.resize", hint: KeyHint(key: "X", place: "overlay"))
                }
                Picker(selection: $settings.videoPreset) {
                    ForEach(VideoPreset.allCases, id: \.self) { preset in
                        Text(preset.title).tag(preset)
                    }
                } label: {
                    title("Save and copy as", icon: "film", hint: KeyHint(key: "P", place: "in the editor"))
                }
                Picker(selection: $settings.recordingGoal) {
                    Text("No length in mind").tag(TimeInterval(0))
                    Text("30 seconds").tag(TimeInterval(30))
                    Text("1 minute").tag(TimeInterval(60))
                    Text("2 minutes").tag(TimeInterval(120))
                    Text("5 minutes").tag(TimeInterval(300))
                } label: {
                    title(
                        "Aim for",
                        subtitle: "The pill shows the time against it. The take is never stopped.",
                        icon: "timer",
                        hint: nil
                    )
                }
            }
            .help(Text("""
            A 1x video is about four times smaller, with softer text. X switches it on the \
            recording overlay; P switches the format in the video editor.
            """))
        } header: {
            Text("Quality")
        }
    }

    /// A row's title, an optional line under it, and at its right end the key that changes it
    /// for one take.
    private func title(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        icon: String,
        hint: KeyHint?
    ) -> some View {
        Label {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                hint
            }
        } icon: {
            Image(systemName: icon)
        }
    }

    private func explanation(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "Microphone access — Allowed", or a button to get there.
    private func accessRow(
        _ title: LocalizedStringKey,
        granted: Bool,
        log: StaticString,
        action: @escaping () -> Void
    ) -> some View {
        LabeledContent {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Allow…") {
                    Self.logger.notice("settings: allow \(log, privacy: .public)")
                    action()
                }
            }
        } label: {
            Text(title)
                .foregroundStyle(.secondary)
                .padding(.leading, 28)
        }
    }

    /// The same for Input Monitoring: asked for when the switch goes on, not in the middle of a
    /// take.
    private var keystrokesBinding: Binding<Bool> {
        Binding {
            settings.showsKeystrokes
        } set: { isOn in
            settings.showsKeystrokes = isOn
            if isOn, !CGPreflightListenEventAccess() {
                Self.logger.notice("input monitoring: asked for (shortcut captions on)")
                _ = CGRequestListenEventAccess()
            }
        }
    }

    /// Turning the microphone on is the moment to ask for it — not the first recording, where the
    /// system prompt would land on top of the take.
    private var microphoneBinding: Binding<Bool> {
        Binding {
            settings.recordsMicrophone
        } set: { isOn in
            settings.recordsMicrophone = isOn
            guard isOn else { return }
            Task { _ = await MicrophonePermission.resolve(wanted: true) }
        }
    }
}

/// A grey pill: the key that changes a setting for one take, and where it works.
private struct KeyHint: View {
    var key: String?
    let place: LocalizedStringKey

    var body: some View {
        HStack(spacing: 4) {
            if let key {
                Text(verbatim: key)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.background))
            }
            Text(place)
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(.quaternary))
        .accessibilityElement(children: .combine)
    }
}

/// A cheat sheet: each shortcut a card with big caps and its action's name under them, a click on
/// the card records a new one — the owner's Ш-C of 2026-09-29. A combination macOS takes first
/// says so on its own card, with a way to fix it there.
private struct ShortcutSettings: View {
    private let settings = Settings.shared
    @State private var isConfirmingReset = false

    /// `log` names the action in English for the log, whatever the interface speaks.
    private typealias Row = (title: LocalizedStringResource, log: String, keyPath: ReferenceWritableKeyPath<Settings, HotKeyBinding?>)

    private static let screenshotRows: [Row] = [
        ("Capture region", "capture a region", \.regionHotKey),
        ("Capture full screen", "capture the full screen", \.fullScreenHotKey),
    ]

    /// Pressed again while a take runs, either one stops it.
    private static let recordingRows: [Row] = [
        ("Record region", "record a region", \.recordRegionHotKey),
        ("Record full screen", "record the full screen", \.recordFullScreenHotKey),
    ]

    /// Live only during a take, so they can be anything that doesn't clash with the rest.
    private static let duringRecordingRows: [Row] = [
        ("Pen on / off", "switch the pen", \.penHotKey),
        ("Restart", "restart the take", \.restartHotKey),
        ("Cut the last 10 seconds", "mark a bad take", \.badTakeHotKey),
        ("Hold: spotlight", "hold the spotlight", \.spotlightHotKey),
        ("Hold: hide the picture", "hold the blur", \.blurHotKey),
        ("Hold: mute the microphone", "hold the mute", \.muteHotKey),
    ]

    private static var rows: [Row] {
        screenshotRows + recordingRows + duringRecordingRows
    }

    var body: some View {
        // Re-read every couple of seconds: the fix happens in System Settings, and the warning
        // should go away while the user is still looking at it.
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let conflicts = conflicts
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Click a shortcut to change it")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults…") {
                        isConfirmingReset = true
                    }
                    .controlSize(.small)
                }
                group("Screenshots", Self.screenshotRows, conflicts: conflicts)
                group("Recording", Self.recordingRows, conflicts: conflicts, footer: "Press the same shortcut again to stop.")
                group("While recording", Self.duringRecordingRows, conflicts: conflicts)
                Spacer(minLength: 0)
            }
            .padding(20)
        }
        // Three rows of cards under "While recording" now, where there were two.
        .frame(height: 460 + HotKeyRecorderView.cardHeight + 8)
        .confirmationDialog("Restore the default shortcuts?", isPresented: $isConfirmingReset) {
            Button("Restore Defaults", role: .destructive) {
                settings.resetHotKeysToDefaults()
            }
        } message: {
            Text("Every shortcut goes back to the one Pawshot came with.")
        }
    }

    private func group(
        _ title: LocalizedStringKey,
        _ rows: [Row],
        conflicts: [(binding: HotKeyBinding, system: SystemScreenshotShortcuts.Shortcut)],
        footer: LocalizedStringKey? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                ForEach(rows, id: \.keyPath) { row in
                    let binding = settings[keyPath: row.keyPath]
                    let system = binding.flatMap { binding in conflicts.first { $0.binding == binding }?.system }
                    RecorderField(
                        binding: binding,
                        title: String(localized: row.title),
                        logName: row.log,
                        systemItem: system.map { "\($0.section) → \($0.name)" },
                        onRecord: { apply($0, to: row) },
                        onClear: { settings[keyPath: row.keyPath] = nil }
                    )
                    .frame(height: HotKeyRecorderView.cardHeight)
                }
            }
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Our shortcuts that macOS still takes for itself — its screenshots, or "Move focus to next
    /// window" — read from the live system preferences: the warning goes away the moment the
    /// system item is unticked.
    private var conflicts: [(binding: HotKeyBinding, system: SystemScreenshotShortcuts.Shortcut)] {
        let system = SystemScreenshotShortcuts.current()
        return settings.allHotKeys.compactMap { binding in
            system.conflict(with: binding).map { (binding, $0) }
        }
    }

    /// The same combination can't do two things — that would leave one of them dead with no way
    /// to tell why.
    private func apply(_ binding: HotKeyBinding, to row: Row) -> Bool {
        let shortcut = binding.logString
        if let holder = Self.rows.first(where: { $0.keyPath != row.keyPath && settings[keyPath: $0.keyPath] == binding }) {
            Self.logger.notice("shortcut for \(row.log, privacy: .public): \(shortcut, privacy: .public) refused, \(holder.log, privacy: .public) has it")
            return false
        }

        settings[keyPath: row.keyPath] = binding
        // Accepted, and still dead: macOS takes it first. The field turns red; the log says why.
        if let system = SystemScreenshotShortcuts.current().conflict(with: binding) {
            Self.logger.error("shortcut for \(row.log, privacy: .public): \(shortcut, privacy: .public) is taken by macOS (item \(system.id, privacy: .public)) — Pawshot won't see it until that is unticked")
        }
        return true
    }

    private static var logger: Logger {
        .pawshot("settings")
    }
}

/// The AppKit recorder as a card of the cheat sheet. The recording logic stays in
/// `HotKeyRecorderView`, where it is tested; this only keeps it in sync and forwards "recording
/// started/stopped" to `AppDelegate` through `Settings.onHotKeyRecordingChange`, so the global
/// hotkeys step aside meanwhile.
private struct RecorderField: NSViewRepresentable {
    private static var logger: Logger {
        .pawshot("settings")
    }

    let binding: HotKeyBinding?
    let title: String
    let logName: String
    /// The macOS item that takes this combination first, `nil` when none does.
    let systemItem: String?
    let onRecord: (HotKeyBinding) -> Bool
    let onClear: () -> Void

    func makeNSView(context _: Context) -> HotKeyRecorderView {
        let view = HotKeyRecorderView(binding: binding)
        view.style = .card
        view.onRecordingChange = { isRecording in
            Settings.shared.onHotKeyRecordingChange?(isRecording)
        }
        view.onFix = {
            guard let url = SystemScreenshotShortcuts.settingsURL else {
                Self.logger.error("shortcut field: Fix… has no Keyboard Shortcuts URL to open")
                return
            }
            NSWorkspace.shared.open(url)
        }
        return view
    }

    func updateNSView(_ view: HotKeyRecorderView, context _: Context) {
        view.binding = binding
        view.title = title
        view.logName = logName
        view.isTakenBySystem = systemItem != nil
        view.systemItemHelp = systemItem
        view.onRecord = onRecord
        view.onClear = onClear
    }
}
