import AppKit
import SwiftUI

/// The welcome window: it opens by itself at launch until "Get Started" is pressed, and from the
/// paw's "Open Pawshot" after that. The owner picked the layout (W-C) on 2026-09-28: the four main
/// shortcuts on the left, as they are set right now; on the right every access Pawshot can use,
/// each read live, with a button to it. Nothing is asked for until one of those is pressed.
struct WelcomeView: View {
    private let settings = Settings.shared
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismissWindow) private var dismissWindow
    /// The first "Allow…" shows the system prompt, and the grant may reach this process late or
    /// never — so from then on a relaunch is on offer too, as in the permission window.
    @State private var askedForScreenRecording = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            shortcuts
            // The answers change in System Settings, not here.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                access
            }
        }
        .padding(12)
        .frame(width: 860)
        .background(ComesForward("welcome"))
    }

    // MARK: - Shortcuts

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 76, height: 76)
                    .accessibilityHidden(true)
                Text("Pawshot")
                    .font(.largeTitle.bold())
                Text("It lives in the menu bar and waits for a shortcut.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                shortcut("Capture a region", settings.regionHotKey)
                shortcut("Capture the full screen", settings.fullScreenHotKey)
                shortcut("Record a region", settings.recordRegionHotKey)
                shortcut("Record the full screen", settings.recordFullScreenHotKey)
            }

            Button("Change Shortcuts…") {
                NSApp.activate()
                openSettings()
            }
            .buttonStyle(.glass)
        }
        // The title bar is hidden, and the window's buttons sit over the top of this panel.
        .padding(.horizontal, 28)
        .padding(.top, 44)
        .padding(.bottom, 28)
        .frame(width: 320, alignment: .leading)
        .frame(maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: Tokens.Radius.panel))
    }

    private func shortcut(_ title: LocalizedStringKey, _ binding: HotKeyBinding) -> some View {
        LabeledContent(title) {
            KeyCaps(caps: binding.keyCaps)
        }
    }

    // MARK: - Access

    private var access: some View {
        let screenRecording = ScreenRecordingPermission.isGranted
        let microphone = MicrophonePermission.isGranted
        let inputMonitoring = InputMonitoringPermission.isGranted
        let takenBySystem = takenBySystem
        let allowed = [screenRecording, microphone, inputMonitoring, takenBySystem.isEmpty].count(where: \.self)

        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Access")
                    .font(.title2.bold())
                Text("Only the first one is required. The rest are for videos and can wait.")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                AccessRow(
                    title: Text("Screen Recording"),
                    detail: Text("Without it Pawshot can't see the screen: no screenshots, no videos."),
                    isRequired: true,
                    isGranted: screenRecording
                ) {
                    HStack(spacing: 8) {
                        if askedForScreenRecording {
                            Button("Relaunch", action: PermissionView.relaunch)
                                .buttonStyle(.glass)
                        }
                        Button("Allow…") {
                            ScreenRecordingPermission.request()
                            askedForScreenRecording = true
                        }
                        .buttonStyle(.glass)
                    }
                }
                Divider()
                AccessRow(
                    title: Text("Microphone"),
                    detail: Text("Your voice in videos."),
                    isGranted: microphone
                ) {
                    Button("Allow…", action: MicrophonePermission.request)
                        .buttonStyle(.glass)
                }
                Divider()
                AccessRow(
                    title: Text("Input Monitoring"),
                    detail: Text("Captions of the shortcuts you press in videos, like ⌘Z ×3."),
                    isGranted: inputMonitoring
                ) {
                    Button("Allow…", action: InputMonitoringPermission.request)
                        .buttonStyle(.glass)
                }
                Divider()
                AccessRow(
                    title: Text("Shortcuts \(takenShortcutNames(takenBySystem))"),
                    detail: Text("macOS keeps them for its own screenshots. Untick them in Keyboard Shortcuts → Screenshots."),
                    isGranted: takenBySystem.isEmpty,
                    grantedLabel: "Free"
                ) {
                    Button("Open…") {
                        if let url = SystemScreenshotShortcuts.settingsURL {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.glass)
                }
                Divider()
                AccessRow(
                    title: Text("Launch at Login"),
                    detail: LoginItem.hint.map { Text($0) }
                        ?? Text("The paw is in the menu bar as soon as the Mac starts."),
                    isGranted: false
                ) {
                    Toggle("Launch at Login", isOn: LoginItem.menuBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(!LoginItem.isInApplicationsFolder)
                }
                Divider()
                AccessRow(
                    title: Text("Collect Logs"),
                    detail: Text("Stays on this Mac. If something breaks, Settings → Diagnostics sends them to the developer."),
                    isGranted: false
                ) {
                    Toggle("Collect Logs", isOn: LogExport.collectingBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            Spacer(minLength: 0)

            HStack {
                Text("\(allowed) of 4 allowed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Get Started") {
                    settings.welcomeCompleted = true
                    // A fresh install has nothing to be told about on its next launch.
                    settings.lastSeenVersion = AboutPanel.version
                    dismissWindow(id: WindowID.welcome)
                }
                .buttonStyle(.glassProminent)
                .tint(Tokens.paw)
                .controlSize(.large)
                .disabled(!screenRecording)
            }
        }
        .padding(.leading, 32)
        .padding(.trailing, 28)
        .padding(.top, 30)
        .padding(.bottom, 18)
    }

    /// Our shortcuts that macOS still takes for its screenshots, read from the live preferences —
    /// the row turns "Free" the moment the system item is unticked.
    private var takenBySystem: [HotKeyBinding] {
        let system = SystemScreenshotShortcuts.current()
        return settings.allHotKeys.filter { system.conflict(with: $0) != nil }
    }

    /// The taken ones, or — once they are free — the two recording shortcuts the row is about.
    private func takenShortcutNames(_ taken: [HotKeyBinding]) -> String {
        let shown = taken.isEmpty ? [settings.recordRegionHotKey, settings.recordFullScreenHotKey] : taken
        return shown.map(\.displayString).joined(separator: ", ")
    }
}

/// One access: what it is and why, then either "Allowed" or the way to it.
private struct AccessRow<Action: View>: View {
    let title: Text
    let detail: Text
    var isRequired = false
    let isGranted: Bool
    var grantedLabel: LocalizedStringKey = "Allowed"
    @ViewBuilder let action: Action

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    title
                        .font(.headline)
                    if isRequired {
                        Text("Required")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Tokens.paw)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Tokens.paw.opacity(0.15), in: .capsule)
                    }
                }
                detail
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if isGranted {
                Label(grantedLabel, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                action
            }
        }
        .padding(.vertical, 12)
        .animation(.easeOut(duration: Tokens.Motion.enter), value: isGranted)
    }
}
