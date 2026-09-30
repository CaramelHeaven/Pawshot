import AppKit
import os
import SwiftUI

/// Puts the window it sits in above every other app's windows once it opens. The welcome window
/// and What's New open by themselves at launch, and a launch from the background — Sparkle's
/// relaunch after an update, a login item — is not activated by macOS: SwiftUI then orders the
/// window front among Pawshot's own only, behind the app in front. 0.4.7's What's New opened
/// there. `NSApp.activate()` may be refused (macOS 14+ activation is cooperative), so
/// `orderFrontRegardless()` does the work, as in `PermissionWindowController`.
///
/// A window opened again — from the paw's menu, or Settings, which SwiftUI reuses — never moves
/// into a window anew, so the menu calls `bringFront(_:)` for it.
struct ComesForward: NSViewRepresentable {
    private static var logger: Logger {
        .pawshot("app")
    }

    /// Each named window once its view is in it; weak, so a closed window SwiftUI lets go of goes.
    @MainActor fileprivate static let windows = NSMapTable<NSString, NSWindow>.strongToWeakObjects()
    /// The latest check per window: a menu's `bringFront` right after the window's first showing
    /// asked twice, and the log said "not key" twice in the same millisecond.
    @MainActor private static var checks: [String: Int] = [:]

    private let name: String

    /// `name` is for the log, and what `bringFront(_:)` finds the window by.
    init(_ name: String) {
        self.name = name
    }

    func makeNSView(context _: Context) -> NSView {
        ForwardView(name: name)
    }

    func updateNSView(_: NSView, context _: Context) {}

    /// For a window opened from a menu, a turn after `openWindow`. Nothing registered yet means
    /// its first showing is still to come, and that brings it forward by itself.
    @MainActor
    static func bringFront(_ name: String) {
        guard let window = windows.object(forKey: name as NSString) else { return }
        guard window.isVisible else {
            logger.notice("\(name, privacy: .public) window not up a turn after opening: left to its first showing")
            return
        }
        guard !(NSApp.isActive && window.isKeyWindow) else {
            logger.notice("\(name, privacy: .public) window already in front")
            return
        }
        order(window, name: name, what: "brought front")
    }

    /// When a check looks, and when "not key" becomes an error: macOS hands the activation to a
    /// background app late — in the owner's 0.5.3 log a second after the menu — so half a second
    /// is only a first look.
    static let checkTimes = [500, 1500]

    /// Activates, orders the window above everyone, and says whether it became key — not key at
    /// the last look is the window left behind another app.
    @MainActor
    fileprivate static func order(_ window: NSWindow, name: String, what: String) {
        let wasActive = NSApp.isActive
        NSApp.activate()
        window.orderFrontRegardless()
        logger.notice("\(name, privacy: .public) window \(what, privacy: .public): app was active \(wasActive, privacy: .public), ordered front")
        let check = (checks[name] ?? 0) + 1
        checks[name] = check
        Task { @MainActor [weak window] in
            var waited = 0
            for (index, ms) in checkTimes.enumerated() {
                try? await Task.sleep(for: .milliseconds(ms - waited))
                waited = ms
                // A newer check of the same window, or the window gone: nothing for this one to say.
                guard checks[name] == check, let window, window.isVisible else { return }
                let isActive = NSApp.isActive
                if window.isKeyWindow {
                    Self.logger.notice("\(name, privacy: .public) window after \(ms, privacy: .public) ms: key true, app active \(isActive, privacy: .public)")
                    return
                }
                if index < checkTimes.count - 1 {
                    Self.logger.notice("\(name, privacy: .public) window after \(ms, privacy: .public) ms: not key yet, app active \(isActive, privacy: .public)")
                } else {
                    Self.logger.error("\(name, privacy: .public) window after \(ms, privacy: .public) ms: not key — behind another app? app active \(isActive, privacy: .public)")
                }
            }
        }
    }
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

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // A selector observer goes away with the view by itself; this is for a window swapped.
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let current = window else { return }
        ComesForward.windows.setObject(current, forKey: name as NSString)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: current
        )
        // A turn later: SwiftUI puts the window up after it has built the content.
        Task { @MainActor [weak self] in
            guard let self, let window, window !== broughtForward else { return }
            broughtForward = window
            ComesForward.order(window, name: name, what: "shown")
        }
    }

    @objc private func windowWillClose(_: Notification) {
        let name = name
        Self.logger.notice("\(name, privacy: .public) window closed")
    }
}
