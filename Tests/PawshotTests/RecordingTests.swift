import AVFoundation
import Carbon.HIToolbox
import CoreMedia
@testable import Pawshot
import XCTest

final class RecordingClockTests: XCTestCase {
    private func t(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// The file starts at the first picture: sound that came before it would put the picture late.
    func testNothingIsWrittenBeforeTheFirstFrame() {
        var clock = RecordingClock()

        XCTAssertNil(clock.outputTime(for: t(10), isVideo: false), "audio before the first frame")
        XCTAssertEqual(clock.outputTime(for: t(10.5), isVideo: true), .zero)
        XCTAssertEqual(clock.outputTime(for: t(11), isVideo: false), t(0.5))
    }

    /// A pause leaves no hole: what comes after it is shifted back by exactly its length.
    func testPauseIsCutOutOfTheTimeline() {
        var clock = RecordingClock()
        _ = clock.outputTime(for: t(100), isVideo: true)

        clock.pause(at: t(102))
        XCTAssertNil(clock.outputTime(for: t(103), isVideo: true), "frames during a pause are dropped")
        clock.resume(at: t(105))

        XCTAssertEqual(clock.outputTime(for: t(105.5), isVideo: true), t(2.5))
        XCTAssertEqual(clock.duration(at: t(106)), t(3))
    }

    /// A frame captured before the resume but delivered after it would land in the past.
    func testLateFrameFromBeforeTheResumeIsDropped() {
        var clock = RecordingClock()
        _ = clock.outputTime(for: t(0), isVideo: true)
        clock.pause(at: t(1))
        clock.resume(at: t(5))

        XCTAssertNil(clock.outputTime(for: t(0.5), isVideo: true))
    }

    /// A frame captured during the pause but delivered after the resume would be stamped inside
    /// the stretch already written: 4.5 s into a pause of 1…5 s lands at 0.5 s, before the frame
    /// written at 0.98 s — a time going backwards the writer may refuse, losing the take.
    func testAFrameFromInsideThePauseDeliveredLateIsDropped() {
        var clock = RecordingClock()
        _ = clock.outputTime(for: t(0), isVideo: true)
        XCTAssertEqual(clock.outputTime(for: t(0.98), isVideo: true), t(0.98))
        clock.pause(at: t(1))
        clock.resume(at: t(5))

        XCTAssertNil(clock.outputTime(for: t(4.5), isVideo: true))
        XCTAssertNil(clock.outputTime(for: t(4.9), isVideo: false), "sound from the pause too")
        XCTAssertEqual(clock.outputTime(for: t(5.1), isVideo: true), t(1.1), "what comes after the resume goes on")
    }

    func testDurationStopsWhilePaused() {
        var clock = RecordingClock()
        XCTAssertEqual(clock.duration(at: t(3)), .zero, "nothing recorded yet")

        _ = clock.outputTime(for: t(1), isVideo: true)
        clock.pause(at: t(4))

        XCTAssertEqual(clock.duration(at: t(60)), t(3))
    }

    func testDoublePauseAndStrayResumeChangeNothing() {
        var clock = RecordingClock()
        _ = clock.outputTime(for: t(0), isVideo: true)
        clock.resume(at: t(1))
        clock.pause(at: t(2))
        clock.pause(at: t(3))
        clock.resume(at: t(4))

        XCTAssertEqual(clock.pausedTotal, t(2))
    }
}

final class RecordingStatusTests: XCTestCase {
    func testElapsedReadsLikeAStopwatch() {
        XCTAssertEqual(AppState.RecordingStatus(elapsed: 0, isPaused: false).elapsedText, "0:00")
        XCTAssertEqual(AppState.RecordingStatus(elapsed: 42.9, isPaused: false).elapsedText, "0:42")
        XCTAssertEqual(AppState.RecordingStatus(elapsed: 725, isPaused: false).elapsedText, "12:05")
        XCTAssertEqual(AppState.RecordingStatus(elapsed: 3725, isPaused: true).elapsedText, "1:02:05")
    }
}

final class SystemScreenshotShortcutsTests: XCTestCase {
    private static func entry(enabled: Bool, keyCode: Int, flags: Int, character: Int = 65535) -> [String: Any] {
        [
            "enabled": NSNumber(value: enabled),
            "value": ["parameters": [NSNumber(value: character), NSNumber(value: keyCode), NSNumber(value: flags)]],
        ]
    }

