import os
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

    /// The Mac's own state goes in the header: a throttled or starved Mac lags without Pawshot.
    func testTheHeaderCarriesTheHardwareAndTheMacsState() {
        var facts = facts(takenBy: nil)
        facts.hardware = "Apple M1, 8 GB"
        facts.system = "thermal nominal, memory pressure normal, low power off, on AC"
        facts.otherCaptureApps = ["CleanShot X"]
        let header = LogExport.header(facts, generatedAt: Date())

        XCTAssertTrue(header.contains("Hardware: Apple M1, 8 GB; now: thermal nominal, memory pressure normal, low power off, on AC"))
        XCTAssertTrue(header.contains("Other capture apps: CleanShot X"))
    }

    func testOtherCaptureAppsAreFoundWithoutFalseFriends() {
        XCTAssertEqual(
            SystemState.matchingCaptureApps(["CleanShot X", "Obsidian", "OBS", "Safari", "Shottr", "Kaleidoscope"]),
            ["CleanShot X", "OBS", "Shottr"]
        )
    }

    /// Read with no permission at all, and never empty.
    func testTheMacsStateIsReadable() {
        XCTAssertTrue(SystemState.hardware.contains("GB"))
        XCTAssertTrue(SystemState.now.hasPrefix("thermal "))
        XCTAssertNotEqual(SystemState.memoryPressure, "?")
        XCTAssertNotEqual(SystemState.powerSource, "power ?")
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
    func testLogShowRunsAndFindsOurLines() async throws {
        try XCTSkipUnless(Logger.isCollecting, "Collect Logs is off in this Mac's Pawshot settings")
        let text = await LogExport.readLog(arguments: [
            "show", "--predicate", "subsystem == \"com.caramelheaven.pawshot\"", "--last", "10m", "--style", "compact",
        ])
        XCTAssertTrue(text.contains("com.caramelheaven.pawshot"), String(text.prefix(300)))
    }

    /// "Collect Logs" off is read at every log call, with no relaunch. The test host shares the
    /// app's defaults, so the owner's own value is put back.
    func testTheLogGateFollowsTheSwitchAtOnce() {
        let key = Settings.Key.collectsLogs.rawValue
        let before = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(before, forKey: key) }

        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(Logger.isCollecting, "on by default")
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertFalse(Logger.isCollecting)
        UserDefaults.standard.set(true, forKey: key)
        XCTAssertTrue(Logger.isCollecting)
    }

    /// A stall's sample goes into Save Logs as its header and the main thread's branch only: the
    /// other threads are the same idle stacks every time, and the whole report is 230 KB.
    func testAStallSampleKeepsTheHeaderAndTheMainThreadOnly() {
        let report = """
        Analysis of sampling Pawshot (pid 42) every 10 milliseconds
        Physical footprint:         151.1M
        ----

        Call graph:
            92 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
            + 92 start  (in dyld) + 6688  [0x19017be80]
            +   92 CA::Transaction::commit()  (in QuartzCore) + 640  [0x1a0000000]
            92 Thread_2: com.apple.NSEventThread
            + 92 thread_start  (in libsystem_pthread.dylib) + 8  [0x19054ccec]

        Total number in stack (recursive counted multiple, when >=5):
        """

        let part = StallSamples.mainThreadPart(of: report)

        XCTAssertTrue(part.contains("Physical footprint:         151.1M"))
        XCTAssertTrue(part.contains("CA::Transaction::commit()"))
        XCTAssertFalse(part.contains("NSEventThread"))
        XCTAssertFalse(part.contains("Total number"))
    }

    /// Whether a stalled main thread was asleep or starved is the whole question a stall asks.
    func testAThreadStateSaysRunningOrWaitingAndItsPriority() {
        XCTAssertEqual(SystemState.describeThread(runState: TH_STATE_WAITING, current: 31, base: 47), "waiting, priority 31 (base 47)")
        XCTAssertEqual(SystemState.describeThread(runState: TH_STATE_RUNNING, current: 4, base: 47), "running, priority 4 (base 47)")
        XCTAssertTrue(SystemState.threadState(pthread_mach_thread_np(pthread_self())).hasPrefix("running, priority "))
    }

    /// The process start is what the launch is measured from: in the past, and not long ago.
    func testTheProcessStartedAMomentAgo() throws {
        let started = try XCTUnwrap(SystemState.processStart)
        XCTAssertLessThan(started, Date())
        XCTAssertGreaterThan(started, Date(timeIntervalSinceNow: -24 * 60 * 60))
    }
}
