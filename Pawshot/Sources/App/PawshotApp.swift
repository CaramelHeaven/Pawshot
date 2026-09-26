import AppKit
import SwiftUI

/// The entry point. The capture pipeline, the hotkeys and the editor windows stay with
/// `AppDelegate`; SwiftUI owns the menu bar item, the settings window, the small windows and the
/// main menu.
///
/// `LSUIElement` in Info.plist keeps it a menu bar utility: no Dock icon, no ⌘Tab entry.
@main
struct PawshotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            CaptureMenu(actions: CaptureActions(
                captureRegion: { delegate.beginCapture() },
                captureFullScreen: { delegate.beginFullScreenCapture() },
                recordRegion: { delegate.beginRegionRecording() },
                recordFullScreen: { delegate.beginFullScreenRecording() },
                stopRecording: { delegate.stopRecording() },
                togglePause: { delegate.toggleRecordingPause() },
                restartRecording: { delegate.restartRecording() }
            ))
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.menu)
        .commands {
            AppCommands()
            EditorCommands()
        }

        // `SwiftUI.` because the app has its own `Settings` — the stored preferences.
        SwiftUI.Settings {
            SettingsView()
        }

        Window("Pawshot", id: WindowID.welcome) {
            WelcomeView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("About Pawshot", id: WindowID.about) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

/// "About Pawshot" opens our own window instead of the stock panel.
private struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Pawshot") {
                NSApp.activate()
                openWindow(id: WindowID.about)
            }
        }
    }
}

/// The editor's shortcuts. An accessory app has no visible menu bar, but the items still matter:
/// they are how ⌘S and ⌘D travel down the responder chain to `EditorWindowController`, and how the
/// canvas re-dispatches them on a non-Latin layout (`AnnotationCanvasView.performKeyEquivalent`).
/// ⌘C, ⌘Z and ⌘⇧Z come from the standard Edit menu SwiftUI builds.
private struct EditorCommands: Commands {
    var body: some Commands {
        // SwiftUI's save group also holds Close; replacing the group without it took ⌘W away.
        CommandGroup(replacing: .saveItem) {
            Button("Close Window") {
                send(#selector(NSWindow.performClose(_:)))
            }
            .keyboardShortcut("w")

            Button("Save to Desktop") {
                send(#selector(EditorWindowController.saveDocument(_:)))
            }
            .keyboardShortcut("s")
        }

        CommandGroup(after: .pasteboard) {
            // The video editor's: the recording as a GIF, whatever format is chosen.
            Button("Copy as GIF") {
                send(#selector(VideoEditorWindowController.copyGIF(_:)))
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Divider()
            Button("Copy Text") {
                send(#selector(EditorWindowController.copyText(_:)))
            }
            .keyboardShortcut("d")

            // No key equivalent: a bare "C" in the menu would swallow text input as well. The key
            // lives in the canvas, which knows when text is being typed.
            Button("Clear All") {
                send(#selector(EditorWindowController.clearAll(_:)))
            }
        }
    }

    @MainActor
    private func send(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }
}
