import AppKit
import os
import SwiftUI

/// Puts the window it sits in above every other app's windows once it opens. The welcome window
/// and What's New open by themselves at launch, and a launch from the background — Sparkle's
/// relaunch after an update, a login item — is not activated by macOS: SwiftUI then orders the
/// window front among Pawshot's own only, behind the app in front. 0.4.7's What's New opened
/// there. `NSApp.activate()` may be refused (macOS 14+ activation is cooperative), so
/// `orderFrontRegardless()` does the work, as in `PermissionWindowController`.
struct ComesForward: NSViewRepresentable {
    private let name: String

    /// `name` is for the log only.
    init(_ name: String) {
        self.name = name
    }

    func makeNSView(context _: Context) -> NSView {
        ForwardView(name: name)
    }

    func updateNSView(_: NSView, context _: Context) {}
}

private final class ForwardView: NSView {
    private static var logger: Logger {
        .pawshot("app")
    }

    private let name: String
    private weak var broughtForward: NSWindow?

    init(name: String) {
        self.name = name
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unused — the UI is built in code")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A turn later: SwiftUI puts the window up after it has built the content.
        Task { @MainActor [weak self] in
            guard let self, let window, window !== broughtForward else { return }
            broughtForward = window
            let wasActive = NSApp.isActive
            NSApp.activate()
            window.orderFrontRegardless()
            let name = name
            Self.logger.notice(
                "\(name, privacy: .public) window shown: app was active \(wasActive, privacy: .public), ordered front"
            )
        }
    }
}
