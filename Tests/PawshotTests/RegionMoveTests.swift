import AppKit
@testable import Pawshot
import XCTest

/// The frame a paused recording's region is grabbed by: four bars round it, never over it.
final class RegionMoveTests: XCTestCase {
    private let area = CGRect(x: 100, y: 200, width: 300, height: 150)
    private let thickness: CGFloat = 10

    func testNoBarReachesIntoTheRegion() {
        let bars = SelectionGeometry.grabBars(around: area, thickness: thickness)
        XCTAssertEqual(bars.count, 4)
        for bar in bars {
            XCTAssertFalse(bar.intersects(area), "\(bar) covers part of what is being recorded")
        }
    }

    func testTheBarsCloseTheRingWithNoGapAtTheCorners() {
        let bars = SelectionGeometry.grabBars(around: area, thickness: thickness)
        // A point just outside each side and just outside each corner.
        let outside = [
            CGPoint(x: area.midX, y: area.minY - 5), CGPoint(x: area.midX, y: area.maxY + 5),
            CGPoint(x: area.minX - 5, y: area.midY), CGPoint(x: area.maxX + 5, y: area.midY),
            CGPoint(x: area.minX - 5, y: area.minY - 5), CGPoint(x: area.maxX + 5, y: area.minY - 5),
            CGPoint(x: area.minX - 5, y: area.maxY + 5), CGPoint(x: area.maxX + 5, y: area.maxY + 5),
        ]
        for point in outside {
            XCTAssertTrue(bars.contains { $0.contains(point) }, "\(point) is a gap in the frame")
        }
        // And a point just past the ring is not the frame's business.
        XCTAssertFalse(bars.contains { $0.contains(CGPoint(x: area.midX, y: area.minY - thickness - 1)) })
    }

    func testTheFrameDoesNotSwallowAClickInsideTheRegion() {
        let bars = SelectionGeometry.grabBars(around: area, thickness: thickness)
        XCTAssertFalse(bars.contains { $0.contains(CGPoint(x: area.midX, y: area.midY)) })
        XCTAssertFalse(bars.contains { $0.contains(CGPoint(x: area.minX + 1, y: area.minY + 1)) })
    }

    /// The move itself is `SelectionGeometry.moved`; what the paused region needs from it is that
    /// it keeps its size and stops at the screen's edge.
    func testAMovedRegionKeepsItsSizeAndStopsAtTheScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let moved = SelectionGeometry.moved(area, by: CGSize(width: 5000, height: -5000), within: screen)
        XCTAssertEqual(moved.size, area.size)
        XCTAssertEqual(moved.maxX, screen.maxX)
        XCTAssertEqual(moved.minY, screen.minY)
    }

    // MARK: - Zones to hide

    func testAZoneIsKeptAsFractionsOfTheRegionAndComesBack() throws {
        let region = CGRect(x: 100, y: 200, width: 400, height: 200)
        let zone = CGRect(x: 200, y: 250, width: 100, height: 50)
        let fractions = try XCTUnwrap(SelectionGeometry.zoneFractions(of: zone, in: region))
        XCTAssertEqual(fractions, CGRect(x: 0.25, y: 0.25, width: 0.25, height: 0.25))
        XCTAssertEqual(SelectionGeometry.zone(fromFractions: fractions, in: region), zone)

        // The region moved and doubled: the zone stayed on the same part of the picture.
        let later = CGRect(x: 0, y: 0, width: 800, height: 400)
        XCTAssertEqual(
            SelectionGeometry.zone(fromFractions: fractions, in: later),
            CGRect(x: 200, y: 100, width: 200, height: 100)
        )
    }

    func testAZoneIsCutToTheRegionAndTooSmallOnesAreRefused() throws {
        let region = CGRect(x: 0, y: 0, width: 100, height: 100)
        let spilling = try XCTUnwrap(SelectionGeometry.zoneFractions(of: CGRect(x: 50, y: 50, width: 200, height: 200), in: region))
        XCTAssertEqual(spilling, CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))

        XCTAssertNil(SelectionGeometry.zoneFractions(of: CGRect(x: 10, y: 10, width: 7, height: 50), in: region), "7 pt wide")
        XCTAssertNil(SelectionGeometry.zoneFractions(of: CGRect(x: 300, y: 300, width: 50, height: 50), in: region), "outside")
        // Dragged up and to the left, the rectangle has a negative size; it is the same zone.
        XCTAssertNotNil(SelectionGeometry.zoneFractions(of: CGRect(x: 60, y: 60, width: -30, height: -30), in: region))
    }
}

