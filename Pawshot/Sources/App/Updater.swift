import os
import Sparkle

/// Updates through Sparkle: the feed and the key are in Info.plist (`Project.swift`), releases go
/// out with `make release publish`. Sparkle downloads the new build itself, so it carries no
/// quarantine and Gatekeeper never asks — the reason it is here at all.
@MainActor
enum Updater {
    private static var logger: Logger {
        .pawshot("updates")
    }

    private static var controller: SPUStandardUpdaterController?
    /// Sparkle holds its delegate weakly.
    private static let delegate = UpdaterLog()

    /// Not under tests: the test host is this app, and it has no business checking a feed.
    static func start() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
        logger.notice("updates: started, checking automatically")
    }

    static func checkForUpdates() {
        guard let controller else {
            logger.error("updates: asked to check, but the updater never started")
            return
        }
        controller.checkForUpdates(nil)
    }
}

/// What Sparkle found and did, for the log: a check leaves no other trace.
@MainActor
private final class UpdaterLog: NSObject, SPUUpdaterDelegate {
    private static var logger: Logger {
        .pawshot("updates")
    }

    func updater(_: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Self.logger.notice("updates: found \(version, privacy: .public)")
    }

    func updaterDidNotFindUpdate(_: SPUUpdater) {
        Self.logger.notice("updates: none")
    }

    func updater(_: SPUUpdater, didAbortWithError error: any Error) {
        // "No update" arrives here too; `updaterDidNotFindUpdate` has said it.
        let error = error as NSError
        guard !(error.domain == SUSparkleErrorDomain && error.code == 1001) else { return } // SUNoUpdateError
        Self.logger.error("updates: aborted: \(String(describing: error), privacy: .public)")
    }

    func updaterWillRelaunchApplication(_: SPUUpdater) {
        Self.logger.notice("updates: relaunching")
    }
}
