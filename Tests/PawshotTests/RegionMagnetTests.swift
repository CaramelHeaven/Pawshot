import AppKit
@testable import Pawshot
import XCTest

/// The arithmetic behind the recording region's grips, its magnet and the drop onto a window.
final class RegionMagnetTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let region = CGRect(x: 100, y: 100, width: 400, height: 300)

    // MARK: - A press that is not yet a drag

    func testAPressBecomesADragPastThreePoints() {
        let press = CGPoint(x: 600, y: 400)
        XCTAssertFalse(SelectionGeometry.isDrag(from: press, to: press))
        XCTAssertFalse(SelectionGeometry.isDrag(from: press, to: CGPoint(x: 602, y: 402)))
        XCTAssertTrue(SelectionGeometry.isDrag(from: press, to: CGPoint(x: 604, y: 400)))
    }

    // MARK: - Grip pills

    func testPillsSitOnTheMiddlesOfTheEdgesAndTheHotOneGrows() throws {
        let pills = SelectionGeometry.gripPills(for: region, hot: .right)
        XCTAssertEqual(pills.map(\.handle), [.top, .bottom, .left, .right])

        let top = try XCTUnwrap(pills.first { $0.handle == .top }).frame
        XCTAssertEqual(top.midX, region.midX)
        XCTAssertEqual(top.midY, region.minY, "centred on the edge line")
        XCTAssertEqual(top.size, CGSize(width: 34, height: 5))

        let right = try XCTUnwrap(pills.first { $0.handle == .right }).frame
        XCTAssertEqual(right.midX, region.maxX)
        XCTAssertEqual(right.size, CGSize(width: 7, height: 56), "the pill under the cursor is longer and thicker")
    }

    /// A pill on a short side would run into the corner brackets.
    func testAShortSideHasNoPill() {
        let thin = CGRect(x: 100, y: 100, width: 400, height: 60)
        XCTAssertEqual(SelectionGeometry.gripPills(for: thin, hot: nil).map(\.handle), [.top, .bottom])
    }

    func testNearReachesFortyFourPointsAroundTheRegion() {
        XCTAssertTrue(SelectionGeometry.isNear(CGPoint(x: 60, y: 250), to: region))
        XCTAssertTrue(SelectionGeometry.isNear(CGPoint(x: 300, y: 250), to: region), "inside is near")
        XCTAssertFalse(SelectionGeometry.isNear(CGPoint(x: 50, y: 250), to: region))
    }

    // MARK: - The magnet

    private let window = CGRect(x: 520, y: 80, width: 300, height: 400)

    func testMovingSticksAnEdgeToAWindowEdgeAndSaysWhere() {
        let lines = SelectionGeometry.snapLines(windows: [window], bounds: bounds, around: region)
        // The region's right edge is 4 pt short of the window's left edge.
        let moving = CGRect(x: 116, y: 300, width: 400, height: 300)
        let snapped = SelectionGeometry.snapped(moving: moving, to: lines, within: bounds)

        XCTAssertEqual(snapped.rect.maxX, 520)
        XCTAssertEqual(snapped.rect.size, moving.size, "sticking never resizes")
        XCTAssertEqual(snapped.guides.x, 520)
        XCTAssertNil(snapped.guides.y)
    }

    func testMovingSticksTheMiddleToTheMiddleOfTheScreen() {
        let lines = SelectionGeometry.snapLines(windows: [], bounds: bounds, around: region)
        let moving = CGRect(x: 303, y: 253, width: 400, height: 300)
        let snapped = SelectionGeometry.snapped(moving: moving, to: lines, within: bounds)

        XCTAssertEqual(snapped.rect.midX, 500)
        XCTAssertEqual(snapped.rect.midY, 400)
        XCTAssertEqual(snapped.guides, SelectionGeometry.SnapGuides(x: 500, y: 400))
    }

    func testNothingSticksOutsideTheTolerance() {
        let lines = SelectionGeometry.snapLines(windows: [window], bounds: bounds, around: region)
        let moving = CGRect(x: 100, y: 120, width: 400, height: 300)
        let snapped = SelectionGeometry.snapped(moving: moving, to: lines, within: bounds)

        XCTAssertEqual(snapped.rect, moving)
        XCTAssertEqual(snapped.guides, SelectionGeometry.SnapGuides())
    }

    /// The list is front to back. An edge lying under a window in front can't be seen, and a
    /// region that stuck to it would look like it stuck to nothing.
    func testAnEdgeHiddenUnderAWindowInFrontIsNoTarget() {
        let front = CGRect(x: 400, y: 0, width: 300, height: 800)
        let lines = SelectionGeometry.snapLines(windows: [front, window], bounds: bounds, around: region)

        XCTAssertFalse(lines.xs.contains(520), "the window's left edge is under the one in front")
        XCTAssertTrue(lines.xs.contains(820), "its right edge sticks out and counts")
        XCTAssertTrue(lines.xs.contains(400))
    }

    func testResizingSticksOnlyTheDraggedEdge() {
        let lines = SelectionGeometry.snapLines(windows: [window], bounds: bounds, around: region)
        let right = SelectionGeometry.snapped(CGPoint(x: 517, y: 83), dragging: .right, to: lines)
        XCTAssertEqual(right.point, CGPoint(x: 520, y: 83), "a right edge has no business with the lines across")
        XCTAssertEqual(right.guides, SelectionGeometry.SnapGuides(x: 520, y: nil))

        let corner = SelectionGeometry.snapped(CGPoint(x: 517, y: 83), dragging: .topRight, to: lines)
        XCTAssertEqual(corner.point, CGPoint(x: 520, y: 80))
    }

    // MARK: - The drop onto a window

    func testFitIsOfferedMiddleToMiddleOnly() {
        // The window is 300 × 400: the middle has to come within 45 pt of (670, 280) both ways.
        XCTAssertEqual(SelectionGeometry.fitCandidate(center: CGPoint(x: 700, y: 300), windows: [window]), 0)
        XCTAssertNil(SelectionGeometry.fitCandidate(center: CGPoint(x: 720, y: 300), windows: [window]), "inside the window, off its middle")
        XCTAssertNil(SelectionGeometry.fitCandidate(center: CGPoint(x: 100, y: 700), windows: [window]), "over no window")
    }

    func testFitGoesToTheWindowOnTopUnderTheMiddle() {
        let front = CGRect(x: 600, y: 200, width: 200, height: 200)
        XCTAssertEqual(SelectionGeometry.fitCandidate(center: CGPoint(x: 700, y: 300), windows: [front, window]), 0)
        // Near the middle of the one behind, but a different window is on top there.
        XCTAssertNil(SelectionGeometry.fitCandidate(center: CGPoint(x: 640, y: 260), windows: [front, window]))
    }

    func testAWindowTooSmallToRecordIsNotOffered() {
        let palette = CGRect(x: 600, y: 200, width: 40, height: 200)
        XCTAssertNil(SelectionGeometry.fitCandidate(center: CGPoint(x: 620, y: 300), windows: [palette]))
    }

    /// Grabbed again, a fitted region goes back to the size it had, and the spot under the cursor
    /// stays the same share of the region.
    func testRestoringKeepsTheGrabbedShareUnderTheCursor() {
        let restored = SelectionGeometry.restored(
            size: CGSize(width: 200, height: 100),
            grabbedAt: CGPoint(x: 595, y: 380),
            in: window,
            within: bounds
        )
        // A quarter along and three quarters down the window: the same in the restored region.
        XCTAssertEqual(restored, CGRect(x: 545, y: 305, width: 200, height: 100))
    }

    func testRestoringStaysOnTheScreen() {
        let restored = SelectionGeometry.restored(
            size: CGSize(width: 600, height: 500), grabbedAt: CGPoint(x: 810, y: 90), in: window, within: bounds
        )
        XCTAssertTrue(bounds.contains(restored))
        XCTAssertEqual(restored.size, CGSize(width: 600, height: 500))
    }

    // MARK: - ⌥, the arrows, the toolbar

    func testResizingFromTheMiddleGrowsBothWays() {
        let wider = SelectionGeometry.resized(
            region, dragging: .right, to: CGPoint(x: 540, y: 0), aspect: nil, within: bounds, fromCenter: true
        )
        XCTAssertEqual(wider, CGRect(x: 60, y: 100, width: 480, height: 300))

        let corner = SelectionGeometry.resized(
            region, dragging: .bottomRight, to: CGPoint(x: 520, y: 430), aspect: nil, within: bounds, fromCenter: true
        )
        XCTAssertEqual(corner, CGRect(x: 80, y: 70, width: 440, height: 360))
    }

    func testResizingFromTheMiddleStopsAtTheScreen() {
        let wide = SelectionGeometry.resized(
            region, dragging: .left, to: CGPoint(x: -500, y: 0), aspect: nil, within: bounds, fromCenter: true
        )
        XCTAssertEqual(wide.minX, 0)
        XCTAssertEqual(wide.midX, region.midX, "still about its middle")
    }

    /// ⌥ with the proportions held, by an edge of the screen: the side that runs out of room
    /// takes the other one down with it — the region stays at its proportions.
    func testResizingFromTheMiddleKeepsTheProportionsAtTheScreensEdge() {
        let nearTheLeft = CGRect(x: 50, y: 300, width: 100, height: 100)
        let grown = SelectionGeometry.resized(
            nearTheLeft, dragging: .bottomRight, to: CGPoint(x: 300, y: 500), aspect: 1, within: bounds, fromCenter: true
        )
        XCTAssertEqual(grown.width / grown.height, 1, accuracy: 0.01, "\(grown)")
        XCTAssertGreaterThanOrEqual(grown.minX, bounds.minX)
        XCTAssertEqual(grown.midX, nearTheLeft.midX, accuracy: 0.5, "still about its middle")
    }

    func testArrowsMoveOrResizeAndStayInside() {
        XCTAssertEqual(
            SelectionGeometry.nudged(region, by: CGSize(width: 10, height: 0), resizing: false, within: bounds),
            CGRect(x: 110, y: 100, width: 400, height: 300)
        )
        XCTAssertEqual(
            SelectionGeometry.nudged(region, by: CGSize(width: -2000, height: 0), resizing: false, within: bounds).minX, 0
        )
        XCTAssertEqual(
            SelectionGeometry.nudged(region, by: CGSize(width: 0, height: -10), resizing: true, within: bounds),
            CGRect(x: 100, y: 100, width: 400, height: 290)
        )
        XCTAssertEqual(
            SelectionGeometry.nudged(region, by: CGSize(width: 5000, height: 0), resizing: true, within: bounds).maxX, 1000
        )
        let tiny = SelectionGeometry.nudged(region, by: CGSize(width: -5000, height: 0), resizing: true, within: bounds)
        XCTAssertFalse(SelectionGeometry.isTooSmall(tiny), "an arrow never shrinks the region out of reach")
    }

    func testToolbarSitsInTheMiddleAboveTheBottomEdge() {
        let origin = SelectionGeometry.toolbarOrigin(toolbarSize: CGSize(width: 360, height: 44), bounds: bounds)
        XCTAssertEqual(origin, CGPoint(x: 320, y: 800 - 44 - 48))
    }

    func testTheSizeLabelStaysBesideTheDraggedEdge() {
        let label = CGSize(width: 60, height: 18)
        let right = SelectionGeometry.edgeLabelOrigin(for: .right, of: region, labelSize: label, bounds: bounds)
        XCTAssertEqual(right, CGPoint(x: 508, y: 241))
        let top = SelectionGeometry.edgeLabelOrigin(for: .top, of: region, labelSize: label, bounds: bounds)
        XCTAssertEqual(top, CGPoint(x: 270, y: 74))

        // A region touching the right edge of the screen: the label comes inside instead of leaving.
        let flush = CGRect(x: 600, y: 100, width: 400, height: 300)
        let inside = SelectionGeometry.edgeLabelOrigin(for: .right, of: flush, labelSize: label, bounds: bounds)
        XCTAssertEqual(inside.x, 1000 - 60)
    }
}

final class MicrophoneDevicesTests: XCTestCase {
    private let builtIn = MicrophoneDevices.Device(id: "built-in", name: "MacBook Pro Microphone")
    private let airPods = MicrophoneDevices.Device(id: "airpods", name: "AirPods")

    func testThePickedMicrophoneIsUsedWhileItIsPluggedIn() {
        XCTAssertEqual(
            MicrophoneDevices.resolved(stored: "airpods", among: [builtIn, airPods], systemDefault: "built-in"),
            "airpods"
        )
    }

    /// AirPods back in their case: the take must not start on a device that isn't there.
    func testAMicrophoneThatIsGoneFallsBackToTheSystemOne() {
        XCTAssertEqual(MicrophoneDevices.resolved(stored: "airpods", among: [builtIn], systemDefault: "built-in"), "built-in")
        XCTAssertEqual(MicrophoneDevices.resolved(stored: nil, among: [builtIn, airPods], systemDefault: "airpods"), "airpods")
    }

    func testWithNoInputThereIsNothingToRecordFrom() {
        XCTAssertNil(MicrophoneDevices.resolved(stored: "airpods", among: [], systemDefault: nil))
    }
}