    /// ⇧ = 0x20000, ⌘ = 0x100000 — the flags the preferences store, same as `NSEvent`.
    private static let shiftCommand = 0x120000

    func testUntickedSystemShortcutFreesTheKey() {
        let system = SystemScreenshotShortcuts(symbolicHotKeys: [
            "28": Self.entry(enabled: false, keyCode: kVK_ANSI_3, flags: Self.shiftCommand),
            "30": Self.entry(enabled: true, keyCode: kVK_ANSI_4, flags: Self.shiftCommand),
        ])

        XCTAssertNil(system.conflict(with: .recordRegionDefault), "⇧⌘3 was unticked")
        XCTAssertEqual(system.conflict(with: .recordFullScreenDefault)?.id, 30)
    }

    /// An untouched Mac has no entries at all, and every screenshot shortcut is on.
    func testMissingPreferencesMeanTheFactoryDefaults() {
        let system = SystemScreenshotShortcuts(symbolicHotKeys: nil)

        XCTAssertEqual(system.conflict(with: .recordRegionDefault)?.id, 28)
        XCTAssertEqual(system.conflict(with: .recordFullScreenDefault)?.id, 30)
        XCTAssertNil(system.conflict(with: .regionDefault), "⇧⌘2 has never been the system's")
        XCTAssertNil(system.conflict(with: .fullScreenDefault))
    }

    /// Reassigned in System Settings: the system now holds the new key, not the old one.
    func testReassignedSystemShortcutFollowsItsNewKey() {
        let system = SystemScreenshotShortcuts(symbolicHotKeys: [
            "28": Self.entry(enabled: true, keyCode: kVK_ANSI_9, flags: Self.shiftCommand),
        ])

        XCTAssertNil(system.conflict(with: .recordRegionDefault))
        let nine = HotKeyBinding(keyCode: UInt32(kVK_ANSI_9), modifiers: [.shift, .command], label: "9")
        XCTAssertEqual(system.conflict(with: nine)?.id, 28)
    }

    /// ⌥ on top makes the combination a different one, and it is ours.
    func testExtraModifierIsNotAConflict() {
        let system = SystemScreenshotShortcuts(symbolicHotKeys: nil)
        let withOption = HotKeyBinding(keyCode: UInt32(kVK_ANSI_4), modifiers: [.shift, .command, .option], label: "4")

        XCTAssertNil(system.conflict(with: withOption))
    }

    /// ⇧⌘6 is the Touch Bar's picture only on a Mac with a Touch Bar, which can't be told: a Mac
    /// with no entry must not be warned about a key that works; an explicit entry is heeded.
    func testTouchBarShortcutWarnsOnlyWhenThePreferencesHaveIt() {
        let shiftCommandSix = HotKeyBinding(keyCode: UInt32(kVK_ANSI_6), modifiers: [.shift, .command], label: "6")
        XCTAssertNil(SystemScreenshotShortcuts(symbolicHotKeys: nil).conflict(with: shiftCommandSix))

        let on = SystemScreenshotShortcuts(symbolicHotKeys: [
            "181": Self.entry(enabled: true, keyCode: kVK_ANSI_6, flags: Self.shiftCommand),
        ])
        XCTAssertEqual(on.conflict(with: shiftCommandSix)?.id, 181)

        let off = SystemScreenshotShortcuts(symbolicHotKeys: [
            "181": Self.entry(enabled: false, keyCode: kVK_ANSI_6, flags: Self.shiftCommand),
        ])
        XCTAssertNil(off.conflict(with: shiftCommandSix))
    }

