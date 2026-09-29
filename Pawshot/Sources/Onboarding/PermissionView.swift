import AppKit
import AVFoundation
import os
import SwiftUI

/// Shown on the first capture that runs into missing screen recording access — never at launch:
/// the app asks for nothing before the user has asked it to capture.
///
/// An ordinary AppKit window around a SwiftUI view rather than a scene: `AppDelegate` opens it from
/// the capture path, where there is no SwiftUI environment to call `openWindow` from.
@MainActor
final class PermissionWindowController: NSWindowController, NSWindowDelegate {
    private static var current: PermissionWindowController?

    private static var logger: Logger {
        .pawshot("permission")
    }

    static func show() {
        let reused = current != nil
        let wasActive = NSApp.isActive
        logger.notice("permission window shown: reused \(reused, privacy: .public), app was active \(wasActive, privacy: .public)")
        let controller = current ?? PermissionWindowController()
        current = controller
        controller.window?.center()
        NSApp.activate()
        controller.showWindow(nil)
        // Activation of a background utility may be refused (macOS 14+ is cooperative), and the
        // window then opens behind the app in front — the hotkey looks like it did nothing.
        controller.window?.orderFrontRegardless()
    }

    private convenience init() {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.title = String(localized: "Screen Recording")
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: PermissionView())
        self.init(window: window)
        window.delegate = self
    }

    func windowWillClose(_: Notification) {
        let granted = ScreenRecordingPermission.isGranted
        Self.logger.notice("permission window closed: screen recording granted \(granted, privacy: .public)")
        Self.current = nil
    }
}

struct PermissionView: View {
    private static var logger: Logger {
        .pawshot("permission")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Let Pawshot see the screen")
                    .font(.title2.bold())
                Text("""
                macOS asks every app that captures the screen for permission. \
                Turn Pawshot on in Privacy & Security → Screen & System Audio Recording.
                """)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(spacing: 8) {
                        statusRow(granted: ScreenRecordingPermission.isGranted)
                        // Only when the microphone is on: nobody should be asked for a permission
                        // they have no use for.
                        if Settings.shared.recordsMicrophone {
                            microphoneRow(status: MicrophonePermission.status)
                        }
                        if Settings.shared.showsKeystrokes {
                            inputMonitoringRow(granted: InputMonitoringPermission.isGranted)
                        }
                    }
                }

                Text("macOS asks again from time to time. That is the system, not Pawshot misbehaving.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 300)

            dragCard
        }
        .padding(.horizontal, 24)
        .padding(.top, 36)
        .padding(.bottom, 24)
    }

    private func statusRow(granted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "arrow.right.circle.fill")
                .font(.title3)
                .foregroundStyle(granted ? Color.green : Tokens.paw)
                .contentTransition(.symbolEffect(.replace))
            Text(granted ? "Screen Recording is allowed" : "Screen Recording")
                .font(.headline)
            Spacer()
            if granted {
                // The permission reaches a running process late or not at all; a fresh process
                // always sees it.
                Button("Relaunch Pawshot", action: Self.relaunch)
                    .buttonStyle(.glassProminent)
                    .tint(Tokens.paw)
            } else {
                Button("Open System Settings") {
                    guard let url = ScreenRecordingPermission.settingsURL else {
                        Self.logger.error("permission window: no System Settings URL to open")
                        return
                    }
                    Self.logger.notice("permission window: opening System Settings")
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.glass)
                // The grant may never reach this process, and then the row would stay "not
                // allowed" with no way out: relaunching is always on offer.
                Button("Relaunch", action: Self.relaunch)
                    .buttonStyle(.glass)
            }
        }
        .padding(12)
        .background(.quaternary, in: .rect(cornerRadius: Tokens.Radius.row))
        .animation(.easeOut(duration: Tokens.Motion.enter), value: granted)
    }

    private func microphoneRow(status: AVAuthorizationStatus) -> some View {
        let granted = status == .authorized
        return HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "mic.circle.fill")
                .font(.title3)
                .foregroundStyle(granted ? Color.green : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
            Text(granted ? "Microphone is allowed" : "Microphone")
                .font(.headline)
            Spacer()
            if status == .notDetermined {
                Button("Allow", action: MicrophonePermission.request)
                    .buttonStyle(.glass)
            } else if !granted {
                Button("Open System Settings", action: MicrophonePermission.request)
                    .buttonStyle(.glass)
            }
        }
        .padding(12)
        .background(.quaternary, in: .rect(cornerRadius: Tokens.Radius.row))
        .animation(.easeOut(duration: Tokens.Motion.enter), value: granted)
    }

    private func inputMonitoringRow(granted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "keyboard")
                .font(.title3)
                .foregroundStyle(granted ? Color.green : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
            Text(granted ? "Input Monitoring is allowed" : "Input Monitoring — for shortcuts in videos")
                .font(.headline)
            Spacer()
            if !granted {
                Button("Open System Settings", action: InputMonitoringPermission.request)
                    .buttonStyle(.glass)
            }
        }
        .padding(12)
        .background(.quaternary, in: .rect(cornerRadius: Tokens.Radius.row))
        .animation(.easeOut(duration: Tokens.Motion.enter), value: granted)
    }

    /// The app itself as something to drag: dropping it into the list in System Settings adds it
    /// without hunting for it through "+" and Finder.
    private var dragCard: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .draggable(Bundle.main.bundleURL)
                .accessibilityLabel("Pawshot app, drag into the list")
            Text("Drag Pawshot into the list")
                .font(.footnote)
                .multilineTextAlignment(.center)
            Image(systemName: "arrow.down")
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 140)
        .glassEffect(.regular, in: .rect(cornerRadius: Tokens.Radius.panel))
    }

    /// Also the settings window's "Relaunch" after a language change: the new process asks this
    /// one to quit through `replaceOlderInstances`, and this one quits on its own besides.
    static func relaunch() {
        logger.notice("relaunch asked")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            // Called on a queue of its own: only a string crosses to the main actor.
            let failure = error.map { String(describing: $0) }
            Task { @MainActor in
                if let failure {
                    Self.logger.error("relaunch: new copy not started: \(failure, privacy: .public)")
                }
                NSApp.terminate(nil)
            }
        }
    }
}
