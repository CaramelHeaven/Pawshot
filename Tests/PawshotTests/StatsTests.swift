import AppKit
@testable import Pawshot
import XCTest

@MainActor
final class StatsTests: XCTestCase {
    /// A suite of our own per test, gone when it ends: a test must never touch the owner's numbers.
    private lazy var defaults: UserDefaults = {
        let name = "PawshotTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }()

    private func date(day: Int, hour: Int = 12) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
    }

    private func style(_ color: NSColor) -> AnnotationStyle {
        AnnotationStyle(color: color, lineWidth: 3, fillOpacity: 0)
    }

    func testCountsSurviveARelaunch() {
        let stats = Stats(defaults: defaults)
        XCTAssertEqual(stats.value(.arrows), 0)
        XCTAssertEqual(stats.daysTogether(), 1, "the first day counts as one")

        stats.add(.undos)
        stats.add(.recognizedCharacters, 250)
        stats.noteRecording(seconds: 61.6, at: date(day: 3))

        let reread = Stats(defaults: defaults)
        XCTAssertEqual(reread.value(.undos), 1)
        XCTAssertEqual(reread.value(.recognizedCharacters), 250)
        XCTAssertEqual(reread.value(.recordings), 1)
        XCTAssertEqual(reread.value(.recordedSeconds), 62)
    }

    /// The capture count behind the hints lives under `stats.` too, and is not the reset's to clear.
    func testResetStartsAgainAndLeavesTheCaptureCountAlone() {
        defaults.set(7, forKey: Settings.Key.captureCount.rawValue)
        let stats = Stats(defaults: defaults)
        stats.noteShot(.window, at: date(day: 2, hour: 9))
        let before = Date()

        stats.reset()

        XCTAssertEqual(stats.value(.shots), 0)
        XCTAssertEqual(stats.value(.windowShots), 0)
        XCTAssertNil(stats.peakHour)
        XCTAssertEqual(stats.streak(now: date(day: 2)), 0)
        XCTAssertGreaterThanOrEqual(stats.since, before)
        XCTAssertEqual(defaults.integer(forKey: Settings.Key.captureCount.rawValue), 7)
    }

    func testTheStreakGrowsDayByDayAndBreaksOnAGap() {
        let stats = Stats(defaults: defaults)
        stats.noteActiveDay(date(day: 1, hour: 9))
        stats.noteActiveDay(date(day: 1, hour: 23))
        XCTAssertEqual(stats.streak(now: date(day: 1)), 1, "the same day twice is one day")

        stats.noteActiveDay(date(day: 2, hour: 1))
        XCTAssertEqual(stats.streak(now: date(day: 2)), 2)
        XCTAssertEqual(stats.streak(now: date(day: 3)), 2, "still standing the next day")

        stats.noteActiveDay(date(day: 5))
        XCTAssertEqual(stats.streak(now: date(day: 5)), 1, "a gap starts it again")
        XCTAssertEqual(stats.streak(now: date(day: 7)), 0, "a whole day with nothing ends it")
    }

    func testModesAndThePeakHour() {
        let stats = Stats(defaults: defaults)
        stats.noteShot(.region, at: date(day: 1, hour: 2))
        stats.noteShot(.region, at: date(day: 1, hour: 2))
        stats.noteShot(.window, at: date(day: 1, hour: 14))
        stats.noteShot(.fullScreen, at: date(day: 1, hour: 14))

        let shares = stats.modeShares
        XCTAssertEqual(shares?.favourite, .region)
        XCTAssertEqual(shares?.region, 50)
        XCTAssertEqual(shares?.window, 25)
        XCTAssertEqual(shares?.fullScreen, 25)
        XCTAssertEqual(stats.peakHour, 2, "a tie goes to the earlier hour")
    }

    func testTheFavouriteToolAndColour() {
        let stats = Stats(defaults: defaults)
        XCTAssertNil(stats.favouriteTool)
        XCTAssertNil(stats.favouriteColour)

        let red = AnnotationStyle.Palette.colors[0]
        stats.noteDrawn(RectangleAnnotation(start: .zero, style: style(red)))
        stats.noteDrawn(RectangleAnnotation(start: .zero, style: style(red)))
        stats.noteDrawn(ArrowAnnotation(start: .zero, style: style(.systemPurple)))

        XCTAssertEqual(stats.value(.rectangles), 2)
        XCTAssertEqual(stats.value(.arrows), 1)
        XCTAssertEqual(stats.value(.ownColour), 1, "a colour off the palette is one's own")
        XCTAssertEqual(stats.favouriteTool, .rectangle)
        XCTAssertEqual(stats.favouriteColour?.index, 0)
        XCTAssertEqual(stats.favouriteColour?.percent, 67)
    }

    /// A blur draws with no colour, so it must not vote for one.
    func testABlurCountsButHasNoColour() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let frame = try CapturedFrame(
            image: XCTUnwrap(context.makeImage()),
            displayFrame: CGRect(x: 0, y: 0, width: 20, height: 20),
            scale: 1
        )
        let document = try XCTUnwrap(EditorDocument(frame: frame, cropRect: CGRect(x: 0, y: 0, width: 20, height: 20)))
        let stats = Stats(defaults: defaults)

        stats.noteDrawn(BlurAnnotation(start: .zero, style: .default, mode: .blur, source: document.blurSource))

        XCTAssertEqual(stats.value(.blurs), 1)
        XCTAssertNil(stats.favouriteColour)
    }
}
