import AppKit
@testable import Pawshot
import XCTest

/// What can be marked while a take runs — a bad stretch to cut, a zoom held for as long as it
/// should last — and what the pill tells about the take: its size, the disk, the time aimed for.
final class TakeMarksTests: XCTestCase {
    // MARK: - The timeline file

    /// A recording made before these marks existed has a timeline without them. It must still be
    /// read, clicks and all: a missing key used to be enough to lose the whole file.
    func testATimelineWrittenByAnOlderBuildIsStillRead() throws {
        let old = Data(#"{"cursor":[],"clicks":[{"time":1.5,"x":0.2,"y":0.3}],"keys":[],"zoomMarks":[2]}"#.utf8)
        let timeline = try JSONDecoder().decode(EventTimeline.self, from: old)

        XCTAssertEqual(timeline.clicks, [EventTimeline.Point(time: 1.5, x: 0.2, y: 0.3)])
        XCTAssertEqual(timeline.zoomMarks, [2])
        XCTAssertTrue(timeline.zoomHolds.isEmpty)
        XCTAssertTrue(timeline.badTakes.isEmpty)
    }

    func testMarksSurviveTheFile() throws {
        var timeline = EventTimeline()
        timeline.zoomHolds = [EventTimeline.Span(start: 3, end: 6.5)]
        timeline.badTakes = [EventTimeline.Span(start: 10, end: 20)]

        let decoded = try JSONDecoder().decode(EventTimeline.self, from: JSONEncoder().encode(timeline))
        XCTAssertEqual(decoded, timeline)
    }

    func testAHeldZoomCountsAsAZoom() {
        var timeline = EventTimeline()
        XCTAssertFalse(timeline.hasZooms)
        timeline.zoomHolds = [EventTimeline.Span(start: 3, end: 6)]
        XCTAssertTrue(timeline.hasZooms)
        XCTAssertFalse(timeline.isEmpty)
        XCTAssertFalse(EffectsOptions().isEmpty(for: timeline))
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

    // MARK: - A zoom held

    /// A tap is a mark, as it always was; held longer, the zoom lasts from the press to the release.
    func testAZoomKeyHeldPastAThirdOfASecondIsAHold() {
        XCTAssertFalse(EffectsPlanner.isZoomHold(heldFor: 0.2))
        XCTAssertTrue(EffectsPlanner.isZoomHold(heldFor: 0.5))
    }

    func testAHeldZoomLastsFromThePressToTheReleaseAndFollowsTheCursor() {
        var timeline = EventTimeline()
        timeline.cursor = [.init(time: 0, x: 0.2, y: 0.2), .init(time: 5, x: 0.8, y: 0.6)]
        timeline.zoomHolds = [EventTimeline.Span(start: 4, end: 7)]

        let segments = EffectsPlanner.zoomSegments(timeline: timeline, duration: 30)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].start, 4)
        XCTAssertEqual(segments[0].end, 7 + EffectsPlanner.zoomRamp, accuracy: 0.001, "the way out comes after the release")
        XCTAssertTrue(segments[0].follows)

        let path = EffectsPlanner.zoomPath(of: segments[0], from: 4, to: 7.4, timeline: timeline)
        XCTAssertEqual(path.first?.center, CGPoint(x: 0.2, y: 0.2))
        XCTAssertEqual(path.last?.center, CGPoint(x: 0.8, y: 0.6), "the zoom went where the cursor went")
        XCTAssertGreaterThan(path.count, 10)
    }

    func testAMarkedZoomStaysWhereItWasMarked() {
        var timeline = EventTimeline()
        timeline.cursor = [.init(time: 0, x: 0.2, y: 0.2), .init(time: 5, x: 0.8, y: 0.6)]
        timeline.zoomMarks = [4]

        let segment = EffectsPlanner.zoomSegments(timeline: timeline, duration: 30)[0]
        XCTAssertFalse(segment.follows)
        let path = EffectsPlanner.zoomPath(of: segment, from: segment.start, to: segment.end, timeline: timeline)
        XCTAssertEqual(Set(path.map(\.center.x)), [0.2])
    }

    /// A mark close behind a held zoom extends it, the way marks always merged.
    func testMarksAndHoldsMerge() {
        var timeline = EventTimeline()
        timeline.zoomHolds = [EventTimeline.Span(start: 4, end: 7)]
        timeline.zoomMarks = [7.6, 20]

        let segments = EffectsPlanner.zoomSegments(timeline: timeline, duration: 30)
        XCTAssertEqual(segments.map(\.start), [4, 20])
        XCTAssertEqual(segments[0].end, 7.6 + EffectsPlanner.zoomLength, accuracy: 0.001)
    }

    /// In the file a held zoom is one animation that glides: more steps than the four of a marked
    /// zoom, and its first zoomed frame is not its last.
    func testTheExportGlidesAHeldZoomAlongTheCursor() throws {
        var timeline = EventTimeline()
        timeline.cursor = [.init(time: 0, x: 0.2, y: 0.2), .init(time: 5, x: 0.8, y: 0.6)]
        timeline.zoomHolds = [EventTimeline.Span(start: 4, end: 7)]
        let video = CALayer()

        _ = EffectsLayerBuilder.build(
            timeline: timeline, options: EffectsOptions(),
            videoSize: CGSize(width: 800, height: 600), keep: KeepRanges(duration: 30),
            videoLayer: video
        )

        let content = try XCTUnwrap(video.superlayer)
        let key = try XCTUnwrap(content.animationKeys()?.first)
        let zoom = try XCTUnwrap(content.animation(forKey: key) as? CAKeyframeAnimation)
        XCTAssertEqual(zoom.beginTime, 4)
        XCTAssertEqual(zoom.duration, 3 + EffectsPlanner.zoomRamp, accuracy: 0.001)

        let frames = try XCTUnwrap(zoom.values as? [NSValue]).map(\.caTransform3DValue)
        XCTAssertGreaterThan(frames.count, 10)
        XCTAssertEqual(zoom.keyTimes?.count, frames.count)
        XCTAssertEqual(zoom.timingFunctions?.count, frames.count - 1)
        XCTAssertTrue(CATransform3DIsIdentity(frames[0]))
        XCTAssertTrue(CATransform3DIsIdentity(frames[frames.count - 1]))
        XCTAssertNotEqual(frames[1].m41, frames[frames.count - 2].m41, "the picture moved with the cursor")
    }

    /// A marked zoom is what it always was: in, hold, out.
    func testAMarkedZoomIsStillFourSteps() throws {
        var timeline = EventTimeline()
        timeline.zoomMarks = [4]
        let video = CALayer()
        _ = EffectsLayerBuilder.build(
            timeline: timeline, options: EffectsOptions(),
            videoSize: CGSize(width: 800, height: 600), keep: KeepRanges(duration: 30),
            videoLayer: video
        )

        let content = try XCTUnwrap(video.superlayer)
        let key = try XCTUnwrap(content.animationKeys()?.first)
        let zoom = try XCTUnwrap(content.animation(forKey: key) as? CAKeyframeAnimation)
        XCTAssertEqual(zoom.values?.count, 4)
        XCTAssertEqual(zoom.duration, EffectsPlanner.zoomLength, accuracy: 0.001)
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
