import AppKit
import SwiftUI

extension LoginItem {
    /// A toggle's binding over the system state. The getter asks `SMAppService` every time, so a
    /// view that re-renders shows what System Settings says, not what it said at launch.
    @MainActor
    static var menuBinding: Binding<Bool> {
        Binding(
            get: { current.isOn },
            set: { enable in
                do {
                    try setEnabled(enable)
                } catch {
                    presentFailure(error, enabling: enable)
                }
            }
        )
    }

    /// Why the toggle is greyed out or not yet on, in words; `nil` when there is nothing to say.
    static var hint: String? {
        if current == .requiresApproval {
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
    private static func presentFailure(_ error: Error, enabling: Bool) {
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
