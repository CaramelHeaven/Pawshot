import AppKit
import os
import SwiftUI

extension LoginItem {
    private static var logger: Logger {
        .pawshot("settings")
    }

    /// A toggle's binding over the system state. The getter shows the last answer and asks
    /// `SMAppService` again in the background when that answer is two seconds old, so a view that
    /// re-renders every second still follows System Settings — without an XPC call on the main
    /// thread each time (a stall sample of 0.5.3 caught the welcome window in exactly that).
    @MainActor
    static var menuBinding: Binding<Bool> {
        Binding(
            get: {
                LoginItemStatus.shared.refreshIfStale()
                return LoginItemStatus.shared.state.isOn
            },
            set: { enable in
                logger.notice("launch at login → \(enable, privacy: .public)")
                do {
                    try setEnabled(enable)
                } catch {
                    logger.error("launch at login not changed: \(String(describing: error), privacy: .public)")
                    presentFailure(error, enabling: enable)
                }
                LoginItemStatus.shared.refreshNow()
                let now = String(describing: LoginItemStatus.shared.state)
                logger.notice("launch at login now \(now, privacy: .public)")
            }
        )
    }

    /// Why the toggle is greyed out or not yet on, in words; `nil` when there is nothing to say.
    @MainActor
    static var hint: String? {
        if LoginItemStatus.shared.state == .requiresApproval {
            return String(localized: "Allow it in System Settings → General → Login Items.")
        }
        if !isInApplicationsFolder {
            // The system remembers the path to the current bundle, so launching at login from a
            // build folder would later bring up a stale copy.
            return String(localized: "Available once Pawshot is installed in /Applications.")
        }
        return nil
    }

    @MainActor
    fileprivate static func presentFailure(_ error: Error, enabling: Bool) {
        let alert = NSAlert()
        alert.messageText = enabling
            ? String(localized: "Couldn't enable launch at login")
            : String(localized: "Couldn't disable launch at login")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        NSApp.activate()
        alert.runModal()
    }
}

/// The last answer `SMAppService` gave about launch at login, kept for the views that ask every
/// second. Asked again off the main thread, at most every `staleAfter` seconds.
@MainActor
@Observable
final class LoginItemStatus {
    static let shared = LoginItemStatus()

    nonisolated static let staleAfter: TimeInterval = 2

    private static var logger: Logger {
        .pawshot("settings")
    }

    /// Read once, on first use: every later answer comes from the background.
    private(set) var state = LoginItem.current
    @ObservationIgnored private var askedAt = Date()
    @ObservationIgnored private var asking = false

    /// Whether an answer given at `askedAt` should be asked for again at `now`.
    nonisolated static func isStale(askedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(askedAt) >= staleAfter
    }

    func refreshIfStale() {
        guard !asking, Self.isStale(askedAt: askedAt, now: Date()) else { return }
        asking = true
        askedAt = Date()
        Task.detached(priority: .utility) { [weak self] in
            let fresh = LoginItem.current
            await self?.take(fresh)
        }
    }

    /// Right after the toggle: the person expects to see what they did, not an answer two
    /// seconds old.
    func refreshNow() {
        take(LoginItem.current)
        askedAt = Date()
    }

    private func take(_ fresh: LoginItem.State) {
        asking = false
        guard fresh != state else { return }
        let from = String(describing: state)
        let to = String(describing: fresh)
        Self.logger.notice("launch at login: \(from, privacy: .public) → \(to, privacy: .public) (read from the system)")
        state = fresh
    }
}
