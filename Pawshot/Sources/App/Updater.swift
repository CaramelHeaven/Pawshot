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

    /// Not under tests: the test host is this app, and it has no business checking a feed.
    static func start() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
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