    /// A tester moved "Move focus to next window" to ⌘1, and macOS took ⇧⌘1 with it — the other
    /// direction — so the default full-screen shortcut never fired. Both count as taken.
    func testMoveFocusToNextWindowTakesItsKeysWithAndWithoutShift() {
        let moved = SystemScreenshotShortcuts(symbolicHotKeys: [
            "27": Self.entry(enabled: true, keyCode: kVK_ANSI_1, flags: 0x100000, character: 49),
        ])
        let commandOne = HotKeyBinding(keyCode: UInt32(kVK_ANSI_1), modifiers: [.command], label: "1")
        let optionCommandOne = HotKeyBinding(keyCode: UInt32(kVK_ANSI_1), modifiers: [.option, .command], label: "1")

        XCTAssertEqual(moved.conflict(with: .fullScreenDefault)?.id, 27, "⇧⌘1, the other direction")
        XCTAssertEqual(moved.conflict(with: commandOne)?.id, 27)
        XCTAssertNil(moved.conflict(with: optionCommandOne), "⌥ is not a direction")

        let factory = SystemScreenshotShortcuts(symbolicHotKeys: nil)
        let all: [HotKeyBinding] = [.regionDefault, .fullScreenDefault, .recordRegionDefault, .recordFullScreenDefault,
                                    .penDefault, .restartDefault]
        XCTAssertFalse(all.contains { factory.conflict(with: $0)?.id == 27 }, "left at ⌘`, it takes none of ours")
    }

    /// The saved log lists every macOS shortcut that is on, any item, so a key the system takes
    /// shows up by name: a window switcher on ⌘1 (item 27 moved there) reads `item 27: ⌘1`.
    /// Off, bare or keyless items are left out.
    func testEveryEnabledSystemShortcutIsListedForTheLog() {
        let listed = SystemScreenshotShortcuts.enabledShortcuts(in: [
            "27": Self.entry(enabled: true, keyCode: kVK_ANSI_1, flags: 0x100000, character: 49),
            "28": Self.entry(enabled: false, keyCode: kVK_ANSI_3, flags: Self.shiftCommand),
            "60": Self.entry(enabled: true, keyCode: kVK_Space, flags: 0x40000, character: 32),
            "79": ["enabled": true],
            "164": Self.entry(enabled: true, keyCode: 0xFFFF, flags: 0, character: 0xFFFF),
            "200": Self.entry(enabled: true, keyCode: kVK_ANSI_A, flags: 0x20000, character: 97),
        ])

        XCTAssertEqual(listed.map(\.id), [27, 60])
        XCTAssertEqual(listed.map(\.binding.logString), ["⌘1", "⌃Space"])
    }
}

/// An integration test against the real ScreenCaptureKit and AVAssetWriter, skipped without screen
/// recording access, like `ScreenCaptureServiceTests`. No microphone: it would prompt.
final class RecordingEngineTests: XCTestCase {
    /// Goes through `RecordingController.makeEngine`, the path the app takes: a fresh filter that
    /// leaves Pawshot out, a region in global points, an even pixel size.
    @MainActor
    func testRecordsAPlayableMovieOfARegion() async throws {
        try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "No screen recording access — the recording test is skipped")

        let screen = try XCTUnwrap(NSScreen.main)
        let displayID = try XCTUnwrap(SelectionOverlayController.displayID(of: screen))
        let displayBounds = CGDisplayBounds(displayID)
        let region = CGRect(x: displayBounds.minX + 10, y: displayBounds.minY + 10, width: 401, height: 301)

        let (engine, size) = try await RecordingController.makeEngine(
            displayID: displayID,
            rect: region,
            capturesSystemAudio: false,
            capturesMicrophone: false
        )
        try await engine.start()
        try await Task.sleep(for: .seconds(1.5))
        let movie = try await engine.stop()
        defer { try? FileManager.default.removeItem(at: movie) }

        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(tracks.first)
        let naturalSize = try await video.load(.naturalSize)

        // A still screen sends a single frame; the last one is repeated at the stop, so the file
        // still lasts as long as the recording did.
        XCTAssertGreaterThanOrEqual(duration, 1.0)
        XCTAssertEqual(Int(naturalSize.width), size.width)
        XCTAssertEqual(Int(naturalSize.height), size.height)
        XCTAssertEqual(size.width % 2, 0)
        XCTAssertEqual(size.height % 2, 0)
    }

