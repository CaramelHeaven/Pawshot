import AppKit
import SwiftUI

/// "Open Pawshot" from the menu: what the app does, the shortcuts as they are set right now,
/// whether it may record the screen, and launch at login. Everything on it is live — change a
/// shortcut in Settings and it changes here too.
struct WelcomeView: View {
    private let settings = Settings.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                Text("Pawshot is ready")
                    .font(.title2.bold())
                Text("It lives in the menu bar and waits for a shortcut.")
                    .foregroundStyle(.secondary)
            }

            Form {
                Section {
                    LabeledContent("Capture a region") {
                        KeyCaps(caps: settings.regionHotKey.keyCaps)
                    }
                    LabeledContent("Capture a window") {
                        HStack(spacing: 6) {
                            Text("then")
                                .foregroundStyle(.secondary)
                            KeyCaps(caps: ["Space"])
                        }
                    }
                    LabeledContent("Capture the full screen") {
                        KeyCaps(caps: settings.fullScreenHotKey.keyCaps)
                    }
                } header: {
                    Text("Screenshots")
                }

                Section {
                    LabeledContent("Record a region") {
                        KeyCaps(caps: settings.recordRegionHotKey.keyCaps)
                    }
                    LabeledContent("Record a window") {
                        HStack(spacing: 6) {
                            Text("then")
                                .foregroundStyle(.secondary)
                            KeyCaps(caps: ["Space"])
                        }
                    }
                    LabeledContent("Record the full screen") {
                        KeyCaps(caps: settings.recordFullScreenHotKey.keyCaps)
                    }
                    LabeledContent("Zoom in here, while recording") {
                        KeyCaps(caps: settings.zoomMarkHotKey.keyCaps)
                    }
                    LabeledContent("Pen, while recording") {
                        KeyCaps(caps: settings.penHotKey.keyCaps)
                    }
                    LabeledContent("Restart, while recording") {
                        KeyCaps(caps: settings.restartHotKey.keyCaps)
                    }
                } header: {
                    Text("Recording")
                } footer: {
                    Text("The shortcut that started a recording stops it too.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    PermissionStatusRow()
                    Toggle("Launch at Login", isOn: LoginItem.menuBinding)
                        .disabled(!LoginItem.isInApplicationsFolder)
                    if let hint = LoginItem.hint {
                        Text(hint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 600)

            Button("Change Shortcuts…") {
                openSettings()
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

/// "Screen Recording: allowed / not yet", re-checked every couple of seconds while it is visible:
/// the answer changes in System Settings, not here.
struct PermissionStatusRow: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let granted = ScreenRecordingPermission.isGranted
            LabeledContent("Screen Recording") {
                Label(
                    granted ? "Allowed" : "Not allowed yet",
                    systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle"
                )
                .foregroundStyle(granted ? .green : .orange)
            }
        }
    }
}
