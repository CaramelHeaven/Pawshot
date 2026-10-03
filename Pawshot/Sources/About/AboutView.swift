import AppKit
import os
import SwiftUI

/// The About window: the icon inside the app's frame corners, the version and the count of shots.
/// Clicking the paw makes it hop — the one playful thing in the app, kept where nobody is in a
/// hurry.
struct AboutView: View {
    private let settings = Settings.shared
    @State private var hops = 0

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                CornerBrackets(armLength: 18)
                    .bracketStroke(Tokens.paw, width: 3)
                    .frame(width: 124, height: 124)

                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .rotationEffect(.degrees(hops.isMultiple(of: 2) ? 0 : -8))
                    .scaleEffect(hops.isMultiple(of: 2) ? 1 : 1.06)
                    .animation(Tokens.Motion.arrival, value: hops)
                    .onTapGesture {
                        hops += 1
                        let count = hops
                        Self.logger.notice("about: the paw hopped, \(count) this time")
                    }
                    .accessibilityLabel("Pawshot icon")
            }

            VStack(spacing: 4) {
                Text("Pawshot")
                    .font(.title2.bold())
                Text("Version \(AboutPanel.versionLine)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text(shotsLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            VStack(spacing: 2) {
                Text("Screenshots without a subscription.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                if let url = URL(string: AboutPanel.repositoryURL) {
                    Link(AboutPanel.repositoryURL, destination: url)
                        .font(.footnote)
                        .environment(\.openURL, OpenURLAction { _ in
                            Self.logger.notice("about: repository link opened")
                            return .systemAction
                        })
                }
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 28)
        .padding(.bottom, 24)
        .frame(minWidth: 320)
        .background(ComesForward("about"))
    }

    private static var logger: Logger {
        .pawshot("app")
    }

    private var shotsLine: String {
        switch settings.captureCount {
        case 0: String(localized: "No shots yet")
        case let count: String(localized: "\(count) shots taken")
        }
    }
}
