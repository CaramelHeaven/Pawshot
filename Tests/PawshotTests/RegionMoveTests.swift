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
