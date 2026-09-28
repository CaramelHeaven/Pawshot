import AppKit
import SwiftUI

/// The window after an update, the owner's N-A of 2026-09-28: the icon in its corner brackets as
/// in About, then `WhatsNew.text` and one button. It opens by itself once per version
/// (`WhatsNew.showsAtLaunch`); shown means seen, however it is closed.
struct WhatsNewView: View {
    private let settings = Settings.shared
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                CornerBrackets(armLength: 16)
                    .bracketStroke(Tokens.paw, width: 3)
                    .frame(width: 92, height: 92)

                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 70, height: 70)
                    .accessibilityHidden(true)
            }

            VStack(spacing: 3) {
                Text("What's New")
                    .font(.title2.bold())
                Text("Version \(AboutPanel.versionLine)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text(WhatsNew.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Button("Got It") {
                dismissWindow(id: WindowID.whatsNew)
            }
            .buttonStyle(.glassProminent)
            .tint(Tokens.paw)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 6)
        }
        .padding(.horizontal, 30)
        .padding(.top, 28)
        .padding(.bottom, 24)
        .frame(width: 440)
        .background(ComesForward("what's new"))
        .onAppear {
            settings.lastSeenVersion = AboutPanel.version
        }
    }
}