/// Zones to hide, kept as fractions of the region: where they land in the video, and what a
/// region moved on a pause does to them.
final class HiddenZoneTests: XCTestCase {
    /// Fractions count from the top left, Core Animation from the bottom left: the top 30% of a
    /// 400×200 video is the band from 140 up.
    func testAZoneLandsInCoreAnimationCountedFromTheBottom() throws {
        let layer = try XCTUnwrap(SelectionGeometry.layerRect(
            fractions: CGRect(x: 0, y: 0, width: 1, height: 0.3),
            in: CGSize(width: 400, height: 200)
        ))
        XCTAssertEqual(layer.minX, 0, accuracy: 0.001)
        XCTAssertEqual(layer.minY, 140, accuracy: 0.001)
        XCTAssertEqual(layer.width, 400, accuracy: 0.001)
        XCTAssertEqual(layer.height, 60, accuracy: 0.001)
    }

    /// A zone out of 0…1 — a file edited by hand, or broken — is cut to the picture, and one with
    /// nothing left, or no numbers at all, is not drawn.
    func testAZoneOutsideThePictureIsCutOrLeftOut() throws {
        let size = CGSize(width: 100, height: 100)
        let spilling = try XCTUnwrap(SelectionGeometry.layerRect(fractions: CGRect(x: -0.5, y: 0.5, width: 1, height: 1), in: size))
        XCTAssertEqual(spilling.width, 50, accuracy: 0.001)
        XCTAssertEqual(spilling.height, 50, accuracy: 0.001)
        XCTAssertNil(SelectionGeometry.layerRect(fractions: CGRect(x: 2, y: 0, width: 1, height: 1), in: size))
        XCTAssertNil(SelectionGeometry.layerRect(fractions: CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1), in: size))
    }

    /// The region moved 100 pt to the right on a pause: the zone stays over the same part of the
    /// screen. Until the move it is where it was drawn; from the move on it is counted from the
    /// new region, cut to it.
    func testAZoneStaysOnTheScreenWhenTheRegionMoves() {
        let old = CGRect(x: 100, y: 100, width: 400, height: 200)
        let new = old.offsetBy(dx: 100, dy: 0)
        // The zone: x 200…300 on the screen.
        let zone = EventTimeline.Mask(x: 0.25, y: 0.5, width: 0.25, height: 0.25)

        let (masks, dropped) = EventTimeline.masks([zone], afterMovingFrom: old, to: new, at: 4)
        XCTAssertEqual(dropped, 0)
        XCTAssertEqual(masks.count, 2)
        XCTAssertEqual(masks[0].fractions, zone.fractions)
        XCTAssertNil(masks[0].start)
        XCTAssertEqual(masks[0].end, 4)
        XCTAssertEqual(masks[1].start, 4)
        XCTAssertNil(masks[1].end)
        // x 200…300 is now 0…100 of the new region.
        XCTAssertEqual(masks[1].fractions.minX, 0, accuracy: 0.0001)
        XCTAssertEqual(masks[1].fractions.width, 0.25, accuracy: 0.0001)
        XCTAssertEqual(masks[1].fractions.minY, 0.5, accuracy: 0.0001)
    }

    func testAZoneLeftBehindByTheRegionIsDroppedAndCounted() {
        let old = CGRect(x: 100, y: 100, width: 400, height: 200)
        let new = old.offsetBy(dx: 400, dy: 0)
        let zone = EventTimeline.Mask(x: 0.25, y: 0.5, width: 0.25, height: 0.25)
        let (masks, dropped) = EventTimeline.masks([zone], afterMovingFrom: old, to: new, at: 4)
        XCTAssertEqual(dropped, 1)
        XCTAssertEqual(masks.count, 1, "hidden until the move, gone after it")
        XCTAssertEqual(masks.first?.end, 4)
    }

    /// A zone already closed by an earlier move is history: a second move leaves it alone.
    func testAClosedZoneIsNotMovedAgain() {
        let old = CGRect(x: 0, y: 0, width: 400, height: 200)
        let closed = EventTimeline.Mask(x: 0, y: 0, width: 0.5, height: 0.5, start: nil, end: 2)
        let (masks, dropped) = EventTimeline.masks([closed], afterMovingFrom: old, to: old.offsetBy(dx: 10, dy: 0), at: 5)
        XCTAssertEqual(masks, [closed])
        XCTAssertEqual(dropped, 0)
    }

    /// A moved region keeps everything that is not its place.
    @MainActor
    func testAMovedTargetKeepsItsDisplayItsWindowAndItsZones() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let target = RecordingTarget(displayID: 7, rect: CGRect(x: 0, y: 0, width: 400, height: 200), screen: screen, windowID: nil,
                                     maskZones: [CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)])
        let zones = [CGRect(x: 0.3, y: 0.1, width: 0.2, height: 0.2)]
        let moved = target.moved(to: CGRect(x: 50, y: 60, width: 400, height: 200), maskZones: zones)
        XCTAssertEqual(moved.displayID, 7)
        XCTAssertEqual(moved.rect, CGRect(x: 50, y: 60, width: 400, height: 200))
        XCTAssertNil(moved.windowID)
        XCTAssertEqual(moved.maskZones, zones)
        XCTAssertTrue(moved.screen === screen)
    }

    func testZonesSurviveTheFileAndOlderFilesHaveNone() throws {
        var timeline = EventTimeline()
        timeline.masks = [
            EventTimeline.Mask(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            EventTimeline.Mask(x: 0.1, y: 0.2, width: 0.3, height: 0.4, start: 1, end: 2),
        ]
        let decoded = try JSONDecoder().decode(EventTimeline.self, from: JSONEncoder().encode(timeline))
        XCTAssertEqual(decoded, timeline)

        let old = try JSONDecoder().decode(EventTimeline.self, from: Data(#"{"clicks":[]}"#.utf8))
        XCTAssertTrue(old.masks.isEmpty)
        // A zone from 0.6.4, before zones had a start and an end.
        let zone = try JSONDecoder().decode(EventTimeline.Mask.self, from: Data(#"{"x":0,"y":0,"width":1,"height":1}"#.utf8))
        XCTAssertNil(zone.start)
        XCTAssertNil(zone.end)
    }

    func testAZoneIsSomethingToDraw() {
        var timeline = EventTimeline()
        timeline.masks = [EventTimeline.Mask(x: 0, y: 0, width: 0.5, height: 0.5)]
        XCTAssertFalse(timeline.isEmpty)
        XCTAssertFalse(EffectsOptions().isEmpty(for: timeline))
        XCTAssertTrue(EffectsOptions(masks: false).isEmpty(for: timeline), "switched off in the editor, the video goes out as it is")
    }

    /// The zones drawn on the overlay reach the take's timeline as they are.
    @MainActor
    func testTheZonesDrawnBeforeTheTakeGoIntoItsTimeline() {
        let recorder = EventRecorder(area: CGRect(x: 0, y: 0, width: 400, height: 200)) { nil }
        recorder.setMasks([CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)])
        XCTAssertEqual(recorder.timeline.masks, [EventTimeline.Mask(x: 0.1, y: 0.2, width: 0.3, height: 0.4)])
    }
}

/// The cursor is sampled 60 times a second during a take, and asking the take's clock is a hop
/// onto its sample queue: a mouse that hasn't moved must not ask.
@MainActor
final class CursorSamplingTests: XCTestCase {
    func testAStillMouseDoesNotAskTheClock() {
        var mouse = CGPoint(x: 100, y: 100)
        var asks = 0
        let recorder = EventRecorder(area: CGRect(x: 0, y: 0, width: 400, height: 200)) {
            asks += 1
            return Double(asks)
        }
        recorder.mouseLocation = { mouse }

        recorder.sampleCursor()
        recorder.sampleCursor()
        recorder.sampleCursor()
        XCTAssertEqual(asks, 1, "asked once for the first point, never for the same point again")

        mouse = CGPoint(x: 120, y: 100)
        recorder.sampleCursor()
        XCTAssertEqual(asks, 2, "a move asks again")
    }
}
