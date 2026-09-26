import AppKit
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
        }
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    @Bindable private var settings = Settings.shared

    var body: some View {
        Form {
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
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: 220)
    }
}

/// Everything about a recording in one place, each group with a line of plain words under it:
/// what gets recorded, what gets drawn into the video afterwards, and how big it comes out.
///
/// The access rows re-check themselves every second — the answer changes in System Settings,
/// not here — and show up only for a switch that needs them.
private struct RecordingSettings: View {
    @Bindable private var settings = Settings.shared

    private static let microphoneSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    )
    private static let inputMonitoringURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    )

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
                    action: requestMicrophone
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
                    action: requestInputMonitoring
                )
            }
            Toggle(isOn: $settings.showsZooms) {
                Label("Zooms", systemImage: "plus.magnifyingglass")
            }
        } header: {
            Text("Shown in the video")
        } footer: {
            explanation("""
            Drawn in when the video is saved, never while you record. Clicks become orange \
            rings. Shortcuts show as a caption — only combinations with ⌘, ⌥ or ⌃, so plain \
            typing and passwords never appear. Zooms go wherever you pressed \
            \(settings.zoomMarkHotKey.displayString) while recording. Each can still be switched \
            off for one video in the editor.
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

    private func requestMicrophone() {
        if MicrophonePermission.status == .notDetermined {
            Task { _ = await MicrophonePermission.resolve(wanted: true) }
        } else if let url = Self.microphoneSettingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    private func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        if let url = Self.inputMonitoringURL {
            NSWorkspace.shared.open(url)
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

    private static let keyboardSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
    )

    private typealias Row = (title: LocalizedStringKey, keyPath: ReferenceWritableKeyPath<Settings, HotKeyBinding>)

    private static let screenshotRows: [Row] = [
        ("Capture region", \.regionHotKey),
        ("Capture full screen", \.fullScreenHotKey),
    ]

    /// Pressed again while a take runs, either one stops it.
    private static let recordingRows: [Row] = [
        ("Record region", \.recordRegionHotKey),
        ("Record full screen", \.recordFullScreenHotKey),
    ]

    /// Live only during a take, so they can be anything that doesn't clash with the rest.
    private static let duringRecordingRows: [Row] = [
        ("Zoom in here", \.zoomMarkHotKey),
        ("Pen on / off", \.penHotKey),
        ("Restart", \.restartHotKey),
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
            }
            .formStyle(.grouped)
        }
        .frame(height: 580)
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
                    isTakenBySystem: conflicts.contains { $0.binding == binding }
                ) { apply($0, to: row.keyPath) }
            }
        }
    }

    /// Our shortcuts that macOS still takes for its own screenshots, read from the live system
    /// preferences — the warning goes away the moment the system item is unticked.
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
                Text("macOS takes \(taken) for its own screenshots, so Pawshot never sees the key.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.callout)

            VStack(alignment: .leading, spacing: 2) {
                Text("Keyboard Shortcuts… → Screenshots, then untick:")
                ForEach(conflicts, id: \.system.id) { conflict in
                    Text("• \(conflict.system.name)")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            Button("Open Keyboard Shortcuts") {
                if let url = Self.keyboardSettingsURL {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
    }

    /// The same combination can't do two things — that would leave one of them dead with no way
    /// to tell why.
    private func apply(
        _ binding: HotKeyBinding,
        to keyPath: ReferenceWritableKeyPath<Settings, HotKeyBinding>
    ) -> Bool {
        let others = Self.rows.map(\.keyPath).filter { $0 != keyPath }.map { settings[keyPath: $0] }
        guard !others.contains(binding) else { return false }

        settings[keyPath: keyPath] = binding
        return true
    }
}

/// The AppKit recorder inside the form. The recording logic stays in `HotKeyRecorderView`, where it
/// is tested; this only keeps it in sync and forwards "recording started/stopped" to `AppDelegate`
/// through `Settings.onHotKeyRecordingChange`, so the global hotkeys step aside meanwhile.
private struct RecorderField: NSViewRepresentable {
    let binding: HotKeyBinding
    let isTakenBySystem: Bool
    let onRecord: (HotKeyBinding) -> Bool

    func makeNSView(context _: Context) -> HotKeyRecorderView {
        let view = HotKeyRecorderView(binding: binding)
        view.onRecordingChange = { isRecording in
            Settings.shared.onHotKeyRecordingChange?(isRecording)
        }
        return view
    }

    func updateNSView(_ view: HotKeyRecorderView, context _: Context) {
        view.binding = binding
        view.isTakenBySystem = isTakenBySystem
        view.onRecord = onRecord
    }
}
