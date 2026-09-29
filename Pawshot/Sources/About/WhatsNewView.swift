import AppKit
import SwiftUI

/// The window after an update, the owner's W-C of 2026-09-28: a timeline of every version the
/// person skipped (`WhatsNew.entries`), the current one on top. It opens by itself once per
/// version (`WhatsNew.showsAtLaunch`); shown means seen, however it is closed.
struct WhatsNewView: View {
    private let settings = Settings.shared
    @Environment(\.dismissWindow) private var dismissWindow

    /// Read once. Showing the window records the new version as seen, and a list read afresh
    /// after that would have nothing left in it.
    @State private var from = Settings.shared.lastSeenVersion

    var body: some View {
        WhatsNewContent(
            from: from,
            current: AboutPanel.version,
            entries: WhatsNew.entries(in: WhatsNew.history, since: from)
        ) {
            dismissWindow(id: WindowID.whatsNew)
        }
        .background(ComesForward("what's new"))
        .onAppear {
            settings.lastSeenVersion = AboutPanel.version
        }
    }
}

/// What the window shows, apart from the window, so its layout can be measured in a test.
struct WhatsNewContent: View {
    /// The version before the update; `nil` for 0.4.6 and older, which stored none.
    let from: String?
    let current: String
    let entries: [WhatsNew.Entry]
    let onDone: () -> Void

    /// A person back after many versions gets a scrolling list, not a window taller than the
    /// screen of a MacBook Air.
    static let listMaxHeight: CGFloat = 576

    /// The owner asked for a window a fifth taller (2026-09-29). One version's text took 315 pt of
    /// a 526 pt window; 420 makes that window 631. Two versions already fill it.
    static let listMinHeight: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            ScrollView {
                timeline
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(minHeight: Self.listMinHeight, maxHeight: Self.listMaxHeight, alignment: .top)

            Button("Got It", action: onDone)
                .buttonStyle(.glassProminent)
                .tint(Tokens.paw)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 30)
        // The title bar is hidden and its buttons sit over the top left, above the icon.
        .padding(.top, 44)
        .padding(.bottom, 24)
        .frame(width: 440)
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                CornerBrackets(armLength: 11)
                    .bracketStroke(Tokens.paw, width: 2.5)
                    .frame(width: 64, height: 64)

                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 49, height: 49)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("What's New")
                    .font(.title2.bold())
                Group {
                    if let from {
                        Text(verbatim: "\(from) → \(current)")
                    } else {
                        Text("Version \(current)")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            // By version, not by place: a current release with nothing to tell is left out, and
            // the one on top is then an older version.
            ForEach(entries, id: \.version) { entry in
                version(entry, isCurrent: entry.version == current)
            }
            if let from {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Circle()
                        .fill(.tertiary)
                        .frame(width: 8, height: 8)
                        .frame(width: 22)
                    Text("\(from) — your version before the update")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One version: its dot and the line down to the next one, beside its number and text. The
    /// dot and the line are the text's background, so the line is exactly as tall as the text.
    private func version(_ entry: WhatsNew.Entry, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(verbatim: entry.version)
                    .fontWeight(.bold)
                if isCurrent {
                    Text(verbatim: "·")
                        .foregroundStyle(.secondary)
                    Text("now")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .monospacedDigit()

            Text(entry.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 34)
        .padding(.bottom, 20)
        .background(alignment: .topLeading) {
            VStack(spacing: 6) {
                dot(isCurrent: isCurrent)
                    .padding(.top, 4)
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 2)
            }
            .frame(width: 22)
        }
    }

    private func dot(isCurrent: Bool) -> some View {
        Group {
            if isCurrent {
                Circle()
                    .fill(Tokens.paw)
                    .frame(width: 12, height: 12)
                    .background(Circle().fill(Tokens.paw.opacity(0.2)).padding(-4))
            } else {
                Circle()
                    .strokeBorder(Tokens.paw, lineWidth: 2)
                    .frame(width: 10, height: 10)
            }
        }
        .frame(width: 12, height: 12)
    }
}
