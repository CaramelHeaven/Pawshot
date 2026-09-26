import Foundation
import ServiceManagement

/// Launch at login on top of `SMAppService`.
///
/// The thin wrapper is not there for elegance: `SMAppService` registers the **bundle path**, so
/// launch at login enabled for a copy in `DerivedData` will keep starting exactly that copy.
/// Hence `isInApplicationsFolder` — the UI has to be honest about it.
enum LoginItem {
    /// State in UI terms rather than in terms of the system enum.
    enum State {
        case enabled
        case disabled
        /// The system is waiting for the user to allow the launch in System Settings → Login Items.
        case requiresApproval
        case unavailable

        var isOn: Bool {
            self == .enabled
        }
    }

    static func state(from status: SMAppService.Status) -> State {
        switch status {
        case .enabled: .enabled
        case .notRegistered, .notFound: .disabled
        case .requiresApproval: .requiresApproval
        @unknown default: .unavailable
        }
    }

    static var current: State {
        state(from: SMAppService.mainApp.status)
    }

    /// Launching an app at login makes no sense when it runs from outside `/Applications`: the
    /// system remembers the path to the build folder, and after `make install` launch at login
    /// would keep starting the stale copy.
    static var isInApplicationsFolder: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
