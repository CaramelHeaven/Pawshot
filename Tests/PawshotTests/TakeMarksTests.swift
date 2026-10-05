import AppKit
@testable import Pawshot
import XCTest

/// What can be marked while a take runs — a bad stretch to cut — and what the pill tells about the
/// take: its size, the disk, the time aimed for.
final class TakeMarksTests: XCTestCase {
    // MARK: - The timeline file

    /// A recording made before these marks existed has a timeline without them, and one from
    /// 0.6.1–0.6.8 has zooms the app no longer knows. It must still be read, clicks and all: a
    /// missing key used to be enough to lose the whole file.
    func testATimelineWrittenByAnOlderBuildIsStillRead() throws {
        let old = Data(#"{"cursor":[],"clicks":[{"time":1.5,"x":0.2,"y":0.3}],"keys":[],"zoomMarks":[2],"zoomHolds":[{"start":1,"end":2}]}"#.utf8)
        let timeline = try JSONDecoder().decode(EventTimeline.self, from: old)

        XCTAssertEqual(timeline.clicks, [EventTimeline.Point(time: 1.5, x: 0.2, y: 0.3)])
        XCTAssertTrue(timeline.badTakes.isEmpty)
        XCTAssertNil(timeline.framesPerSecond, "a take from before 0.6.11 says no frame rate")
    }

    func testMarksSurviveTheFile() throws {
        var timeline = EventTimeline()
        timeline.badTakes = [EventTimeline.Span(start: 10, end: 20)]
        timeline.framesPerSecond = 15

        let decoded = try JSONDecoder().decode(EventTimeline.self, from: JSONEncoder().encode(timeline))
        XCTAssertEqual(decoded, timeline)
    }

    // MARK: - A bad take

    func testABadTakeIsTheLastTenSeconds() {
        XCTAssertEqual(EventTimeline.badTake(endingAt: 42, after: []), EventTimeline.Span(start: 32, end: 42))
        XCTAssertEqual(EventTimeline.badTake(endingAt: 4, after: []), EventTimeline.Span(start: 0, end: 4), "not before the take began")
    }

    /// Pressed twice in a row, the second mark cuts only what came after the first.
    func testABadTakeNeverReachesBackIntoTheOneBefore() {
        let first = EventTimeline.Span(start: 32, end: 42)
        XCTAssertEqual(EventTimeline.badTake(endingAt: 47, after: [first]), EventTimeline.Span(start: 42, end: 47))
        XCTAssertNil(EventTimeline.badTake(endingAt: 42.2, after: [first]), "a second press at once has nothing to cut")
    }

    // MARK: - Cutting a stretch out of the pieces

    func testACutInTheMiddleLeavesTwoPieces() {
        var keep = KeepRanges(duration: 60)
        XCTAssertTrue(keep.cut(from: 20, to: 30))
        XCTAssertEqual(keep.pieces, [.init(start: 0, end: 20), .init(start: 30, end: 60)])
        XCTAssertEqual(keep.totalLength, 50)
    }

    func testACutAtTheStartOrAcrossPieces() {
        var keep = KeepRanges(duration: 60)
        keep.cut(from: 0, to: 10)
        XCTAssertEqual(keep.pieces, [.init(start: 10, end: 60)])

        keep.cut(from: 20, to: 30)
        keep.cut(from: 25, to: 45)
        XCTAssertEqual(keep.pieces, [.init(start: 10, end: 20), .init(start: 45, end: 60)], "a cut takes what it overlaps of every piece")
    }

    /// What is left of a piece under half a second goes with the cut: a sliver can't be grabbed.
    func testACutDoesNotLeaveSlivers() {
        var keep = KeepRanges(duration: 60)
        keep.cut(from: 0.3, to: 30)
        XCTAssertEqual(keep.pieces, [.init(start: 30, end: 60)])
    }

    func testACutNeverTakesEverything() {
        var keep = KeepRanges(duration: 8)
        XCTAssertFalse(keep.cut(from: 0, to: 8), "a recording with nothing kept is not a recording")
        XCTAssertEqual(keep.pieces, [.init(start: 0, end: 8)])
        XCTAssertFalse(keep.cut(from: 5, to: 5))
    }

    // MARK: - What the pill tells

    func testDiskTimeLeftGoesByTheRateSoFar() {
        // 100 MB in 50 s is 2 MB a second: 600 MB free lasts five minutes.
        XCTAssertEqual(
            RecordingBudget.secondsLeft(freeBytes: 600_000_000, writtenBytes: 100_000_000, elapsed: 50),
            300
        )
        XCTAssertNil(
            RecordingBudget.secondsLeft(freeBytes: 600_000_000, writtenBytes: 0, elapsed: 3),
            "nothing to go by until the first part of the file is written"
        )
    }

    func testTheDiskWarningComesWithFiveMinutesLeft() {
        XCTAssertFalse(RecordingBudget.isRunningOut(secondsLeft: 900))
        XCTAssertTrue(RecordingBudget.isRunningOut(secondsLeft: 240))
        XCTAssertFalse(RecordingBudget.isRunningOut(secondsLeft: nil))
    }

    func testTheGoalFillsUpAndTurnsInItsLastTenSeconds() throws {
        XCTAssertNil(RecordingBudget.goal(elapsed: 30, goal: 0), "no goal, no bar")

        let half = try XCTUnwrap(RecordingBudget.goal(elapsed: 30, goal: 60))
        XCTAssertEqual(half.fraction, 0.5)
        XCTAssertFalse(half.isClose)

        XCTAssertTrue(try XCTUnwrap(RecordingBudget.goal(elapsed: 52, goal: 60)).isClose)
        let over = try XCTUnwrap(RecordingBudget.goal(elapsed: 75, goal: 60))
        XCTAssertEqual(over.fraction, 1)
        XCTAssertTrue(over.isClose)
    }
}
