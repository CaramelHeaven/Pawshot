import AppKit
import Carbon.HIToolbox
import os

/// A window whose short ⌘Q has something to lose: it asks before closing, or closes at once when
/// there is nothing to lose.
@MainActor
protocol ClosesOnQuitKey: AnyObject {
    func closeForQuitKey()
}

/// ⌘Q in Pawshot, Chrome's way ("Warn Before Quitting", Settings → General, on by default):
///
/// - a tap closes the window in front — the owner's call, a stray ⌘Q must not lose a shot;
/// - held past the tap, the "Hold ⌘Q to Quit" toast comes up with a filling bar, and Pawshot
///   quits when the bar is full, its windows fading out first;
/// - let go before that, and the toast melts away; nothing else happens.
///
/// With the setting off, ⌘Q quits at once. Keyboard events don't reach a menu action while the
/// key is held — only repeats — so the key state is polled, as the canvas polls Space.
@MainActor
enum QuitKey {
    private static let logger = Logger(subsystem: "com.caramelheaven.pawshot", category: "quit")

    /// Let go before this and it was a tap.
    static let tapLimit: Duration = .milliseconds(300)
    /// Held this long, from the press, Pawshot quits.
    static let holdDuration: Duration = .milliseconds(1300)

    private static var isWaitingForRelease = false

    enum Phase: Equatable {
        case tap
        /// The toast is up and its bar is filling.
        case warning
        case quit
    }

    static func phase(heldFor held: Duration) -> Phase {
        if held < tapLimit {
            return .tap
        }
        return held < holdDuration ? .warning : .quit
    }

    /// How full the toast's bar is after holding for `held`.
    static func progress(heldFor held: Duration) -> Double {
        min(max((held - tapLimit) / (holdDuration - tapLimit), 0), 1)
    }

    /// The Quit menu item. From the keyboard, it waits to see whether the keys are held; picked
    /// with the mouse, it quits at once, as in any other app.
    static func pressed() {
        // The key state as well as the event: if SwiftUI ever runs the action a beat after the
        // key press, the press must still not read as a click on the menu.
        let fromKeyboard = NSApp.currentEvent?.type == .keyDown || isHeld
        let warns = Settings.shared.warnsBeforeQuitting
        guard fromKeyboard, warns else {
            logger.notice("Quit: at once (from keyboard \(fromKeyboard, privacy: .public), warn before quitting \(warns, privacy: .public))")
            NSApp.terminate(nil)
            return
        }
        // Key repeats of a held ⌘Q arrive while the first press is still being timed.
        guard !isWaitingForRelease else { return }
        logger.notice("⌘Q pressed, timing the hold")
        isWaitingForRelease = true

        Task { @MainActor in
            defer { isWaitingForRelease = false }
            let started = ContinuousClock.now
            var isWarning = false
            while true {
                let held = ContinuousClock.now - started
                switch phase(heldFor: held) {
                case .tap:
                    guard isHeld else {
                        logger.notice("⌘Q: tap")
                        closeFrontWindow()
                        return
                    }
                case .warning:
                    guard isHeld else {
                        logger.notice("⌘Q: let go on the toast, staying")
                        QuitToast.hide()
                        return
                    }
                    if !isWarning {
                        logger.notice("⌘Q: held, toast up")
                        QuitToast.show()
                        isWarning = true
                    }
                    QuitToast.setProgress(progress(heldFor: held))
                case .quit:
                    logger.notice("⌘Q: held to the end, quitting")
                    QuitToast.setProgress(1)
                    fadeOutAndQuit()
                    return
                }
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }

    private static var isHeld: Bool {
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_ANSI_Q))
            && CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
    }

    /// Chrome's ending: the windows fade, then the app goes.
    private static func fadeOutAndQuit() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            for window in NSApp.windows where window.isVisible {
                window.animator().alphaValue = 0
            }
        } completionHandler: {
            MainActor.assumeIsolated {
                NSApp.terminate(nil)
            }
        }
    }

    enum Action: Equatable {
        /// The window's own controller decides, asking first if there is work in it.
        case askController
        case performClose
        /// The capture overlay and other windows without a close button stay.
        case nothing
    }

    static func action(for window: NSWindow) -> Action {
        if window.delegate is ClosesOnQuitKey {
            return .askController
        }
        return window.styleMask.contains(.closable) ? .performClose : .nothing
    }

    /// A tap of ⌘Q: the key window goes, the way ⌘W would take it — unless it has work to lose.
    static func closeFrontWindow() {
        guard let window = NSApp.keyWindow else {
            logger.notice("⌘Q tap: no key window, nothing to close")
            return
        }
        let chosen = action(for: window)
        let title = window.title
        logger.notice("⌘Q tap: \(String(describing: chosen), privacy: .public) for \(title, privacy: .public)")
        switch chosen {
        case .askController:
            (window.delegate as? ClosesOnQuitKey)?.closeForQuitKey()
        case .performClose:
            window.performClose(nil)
        case .nothing:
            break
        }
    }
}
