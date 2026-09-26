import AppKit
import SwiftUI

/// What the menu can ask the app to do. The capture and recording pipelines live in
/// `AppDelegate`; the menu only knows these entry points.
struct CaptureActions {
    var captureRegion: @MainActor () -> Void
    var captureFullScreen: @MainActor () -> Void
    var recordRegion: @MainActor () -> Void
    var recordFullScreen: @MainActor () -> Void
    var stopRecording: @MainActor () -> Void
    var togglePause: @MainActor () -> Void
    var restartRecording: @MainActor () -> Void
}

/// The menu under the paw.
///
/// Icons sit on the capture actions only: an icon on every row turns a short menu into a column
/// of pictures nobody reads, and "Quit" has nothing to gain from one. The shortcut column on the
/// right is the global hotkey, printed for reference — pressing it anywhere captures, the menu
/// doesn't need to be open.
struct CaptureMenu: View {
    let actions: CaptureActions

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    private let settings = Settings.shared
    private let state = AppState.shared

    var body: some View {
        // A menu-style menu bar item can't stop on a plain click, so while a take runs, stopping
        // is the first thing the menu offers.
        if let recording = state.recording {
            Section("Recording · \(recording.elapsedText)") {
                Button("Stop Recording", systemImage: "stop.fill") {
                    actions.stopRecording()
                }
                // The shortcut that started a take stops it; ⇧⌘3 is the one shown.
                .keyboardShortcut(settings.recordRegionHotKey.keyboardShortcut)

                Button("Restart Recording", systemImage: "arrow.counterclockwise") {
                    actions.restartRecording()
                }
                .keyboardShortcut(settings.restartHotKey.keyboardShortcut)

                Button(
                    recording.isPaused ? "Resume Recording" : "Pause Recording",
                    systemImage: recording.isPaused ? "play.fill" : "pause.fill"
                ) {
                    actions.togglePause()
                }
            }

            Divider()
        }

        Section("Capture") {
            Button("Capture Region", systemImage: "rectangle.dashed") {
                actions.captureRegion()
            }
            .keyboardShortcut(settings.regionHotKey.keyboardShortcut)

            Button("Capture Full Screen", systemImage: "display") {
                actions.captureFullScreen()
            }
            .keyboardShortcut(settings.fullScreenHotKey.keyboardShortcut)
        }

        if state.recording == nil {
            Section("Record") {
                Button("Record Region", systemImage: "rectangle.dashed.badge.record") {
                    actions.recordRegion()
                }
                .keyboardShortcut(settings.recordRegionHotKey.keyboardShortcut)

                Button("Record Full Screen", systemImage: "menubar.dock.rectangle.badge.record") {
                    actions.recordFullScreen()
                }
                .keyboardShortcut(settings.recordFullScreenHotKey.keyboardShortcut)
            }
        }

        Divider()

        // Read on every render instead of cached: launch at login can be switched off in System
        // Settings → General → Login Items, and the checkmark has to show it.
        Toggle("Launch at Login", isOn: LoginItem.menuBinding)
            .disabled(!LoginItem.isInApplicationsFolder)

        Button("Open Pawshot") {
            NSApp.activate()
            openWindow(id: WindowID.welcome)
        }

        Button("Settings…") {
            // An accessory app is never active on its own: without this the window opens behind
            // whatever was in front.
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")

        Button("About Pawshot") {
            NSApp.activate()
            openWindow(id: WindowID.about)
        }

        Divider()

        Button("Quit Pawshot") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

/// The paw itself, switching with what the app is doing.
struct MenuBarLabel: View {
    private let state = AppState.shared

    var body: some View {
        // While recording the paw gives way to the dot and the time: the one thing worth a glance
        // at the menu bar in the middle of a take.
        if let recording = state.recording {
            Image(systemName: recording.isPaused ? "pause.circle.fill" : "record.circle.fill")
            Text(recording.elapsedText)
                .monospacedDigit()
        } else {
            Image(nsImage: icon)
        }
    }

    private var icon: NSImage {
        if state.isCapturing {
            return MenuBarIcon.capturing
        }
        if state.textJustCopied {
            return MenuBarIcon.textCopied
        }
        return MenuBarIcon.normal
    }
}

enum WindowID {
    static let welcome = "welcome"
    static let about = "about"
}
