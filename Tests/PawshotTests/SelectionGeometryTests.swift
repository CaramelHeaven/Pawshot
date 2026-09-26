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
}
