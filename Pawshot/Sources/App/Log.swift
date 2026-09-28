import Foundation
import os

/// Settings → Diagnostics → "Collect Logs", honoured for real: switched off, every logger in the
/// app is `Logger(.disabled)` and nothing of Pawshot's reaches the system log.
///
/// Each file's logger is a computed `static var` over `pawshot(_:)`, not a `static let`: a stored
/// logger is made once, and the switch would then take effect only after a relaunch. The flag is
/// read straight from the defaults, which any thread may do — the overlay's watchdog and the
/// recording engine log from their own.
extension Logger {
    static let pawshotSubsystem = "com.caramelheaven.pawshot"

    static var isCollecting: Bool {
        UserDefaults.standard.object(forKey: Settings.Key.collectsLogs.rawValue) as? Bool ?? true
    }

    static func pawshot(_ category: String) -> Logger {
        isCollecting ? Logger(subsystem: pawshotSubsystem, category: category) : Logger(.disabled)
    }
}
