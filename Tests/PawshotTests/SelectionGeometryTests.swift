import CoreGraphics
@testable import Pawshot
import XCTest

final class SelectionGeometryTests: XCTestCase {
    func testRectNormalizesDragInAnyDirection() {
        let downRight = SelectionGeometry.rect(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 110, y: 220))
        let upLeft = SelectionGeometry.rect(from: CGPoint(x: 110, y: 220), to: CGPoint(x: 10, y: 20))

        XCTAssertEqual(downRight, CGRect(x: 10, y: 20, width: 100, height: 200))
        XCTAssertEqual(upLeft, downRight)
    }

    /// Clockwise on screen, with Y going down: the top left corner lands top right.
    func testQuarterTurnClockwiseTakesTopLeftToTopRight() {
        let size = CGSize(width: 400, height: 300)
        XCTAssertEqual(SelectionGeometry.rotatedQuarter(.zero, in: size, clockwise: true), CGPoint(x: 300, y: 0))
        XCTAssertEqual(
            SelectionGeometry.rotatedQuarter(CGPoint(x: 400, y: 300), in: size, clockwise: true),
            CGPoint(x: 0, y: 400)
        )
        XCTAssertEqual(SelectionGeometry.rotatedQuarter(.zero, in: size, clockwise: false), CGPoint(x: 0, y: 400))
    }

    func testQuarterTurnThereAndBackIsTheSamePoint() {
        let size = CGSize(width: 400, height: 300)
        let point = CGPoint(x: 37, y: 12)
        let turned = SelectionGeometry.rotatedQuarter(point, in: size, clockwise: true)
        let back = SelectionGeometry.rotatedQuarter(
            turned,
            in: CGSize(width: size.height, height: size.width),
            clockwise: false
        )
        XCTAssertEqual(back, point)
    }

    /// Turning about a point, Y down: what was to the right of the centre ends up below it.
    func testQuarterTurnAroundAPoint() {
        let centre = CGPoint(x: 10, y: 10)
        let right = CGPoint(x: 12, y: 10)
        XCTAssertEqual(SelectionGeometry.rotatedQuarter(right, around: centre, clockwise: true), CGPoint(x: 10, y: 12))
        XCTAssertEqual(SelectionGeometry.rotatedQuarter(right, around: centre, clockwise: false), CGPoint(x: 10, y: 8))
    }

    /// The shot is where both sides meet: SwiftUI has it at y 50…250 (down), AppKit at y 20…220 (up).
    /// A panel at SwiftUI y 200…240, near the shot's bottom, is at AppKit y 30…70.
    func testSwiftUIFrameMapsOntoTheWindowThroughTheShot() {
        let mapped = SelectionGeometry.windowRect(
            fromSwiftUI: CGRect(x: 60, y: 200, width: 100, height: 40),
            shotInSwiftUI: CGRect(x: 10, y: 50, width: 300, height: 200),
            shotInWindow: CGRect(x: 10, y: 20, width: 300, height: 200)
        )
        XCTAssertEqual(mapped, CGRect(x: 60, y: 30, width: 100, height: 40))
    }

    /// The tools over the shot: 75%…150%, and never wider than the window.
    func testToolsScaleStaysWithinItsLimits() {
        XCTAssertEqual(SelectionGeometry.toolsScale(2, panelWidth: 400, availableWidth: 1000), 1.5)
        XCTAssertEqual(SelectionGeometry.toolsScale(0.5, panelWidth: 400, availableWidth: 1000), 0.75)
        XCTAssertEqual(SelectionGeometry.toolsScale(1.4, panelWidth: 400, availableWidth: 480), 1.2, accuracy: 0.0001)
        XCTAssertEqual(SelectionGeometry.toolsScale(1, panelWidth: 400, availableWidth: 200), 0.75, "a tiny window scrolls")
    }

    func testCornerNearAPointAndItsOpposite() {
        let rect = CGRect(x: 10, y: 10, width: 100, height: 50)
        XCTAssertEqual(SelectionGeometry.corner(of: rect, near: CGPoint(x: 108, y: 62), radius: 4), .bottomRight)
        XCTAssertNil(SelectionGeometry.corner(of: rect, near: CGPoint(x: 60, y: 30), radius: 4))
        XCTAssertEqual(SelectionGeometry.Corner.bottomRight.opposite, .topLeft)
    }

    func testCornerScaleIsTheDistanceRatioFromTheAnchor() {
        let scale = SelectionGeometry.cornerScale(anchor: .zero, start: CGPoint(x: 30, y: 40), current: CGPoint(x: 60, y: 80))
        XCTAssertEqual(scale, 2, accuracy: 0.0001)
    }

    func testQuarterTurnOfARectComesBackNormalised() {
        let turned = SelectionGeometry.rotatedQuarter(
            CGRect(x: 10, y: 20, width: 50, height: 30),
            in: CGSize(width: 400, height: 300),
            clockwise: true
        )
        XCTAssertEqual(turned, CGRect(x: 250, y: 10, width: 30, height: 50))
    }

    func testTooSmallCatchesClickAndShakyHand() {
        XCTAssertTrue(SelectionGeometry.isTooSmall(CGRect(x: 0, y: 0, width: 0, height: 0)))
        XCTAssertTrue(SelectionGeometry.isTooSmall(CGRect(x: 0, y: 0, width: 3, height: 100)))
        XCTAssertFalse(SelectionGeometry.isTooSmall(CGRect(x: 0, y: 0, width: 4, height: 4)))
    }

    /// The primary screen is 1440 tall. A rectangle pinned to its top in AppKit coordinates has
    /// to end up at y = 0 in CoreGraphics.
    func testConvertToCoreGraphicsFlipsY() {
        let appKit = CGRect(x: 100, y: 1340, width: 200, height: 100)

        let cg = SelectionGeometry.convertToCoreGraphics(rect: appKit, primaryScreenMaxY: 1440)

        XCTAssertEqual(cg, CGRect(x: 100, y: 0, width: 200, height: 100))
    }

    func testConvertToCoreGraphicsIsReversible() {
        let appKit = CGRect(x: 40, y: 500, width: 320, height: 240)

        let cg = SelectionGeometry.convertToCoreGraphics(rect: appKit, primaryScreenMaxY: 1440)
        let back = SelectionGeometry.convertToCoreGraphics(rect: cg, primaryScreenMaxY: 1440)

        XCTAssertEqual(back, appKit)
    }

    func testSourceRectIsRelativeToDisplay() {
        let display = CGRect(x: 2560, y: 0, width: 1920, height: 1080)
        let global = CGRect(x: 2600, y: 100, width: 300, height: 200)

        let source = SelectionGeometry.sourceRect(displayRect: global, displayFrame: display)

        XCTAssertEqual(source, CGRect(x: 40, y: 100, width: 300, height: 200))
    }

    func testPixelSizeUsesDisplayScaleAndNeverCollapses() {
        let retina = SelectionGeometry.pixelSize(of: CGRect(x: 0, y: 0, width: 100, height: 50), scale: 2)
        XCTAssertEqual(retina.width, 200)
        XCTAssertEqual(retina.height, 100)

        let sliver = SelectionGeometry.pixelSize(of: CGRect(x: 0, y: 0, width: 0.2, height: 0.2), scale: 1)
        XCTAssertEqual(sliver.width, 1)
        XCTAssertEqual(sliver.height, 1)
    }

    func testCropRectScalesSelectionToPixels() {
        let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)

        let crop = SelectionGeometry.cropRect(
            displayRect: CGRect(x: 100, y: 50, width: 200, height: 100),
            displayFrame: display,
            scale: 2,
            imagePixelSize: CGSize(width: 3456, height: 2234)
        )

        XCTAssertEqual(crop, CGRect(x: 200, y: 100, width: 400, height: 200))
    }

    func testCropRectIsRelativeToItsOwnDisplay() {
        let display = CGRect(x: 2560, y: 0, width: 1920, height: 1080)

        let crop = SelectionGeometry.cropRect(
            displayRect: CGRect(x: 2600, y: 100, width: 300, height: 200),
            displayFrame: display,
            scale: 1,
            imagePixelSize: CGSize(width: 1920, height: 1080)
        )

        XCTAssertEqual(crop, CGRect(x: 40, y: 100, width: 300, height: 200))
    }

    /// The drag can run past the screen edge — the region has to be clipped to the frame instead
    /// of running outside it.
    func testCropRectClampsToFrameBounds() {
        let display = CGRect(x: 0, y: 0, width: 100, height: 100)

        let crop = SelectionGeometry.cropRect(
            displayRect: CGRect(x: 90, y: 90, width: 20, height: 20),
            displayFrame: display,
            scale: 1,
            imagePixelSize: CGSize(width: 100, height: 100)
        )

        XCTAssertEqual(crop, CGRect(x: 90, y: 90, width: 10, height: 10))
    }

    func testCropRectNeverCollapsesOnThinSelection() {
        let display = CGRect(x: 0, y: 0, width: 100, height: 100)

        let crop = SelectionGeometry.cropRect(
            displayRect: CGRect(x: 10, y: 10, width: 0.2, height: 0.2),
            displayFrame: display,
            scale: 1,
            imagePixelSize: CGSize(width: 100, height: 100)
        )

        XCTAssertEqual(crop, CGRect(x: 10, y: 10, width: 1, height: 1))
    }

    func testCropRectIsNilOutsideFrame() {
        let display = CGRect(x: 0, y: 0, width: 100, height: 100)

        let crop = SelectionGeometry.cropRect(
            displayRect: CGRect(x: 200, y: 200, width: 10, height: 10),
            displayFrame: display,
            scale: 1,
            imagePixelSize: CGSize(width: 100, height: 100)
        )

        XCTAssertNil(crop)
    }

    func testBadgeSitsBelowRightOfCursor() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)

        let origin = SelectionGeometry.badgeOrigin(
            cursor: CGPoint(x: 400, y: 300),
            badgeSize: CGSize(width: 120, height: 20),
            bounds: bounds
        )

        XCTAssertEqual(origin, CGPoint(x: 414, y: 314))
    }

    func testBadgeFlipsNearScreenEdges() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let badge = CGSize(width: 120, height: 20)

        let origin = SelectionGeometry.badgeOrigin(cursor: CGPoint(x: 990, y: 795), badgeSize: badge, bounds: bounds)

        XCTAssertEqual(origin.x, 990 - 14 - 120)
        XCTAssertEqual(origin.y, 795 - 14 - 20)
    }

    func testBadgeStaysInsideBoundsWhenNothingFits() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 40)

        let origin = SelectionGeometry.badgeOrigin(
            cursor: CGPoint(x: 50, y: 20),
            badgeSize: CGSize(width: 120, height: 60),
            bounds: bounds
        )

        XCTAssertEqual(origin, CGPoint(x: 0, y: 0))
    }

    /// The overlay has to show the badge and the window highlight before the mouse moves, and for
    /// that the current mouse position has to cross two coordinate systems: AppKit's global one
    /// (origin bottom left, Y up) into a flipped view local to its screen.
    func testMousePositionBecomesAPointInsideTheOverlay() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

        // Top left corner of the screen in AppKit terms is y = maxY.
        XCTAssertEqual(
            SelectionGeometry.viewPoint(forMouse: CGPoint(x: 0, y: 900), on: screen),
            CGPoint(x: 0, y: 0)
        )
        XCTAssertEqual(
            SelectionGeometry.viewPoint(forMouse: CGPoint(x: 200, y: 800), on: screen),
            CGPoint(x: 200, y: 100)
        )
    }

    /// A second display sits at an offset in the global space; the point has to come back local to
    /// its own overlay, not to the primary screen.
    func testMousePositionOnASecondDisplayIsLocalToThatDisplay() {
        let secondary = CGRect(x: 1440, y: 0, width: 1920, height: 1080)

        let point = SelectionGeometry.viewPoint(
            forMouse: CGPoint(x: 1540, y: 1000),
            on: secondary
        )

        XCTAssertEqual(point, CGPoint(x: 100, y: 80))
    }

    // MARK: - Resizing the crop

    private let frameSize = CGSize(width: 1000, height: 800)
    private let crop = CGRect(x: 300, y: 200, width: 200, height: 200)

    /// Dragging one edge must leave the opposite one exactly where it was, otherwise the shot
    /// slides sideways instead of growing.
    func testGrowingLeftEdgeKeepsRightEdgeStill() {
        let grown = SelectionGeometry.resizedCrop(
            crop,
            by: SelectionGeometry.CropEdgeDeltas(left: 50),
            limitedTo: frameSize
        )

        XCTAssertEqual(grown.minX, 250)
        XCTAssertEqual(grown.maxX, crop.maxX)
        XCTAssertEqual(grown.minY, crop.minY)
        XCTAssertEqual(grown.height, crop.height)
    }

    /// Nothing exists outside the captured display, so an edge that reaches it simply stops.
    func testGrowingStopsAtTheFrameBounds() {
        let grown = SelectionGeometry.resizedCrop(
            crop,
            by: SelectionGeometry.CropEdgeDeltas(left: 9999, top: 9999, right: 9999, bottom: 9999),
            limitedTo: frameSize
        )

        XCTAssertEqual(grown, CGRect(origin: .zero, size: frameSize))
    }

    func testShrinkingStopsAtTheMinimumSide() {
        let shrunk = SelectionGeometry.resizedCrop(
            crop,
            by: SelectionGeometry.CropEdgeDeltas(left: -500),
            limitedTo: frameSize,
            minimumSide: 32
        )

        XCTAssertEqual(shrunk.width, 32)
        XCTAssertEqual(shrunk.maxX, crop.maxX, "the edge that wasn't dragged stayed put")
    }

    /// Dragging a corner moves two edges at once — both have to be applied in one go.
    func testCornerDragMovesBothAxes() {
        let grown = SelectionGeometry.resizedCrop(
            crop,
            by: SelectionGeometry.CropEdgeDeltas(left: 100, top: 50),
            limitedTo: frameSize
        )

        XCTAssertEqual(grown, CGRect(x: 200, y: 150, width: 300, height: 250))
    }

    func testPixelRectScalesAndClampsToTheFrame() {
        let pixels = SelectionGeometry.pixelRect(
            of: CGRect(x: 10, y: 20, width: 100, height: 50),
            scale: 2,
            imagePixelSize: CGSize(width: 2000, height: 1600)
        )

        XCTAssertEqual(pixels, CGRect(x: 20, y: 40, width: 200, height: 100))
    }

    func testLoupeSitsAboveLeftOfTheCursor() {
        let origin = SelectionGeometry.loupeOrigin(
            cursor: CGPoint(x: 500, y: 400),
            loupeSize: CGSize(width: 112, height: 130),
            bounds: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )

        XCTAssertEqual(origin, CGPoint(x: 500 - 20 - 112, y: 400 - 20 - 130))
    }

    func testLoupeFlipsAwayFromTheTopLeftCorner() {
        let origin = SelectionGeometry.loupeOrigin(
            cursor: CGPoint(x: 30, y: 40),
            loupeSize: CGSize(width: 112, height: 130),
            bounds: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )

        XCTAssertEqual(origin, CGPoint(x: 50, y: 60), "below and to the right instead")
    }

    func testPixelUnderThePointUsesTheScaleAndStaysInTheFrame() {
        let size = CGSize(width: 200, height: 100)

        XCTAssertEqual(
            SelectionGeometry.pixel(under: CGPoint(x: 10.6, y: 20.2), scale: 2, imagePixelSize: size),
            CGPoint(x: 21, y: 40)
        )
        XCTAssertEqual(
            SelectionGeometry.pixel(under: CGPoint(x: 500, y: -3), scale: 2, imagePixelSize: size),
            CGPoint(x: 199, y: 0)
        )
    }

    /// The loupe keeps its size at the edge of the frame: the square slides inwards.
    func testLoupeSampleIsCentredAndSlidesInwardsAtTheEdge() {
        let size = CGSize(width: 200, height: 100)

        XCTAssertEqual(
            SelectionGeometry.loupeSampleRect(around: CGPoint(x: 50, y: 50), radius: 7, imagePixelSize: size),
            CGRect(x: 43, y: 43, width: 15, height: 15)
        )
        XCTAssertEqual(
            SelectionGeometry.loupeSampleRect(around: CGPoint(x: 2, y: 99), radius: 7, imagePixelSize: size),
            CGRect(x: 0, y: 85, width: 15, height: 15)
        )
    }

    func testCornerBracketsSitOnTheFourCorners() {
        let rect = CGRect(x: 10, y: 20, width: 100, height: 60)
        let brackets = SelectionGeometry.cornerBrackets(for: rect, armLength: 12)

        XCTAssertEqual(brackets.count, 4)
        XCTAssertEqual(brackets.map { $0[1] }, [
            CGPoint(x: 10, y: 20), CGPoint(x: 110, y: 20),
            CGPoint(x: 10, y: 80), CGPoint(x: 110, y: 80),
        ])
        XCTAssertEqual(brackets[0][0], CGPoint(x: 22, y: 20), "horizontal arm runs inward")
        XCTAssertEqual(brackets[3][2], CGPoint(x: 110, y: 68), "vertical arm runs inward")
    }

    /// On a thin selection the arms of one side meet in the middle instead of crossing over.
    func testCornerBracketArmsNeverPassTheMiddle() {
        let thin = CGRect(x: 0, y: 0, width: 10, height: 200)
        let brackets = SelectionGeometry.cornerBrackets(for: thin, armLength: 14)

        XCTAssertEqual(brackets[0][0].x, 5)
        XCTAssertEqual(brackets[1][0].x, 5)
        XCTAssertEqual(brackets[0][2].y, 14, "the long side keeps the full arm")
    }

    // MARK: - Recording

    /// 4:2:0 video is coded in 2×2 blocks: an odd side is rejected or gets a green line.
    func testRecordingSizeIsEvenAndInPixels() {
        let size = SelectionGeometry.recordingPixelSize(of: CGRect(x: 0, y: 0, width: 401.5, height: 300), scale: 2)
        XCTAssertEqual(size.width, 802)
        XCTAssertEqual(size.height, 600)

        let odd = SelectionGeometry.recordingPixelSize(of: CGRect(x: 0, y: 0, width: 101, height: 51), scale: 1)
        XCTAssertEqual(odd.width, 100)
        XCTAssertEqual(odd.height, 50)

        let tiny = SelectionGeometry.recordingPixelSize(of: CGRect(x: 0, y: 0, width: 0.4, height: 1), scale: 1)
        XCTAssertEqual(tiny.width, 2, "never below 2×2")
        XCTAssertEqual(tiny.height, 2)
    }

    /// AppKit coordinates: the visible frame is 0…1000 tall, Y grows upwards.
    private let visible = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let pill = CGSize(width: 232, height: 44)

    func testPillSitsCentredUnderTheArea() {
        let area = CGRect(x: 400, y: 500, width: 600, height: 300)

        let origin = SelectionGeometry.pillOrigin(below: area, pillSize: pill, visibleFrame: visible)

        XCTAssertEqual(origin.x, 700 - 116)
        XCTAssertEqual(origin.y, 500 - 12 - 44)
    }

    func testPillGoesAboveWhenThereIsNoRoomBelow() {
        let area = CGRect(x: 400, y: 20, width: 600, height: 300)

        let origin = SelectionGeometry.pillOrigin(below: area, pillSize: pill, visibleFrame: visible)

        XCTAssertEqual(origin.y, 320 + 12)
    }

    /// A full-screen recording leaves no room outside: the pill goes inside, at the bottom, and
    /// stays on the screen horizontally.
    func testPillInsideTheBottomForAFullScreenArea() {
        let origin = SelectionGeometry.pillOrigin(below: visible, pillSize: pill, visibleFrame: visible)

        XCTAssertEqual(origin.y, 24)
        XCTAssertEqual(origin.x, 800 - 116)

        let atTheEdge = CGRect(x: 1550, y: 500, width: 40, height: 40)
        let clamped = SelectionGeometry.pillOrigin(below: atTheEdge, pillSize: pill, visibleFrame: visible)
        XCTAssertEqual(clamped.x, 1600 - 12 - 232)
    }

    /// The flip is its own inverse: going there and back lands where it started.
    func testAppKitConversionUndoesTheCoreGraphicsOne() {
        let appKit = CGRect(x: 100, y: 200, width: 300, height: 400)
        let coreGraphics = SelectionGeometry.convertToCoreGraphics(rect: appKit, primaryScreenMaxY: 1440)

        XCTAssertEqual(coreGraphics.minY, 1440 - 600)
        XCTAssertEqual(SelectionGeometry.convertToAppKit(rect: coreGraphics, primaryScreenMaxY: 1440), appKit)
    }

    // MARK: - Handles on drawn objects

    private func assertPoint(_ a: CGPoint, _ b: CGPoint, _ message: String = "", line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: 0.001, message, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 0.001, message, line: line)
    }

    /// The trap for a turned box: its "right" side is wherever the turn put it, and the opposite
    /// side must not move on the shot while the dragged one follows the mouse.
    func testDraggingASideOfATurnedBoxKeepsTheOppositeSidePut() {
        let box = SelectionGeometry.RotatedBox(center: CGPoint(x: 100, y: 100), size: CGSize(width: 100, height: 50), angle: .pi / 2)
        let rightSide = box.toWorld(CGPoint(x: 50, y: 0))
        assertPoint(rightSide, CGPoint(x: 100, y: 150), "turned clockwise, its right side faces down")
        let leftSide = box.toWorld(CGPoint(x: -50, y: 0))

        let resized = SelectionGeometry.resized(
            box,
            dragging: .right,
            grabbedAt: rightSide,
            mouse: CGPoint(x: 103, y: 170),
            keepsAspect: false,
            fromCentre: false,
            minimumSide: 4
        )

        XCTAssertEqual(resized.size.width, 120, accuracy: 0.001)
        XCTAssertEqual(resized.size.height, 50, accuracy: 0.001)
        assertPoint(resized.toWorld(CGPoint(x: -60, y: 0)), leftSide)
    }

    func testCornerWithShiftKeepsTheProportionsAndOptionTheCentre() {
        let box = SelectionGeometry.RotatedBox(center: .zero, size: CGSize(width: 100, height: 50))
        let corner = CGPoint(x: 50, y: 25)

        let proportional = SelectionGeometry.resized(
            box, dragging: .bottomRight, grabbedAt: corner, mouse: CGPoint(x: 150, y: 30),
            keepsAspect: true, fromCentre: false, minimumSide: 4
        )
        XCTAssertEqual(proportional.size.width / proportional.size.height, 2, accuracy: 0.001)
        assertPoint(proportional.corner(.topLeft), CGPoint(x: -50, y: -25), "the opposite corner stays")

        let centred = SelectionGeometry.resized(
            box, dragging: .bottomRight, grabbedAt: corner, mouse: CGPoint(x: 60, y: 35),
            keepsAspect: false, fromCentre: true, minimumSide: 4
        )
        assertPoint(centred.center, .zero)
        XCTAssertEqual(centred.size.width, 120, accuracy: 0.001)
        XCTAssertEqual(centred.size.height, 70, accuracy: 0.001)
    }

    /// A side dragged over the opposite one stops at the minimum instead of flipping the box.
    func testASideNeverCrossesTheOppositeOne() {
        let box = SelectionGeometry.RotatedBox(center: .zero, size: CGSize(width: 100, height: 50))
        let resized = SelectionGeometry.resized(
            box, dragging: .right, grabbedAt: CGPoint(x: 50, y: 0), mouse: CGPoint(x: -200, y: 0),
            keepsAspect: false, fromCentre: false, minimumSide: 4
        )
        XCTAssertEqual(resized.size.width, 4, accuracy: 0.001)
        XCTAssertEqual(resized.corner(.topLeft).x, -50, accuracy: 0.001)
    }

    func testTurningSnapsToFifteenDegreesWithShift() {
        let angle = SelectionGeometry.turnedAngle(
            from: 0, centre: .zero, grab: CGPoint(x: 10, y: 0), mouse: CGPoint(x: 10, y: 3.4), snaps: true
        )
        XCTAssertEqual(angle, .pi / 12, accuracy: 0.0001)
        XCTAssertEqual(SelectionGeometry.displayDegrees(angle), -15, "clockwise on screen reads as negative")

        let free = SelectionGeometry.turnedAngle(
            from: 0, centre: .zero, grab: CGPoint(x: 10, y: 0), mouse: CGPoint(x: 10, y: 3.4), snaps: false
        )
        XCTAssertEqual(free, atan2(3.4, 10), accuracy: 0.0001)
    }

    func testShiftKeepsTheLengthAndRoundsTheDirection() {
        let end = SelectionGeometry.snappedEnd(fixed: .zero, moving: CGPoint(x: 100, y: 5))
        assertPoint(end, CGPoint(x: CGFloat(100 * 100 + 5 * 5).squareRoot(), y: 0))
    }

    func testTheBendPassesThroughTheDraggedMiddle() throws {
        let start = CGPoint(x: 0, y: 0)
        let end = CGPoint(x: 100, y: 0)
        let control = try XCTUnwrap(SelectionGeometry.control(through: CGPoint(x: 50, y: -30), start: start, end: end))
        assertPoint(SelectionGeometry.curvePoint(start: start, control: control, end: end, at: 0.5), CGPoint(x: 50, y: -30))
        XCTAssertNil(
            SelectionGeometry.control(through: CGPoint(x: 51, y: 2), start: start, end: end),
            "dropped on the straight line, it is straight again"
        )
    }

    /// Moving an end turns and stretches the bend with the line: the same bend on a line twice
    /// as long, turned a quarter, is twice as deep and turned too.
    func testTheBendFollowsTheLine() {
        let carried = SelectionGeometry.carriedControl(
            CGPoint(x: 50, y: -20),
            from: (CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)),
            to: (CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 200))
        )
        assertPoint(carried, CGPoint(x: 40, y: 100))
    }

    func testTheHeadsButtonSitsAboveALineAndAwayFromItsBend() {
        let above = SelectionGeometry.headsButtonCentre(start: .zero, end: CGPoint(x: 100, y: 0), bentMiddle: nil, offset: 20)
        assertPoint(above, CGPoint(x: 50, y: -20))

        let awayFromBend = SelectionGeometry.headsButtonCentre(
            start: .zero, end: CGPoint(x: 100, y: 0), bentMiddle: CGPoint(x: 50, y: -30), offset: 20
        )
        assertPoint(awayFromBend, CGPoint(x: 50, y: 20))
    }

    func testAResizeCursorTurnsWithTheBox() {
        XCTAssertEqual(SelectionGeometry.screenHandle(.right, turnedBy: .pi / 2), .bottom)
        XCTAssertEqual(SelectionGeometry.screenHandle(.topLeft, turnedBy: .pi / 4), .top)
        XCTAssertEqual(SelectionGeometry.screenHandle(.left, turnedBy: 0), .left)
    }

    func testTheTurningZoneIsJustOutsideACorner() {
        let box = SelectionGeometry.RotatedBox(center: .zero, size: CGSize(width: 100, height: 50))
        XCTAssertTrue(SelectionGeometry.isRotationZone(CGPoint(x: 58, y: -33), of: box))
        XCTAssertFalse(SelectionGeometry.isRotationZone(CGPoint(x: 40, y: -20), of: box), "inside is moving")
        XCTAssertFalse(SelectionGeometry.isRotationZone(CGPoint(x: 0, y: -40), of: box), "beside a side is nothing")
    }

    /// Where R's shapes lie in their box: a circle in the middle square, a triangle's apex at the
    /// top middle (Y goes down), a diamond on the middles of the sides.
    func testTheShapesPointsInTheirBox() {
        let box = CGRect(x: 10, y: 20, width: 200, height: 100)
        XCTAssertEqual(SelectionGeometry.centredSquare(in: box), CGRect(x: 60, y: 20, width: 100, height: 100))
        XCTAssertEqual(SelectionGeometry.trianglePoints(in: box), [CGPoint(x: 110, y: 20), CGPoint(x: 210, y: 120), CGPoint(x: 10, y: 120)])
        XCTAssertEqual(
            SelectionGeometry.diamondPoints(in: box),
            [CGPoint(x: 110, y: 20), CGPoint(x: 210, y: 70), CGPoint(x: 110, y: 120), CGPoint(x: 10, y: 70)]
        )
    }

    /// A square drawn with ⇧ grows from where the drag began, in whichever direction it went,
    /// and takes the shorter side of the drag.
    func testAnEvenShapeGrowsFromTheCornerTheDragBeganAt() {
        let start = CGPoint(x: 100, y: 100)
        XCTAssertEqual(SelectionGeometry.evenEnd(from: start, to: CGPoint(x: 160, y: 140), aspect: 1), CGPoint(x: 140, y: 140))
        XCTAssertEqual(SelectionGeometry.evenEnd(from: start, to: CGPoint(x: 40, y: 70), aspect: 1), CGPoint(x: 70, y: 70))
        XCTAssertEqual(SelectionGeometry.evenEnd(from: start, to: CGPoint(x: 150, y: 20), aspect: 1), CGPoint(x: 150, y: 50))
    }
}
