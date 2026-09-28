@testable import Pawshot
import XCTest

@MainActor
final class LogExportTests: XCTestCase {
    private func facts(takenBy: String?) -> LogExport.Facts {
        LogExport.Facts(
            version: "0.4.0",
            build: "1",
            macOS: "Version 26.0",
            model: "Mac16,1",
            bundlePath: "/Applications/Pawshot.app",
            displays: ["2560×1440 pt @2.0x (main)"],
            screenRecording: true,
            microphone: false,
            inputMonitoring: false,
            hotKeys: [("Capture a region", "⇧⌘4", takenBy)],
            settings: [("Warn before quitting (⌘Q)", "true")],
            otherCopies: []
        )
    }

    /// The header says what the log alone can't: the build, the Mac, the permissions, and which
    /// shortcut macOS still takes for itself — the first suspect when a hotkey "does nothing".
    func testTheHeaderNamesTheBuildThePermissionsAndATakenShortcut() {
        let header = LogExport.header(
            facts(takenBy: "Save picture of selected area as a file"),
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(header.contains("Pawshot 0.4.0 (1)"))
        XCTAssertTrue(header.contains("Mac16,1"))
        XCTAssertTrue(header.contains("Screen recording: yes, microphone: NO"))
        XCTAssertTrue(header.contains("Capture a region: ⇧⌘4 — TAKEN BY macOS: Save picture of selected area as a file"))
        XCTAssertTrue(header.contains("Other running copies: none"))
    }

    func testAFreeShortcutIsNotFlagged() {
        let header = LogExport.header(facts(takenBy: nil), generatedAt: Date())
        XCTAssertTrue(header.contains("Capture a region: ⇧⌘4\n"))
        XCTAssertFalse(header.contains("TAKEN"))
    }

    /// Only Pawshot's own subsystem, three days back, with `--info` for whatever is still in memory.
    func testTheLogIsReadForPawshotAlone() {
        XCTAssertEqual(
            LogExport.logArguments,
            ["show", "--predicate", "subsystem == \"com.caramelheaven.pawshot\"", "--last", "3d", "--info", "--style", "compact"]
        )
        XCTAssertTrue(LogExport.suggestedFileName.hasPrefix("pawshot-logs-"))
        XCTAssertTrue(LogExport.suggestedFileName.hasSuffix(".txt"))
    }

    /// The real thing, end to end: `log show` runs from the app and returns Pawshot's lines — the
    /// test host itself has just logged its launch.
    func testLogShowRunsAndFindsOurLines() async {
        let text = await LogExport.readLog(arguments: [
            "show", "--predicate", "subsystem == \"com.caramelheaven.pawshot\"", "--last", "10m", "--style", "compact",
        ])
        XCTAssertTrue(text.contains("com.caramelheaven.pawshot"), String(text.prefix(300)))
    }
}