    /// A take at 15 fps comes out at 15 — and its file's shortest frame does **not** say so:
    /// measured 0.03 s against a nominal 14.86, which is why the take's rate goes into its
    /// timeline for the export. Only a live stream can tell what ScreenCaptureKit's
    /// variable-rate file reports. A still screen sends a frame or two, so the test keeps a
    /// window of its own changing under the region.
    @MainActor
    func testATakeAt15FPSSaysSoInItsFile() async throws {
        try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "No screen recording access — the recording test is skipped")

        let screen = try XCTUnwrap(NSScreen.main)
        let displayID = try XCTUnwrap(SelectionOverlayController.displayID(of: screen))
        let displayBounds = CGDisplayBounds(displayID)
        let region = CGRect(x: displayBounds.minX + 10, y: displayBounds.minY + 40, width: 400, height: 300)

        // Something that changes every 10 ms, under the region (AppKit: bottom-left origin).
        let flicker = NSWindow(
            contentRect: CGRect(x: screen.frame.minX + 10, y: screen.frame.maxY - 40 - 300, width: 400, height: 300),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        flicker.isReleasedWhenClosed = false
        flicker.level = .floating
        flicker.backgroundColor = .red
        flicker.orderFrontRegardless()
        defer { flicker.close() }
        // The filter leaves Pawshot out — the test host is Pawshot — so the window is let in by
        // name, once ScreenCaptureKit sees it on screen (a moment after it is ordered in).
        try await Task.sleep(for: .milliseconds(400))

        let (engine, _) = try await RecordingController.makeEngine(
            displayID: displayID,
            rect: region,
            includingWindows: [CGWindowID(flicker.windowNumber)],
            framesPerSecond: 15,
            capturesSystemAudio: false,
            capturesMicrophone: false
        )
        try await engine.start()
        for tick in 0 ..< 150 {
            flicker.backgroundColor = tick.isMultiple(of: 2) ? .red : .blue
            try await Task.sleep(for: .milliseconds(10))
        }
        let movie = try await engine.stop()
        defer { try? FileManager.default.removeItem(at: movie) }

        let tracks = try await AVURLAsset(url: movie).loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(tracks.first)
        let shortest = try await video.load(.minFrameDuration)
        let rate = try await video.load(.nominalFrameRate)
        XCTAssertEqual(rate, 15, accuracy: 1.5, "nominal \(rate) fps, shortest frame \(shortest.seconds) s")
    }

    /// The region moved on a pause: ScreenCaptureKit has to take a new `sourceRect` on a running
    /// stream, and the file has to go on at the size it started. That ScreenCaptureKit does is the
    /// one thing moving the region rests on, and only a live stream can tell.
    @MainActor
    func testTheSourceOfARunningStreamCanMove() async throws {
        try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "No screen recording access — the recording test is skipped")

        let screen = try XCTUnwrap(NSScreen.main)
        let displayID = try XCTUnwrap(SelectionOverlayController.displayID(of: screen))
        let displayBounds = CGDisplayBounds(displayID)
        let region = CGRect(x: displayBounds.minX + 10, y: displayBounds.minY + 10, width: 401, height: 301)

        let (engine, size) = try await RecordingController.makeEngine(
            displayID: displayID,
            rect: region,
            capturesSystemAudio: false,
            capturesMicrophone: false
        )
        try await engine.start()
        try await Task.sleep(for: .seconds(0.7))
        engine.pause()
        let elsewhere = SelectionGeometry.sourceRect(displayRect: region.offsetBy(dx: 200, dy: 150), displayFrame: displayBounds)
        try await engine.moveSource(to: elsewhere)
        engine.resume()
        try await Task.sleep(for: .seconds(0.7))
        let movie = try await engine.stop()
        defer { try? FileManager.default.removeItem(at: movie) }

        let asset = AVURLAsset(url: movie)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(tracks.first)
        let naturalSize = try await video.load(.naturalSize)
        XCTAssertEqual(Int(naturalSize.width), size.width)
        XCTAssertEqual(Int(naturalSize.height), size.height)
    }
}
