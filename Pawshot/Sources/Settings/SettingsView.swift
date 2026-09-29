import AppKit
import os
import SwiftUI

/// The settings window: a tab in the toolbar per topic, a grouped form in each.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings()
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
    }
}

private struct GeneralSettings: View {
    @Bindable private var settings = Settings.shared

    var body: some View {
        Form {
            about
            Section {
                Toggle("Launch at Login", isOn: LoginItem.menuBinding)
                    .disabled(!LoginItem.isInApplicationsFolder)
                if let hint = LoginItem.hint {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("Warn Before Quitting (⌘Q)", isOn: $settings.warnsBeforeQuitting)
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
            Section {
                Picker("Language", selection: $settings.language) {
                    Text("System").tag(AppLanguage.system)
                    // Each language is named in itself, so it can be found from the other one.
                    Text(verbatim: "English").tag(AppLanguage.english)
                    Text(verbatim: "Русский").tag(AppLanguage.russian)
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
                LabelFontPicker(selection: $settings.labelFontFamily)
                Picker("Tools and colours", selection: $settings.toolsPlacement) {
                    Text("Under the shot").tag(ToolsPlacement.below)
                    Text("Over the shot").tag(ToolsPlacement.overlay)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Editor")
            } footer: {
                Text("The font and the panel change at once, in open editors too. Over the shot, drag the panel's edge to resize it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Save To") {
                    HStack {
                        Text(verbatim: settings.saveFolderName)
                            .foregroundStyle(.secondary)
                            .help(settings.saveFolder.path)
                        Button("Choose…", action: chooseSaveFolder)
                    }
                }
                Picker("Screenshot Format", selection: $settings.imageFormat) {
                    ForEach(ImageFormat.allCases, id: \.self) { format in
                        Text(verbatim: format.name).tag(format)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Saving")
            } footer: {
                Text("⌘S puts shots and videos here; ⇧⌘S picks a name, a folder and a format just once. PNG keeps every pixel, JPEG and HEIC are several times smaller.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Collect Logs", isOn: LogExport.collectingBinding)
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
        .frame(height: 720)
    }

    private func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveFolder
        panel.prompt = String(localized: "Choose")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Settings.shared.saveFolder = url
        }
    }

    /// What is running and whose it is — first, so it is there without scrolling.
    private var about: some View {
        Section {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pawshot")
                        .font(.headline)
                    Text("Version \(AboutPanel.versionLine)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } footer: {
            HStack(spacing: 6) {
                Text(verbatim: AboutPanel.copyright)
                Text(verbatim: "·")
                if let mail = URL(string: "mailto:\(AboutPanel.contactEmail)") {
                    Link(AboutPanel.contactEmail, destination: mail)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
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

/// The labels' family: any font installed on the Mac, each name set in its own face, with the
/// system font first and a search field over the few hundred there are. Under the list, a label
/// the way it lands on a shot — plain and on a plate — in the chosen family.
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
            .frame(height: 180)
            .background(RoundedRectangle(cornerRadius: 8).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.12), lineWidth: 1))
            preview
        }
        .padding(.vertical, 4)
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

    /// A strip of a light screenshot with a label on it, in the chosen family at the default size
    /// and weight.
    private var preview: some View {
        let font = Font(LabelFont.font(size: 17, weight: .semibold, family: selection))
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

/// Everything about a recording in one place, each group with a line of plain words under it:
/// what gets recorded, what gets drawn into the video afterwards, and how big it comes out.
///
/// The access rows re-check themselves every second — the answer changes in System Settings,
/// not here — and show up only for a switch that needs them.
private struct RecordingSettings: View {
    @Bindable private var settings = Settings.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Form {
                sound
                shownInTheVideo
                quality
            }
            .formStyle(.grouped)
        }
        .frame(height: 600)
    }

    private var sound: some View {
        Section {
            Toggle(isOn: $settings.recordsSystemAudio) {
                Label("Record what the Mac plays", systemImage: "speaker.wave.2")
            }
            Toggle(isOn: microphoneBinding) {
                Label("Record the microphone", systemImage: "mic")
            }
            if settings.recordsMicrophone {
                accessRow(
                    "Microphone access",
                    granted: MicrophonePermission.isGranted,
                    action: MicrophonePermission.request
                )
            }
        } header: {
            Text("Sound")
        } footer: {
            explanation("""
            The Mac's sound is videos, calls and notifications. With the microphone on, the bar \
            under the area shows its level before you start, and if it stays silent for a second \
            and a half it turns red and says "no signal". Both end up mixed into one track.
            """)
        }
    }

    private var shownInTheVideo: some View {
        Section {
            Toggle(isOn: $settings.showsClicks) {
                Label("Clicks", systemImage: "cursorarrow.click")
            }
            Toggle(isOn: keystrokesBinding) {
                Label("Pressed shortcuts", systemImage: "command")
            }
            if settings.showsKeystrokes {
                accessRow(
                    "Input Monitoring access",
                    granted: CGPreflightListenEventAccess(),
                    action: InputMonitoringPermission.request
                )
            }
            Toggle(isOn: $settings.showsZooms) {
                Label("Zooms", systemImage: "plus.magnifyingglass")
            }
        } header: {
            Text("Shown in the video")
        } footer: {
            // Only the zoom sentence depends on the shortcut; the rest is written once.
            let zooms = settings.zoomMarkHotKey.map {
                String(localized: "Zooms go wherever you pressed \($0.displayString) while recording.")
            } ?? String(localized: "Zooms go wherever you pressed the magnifier on the pill while recording.")
            explanation("""
            Drawn in when the video is saved, never while you record. Clicks become orange \
            rings. Shortcuts show as a caption — only combinations with ⌘, ⌥ or ⌃, so plain \
            typing and passwords never appear. \(zooms) Each can still be switched off for one \
            video in the editor.
            """)
        }
    }

    private var quality: some View {
        Section {
            Picker(selection: $settings.recordsAtNativeResolution) {
                Text("Retina, 2x").tag(true)
                Text("Standard, 1x").tag(false)
            } label: {
                Label("Resolution", systemImage: "square.resize")
            }
            Picker(selection: $settings.videoPreset) {
                ForEach(VideoPreset.allCases, id: \.self) { preset in
                    Text(preset.title).tag(preset)
                }
            } label: {
                Label("Save and copy as", systemImage: "film")
            }
        } header: {
            Text("Quality")
        } footer: {
            explanation("""
            A 1x video is about four times smaller, with softer text. X switches it on the \
            recording overlay; P switches the format in the video editor.
            """)
        }
    }

    private func explanation(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "Microphone access — Allowed", or a button to get there.
    private func accessRow(_ title: LocalizedStringKey, granted: Bool, action: @escaping () -> Void) -> some View {
        LabeledContent {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Allow…", action: action)
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

private struct ShortcutSettings: View {
    private let settings = Settings.shared
    @State private var isConfirmingReset = false

    /// `log` names the action in English for the log, whatever the interface speaks.
    private typealias Row = (title: LocalizedStringKey, log: String, keyPath: ReferenceWritableKeyPath<Settings, HotKeyBinding?>)

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
        ("Zoom in here", "mark a zoom", \.zoomMarkHotKey),
        ("Pen on / off", "switch the pen", \.penHotKey),
        ("Restart", "restart the take", \.restartHotKey),
    ]

    private static var rows: [Row] {
        screenshotRows + recordingRows + duringRecordingRows
    }

    var body: some View {
        // Re-read every couple of seconds: the fix happens in System Settings, and the warning
        // should go away while the user is still looking at it.
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let conflicts = conflicts
            Form {
                Section("Screenshots") {
                    recorderRows(Self.screenshotRows, conflicts: conflicts)
                }
                Section {
                    recorderRows(Self.recordingRows, conflicts: conflicts)
                } header: {
                    Text("Recording")
                } footer: {
                    Text("Press the same shortcut again to stop.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    recorderRows(Self.duringRecordingRows, conflicts: conflicts)
                } header: {
                    Text("While recording")
                } footer: {
                    if !conflicts.isEmpty {
                        systemShortcutWarning(conflicts)
                    }
                }
                Section {
                    HStack {
                        Spacer()
                        Button("Restore Defaults…") {
                            isConfirmingReset = true
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(height: 580)
        .confirmationDialog("Restore the default shortcuts?", isPresented: $isConfirmingReset) {
            Button("Restore Defaults", role: .destructive) {
                settings.resetHotKeysToDefaults()
            }
        } message: {
            Text("Every shortcut goes back to the one Pawshot came with.")
        }
    }

    private func recorderRows(
        _ rows: [Row],
        conflicts: [(binding: HotKeyBinding, system: SystemScreenshotShortcuts.Shortcut)]
    ) -> some View {
        ForEach(rows, id: \.keyPath) { row in
            let binding = settings[keyPath: row.keyPath]
            LabeledContent(row.title) {
                RecorderField(
                    binding: binding,
                    logName: row.log,
                    isTakenBySystem: binding.map { binding in conflicts.contains { $0.binding == binding } } ?? false,
                    onRecord: { apply($0, to: row) },
                    onClear: { settings[keyPath: row.keyPath] = nil }
                )
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

    private func systemShortcutWarning(
        _ conflicts: [(binding: HotKeyBinding, system: SystemScreenshotShortcuts.Shortcut)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let taken = conflicts.map(\.binding.displayString).joined(separator: ", ")
            Label {
                Text("macOS takes \(taken) for itself, so Pawshot never sees the key.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.callout)

            VStack(alignment: .leading, spacing: 2) {
                Text("Pick another shortcut, or untick in Keyboard Shortcuts…:")
                // One line per system item: "Move focus to next window" can hold two of ours, ⌘1
                // and ⇧⌘1.
                ForEach(SystemScreenshotShortcuts.unique(conflicts.map(\.system)), id: \.id) { item in
                    Text("• \(item.section) → \(item.name)")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            Button("Open Keyboard Shortcuts") {
                if let url = SystemScreenshotShortcuts.settingsURL {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
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

/// The AppKit recorder inside the form. The recording logic stays in `HotKeyRecorderView`, where it
/// is tested; this only keeps it in sync and forwards "recording started/stopped" to `AppDelegate`
/// through `Settings.onHotKeyRecordingChange`, so the global hotkeys step aside meanwhile.
private struct RecorderField: NSViewRepresentable {
    let binding: HotKeyBinding?
    let logName: String
    let isTakenBySystem: Bool
    let onRecord: (HotKeyBinding) -> Bool
    let onClear: () -> Void

    func makeNSView(context _: Context) -> HotKeyRecorderView {
        let view = HotKeyRecorderView(binding: binding)
        view.onRecordingChange = { isRecording in
            Settings.shared.onHotKeyRecordingChange?(isRecording)
        }
        return view
    }

    func updateNSView(_ view: HotKeyRecorderView, context _: Context) {
        view.binding = binding
        view.logName = logName
        view.isTakenBySystem = isTakenBySystem
        view.onRecord = onRecord
        view.onClear = onClear
    }
}
