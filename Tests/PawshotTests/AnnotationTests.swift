import AppKit
@testable import Pawshot
import XCTest

@MainActor
final class AnnotationTests: XCTestCase {
    // MARK: - Mouse hits

    func testUnfilledRectangleIsHitOnBorderOnly() {
        let rectangle = RectangleAnnotation(start: CGPoint(x: 0, y: 0), style: .default)
        rectangle.update(to: CGPoint(x: 100, y: 100))

        XCTAssertTrue(rectangle.hitTest(CGPoint(x: 0, y: 50), tolerance: 4), "the border")
        XCTAssertFalse(rectangle.hitTest(CGPoint(x: 50, y: 50), tolerance: 4), "the empty middle")
    }

    func testFilledRectangleIsHitInside() {
        let rectangle = RectangleAnnotation(
            start: CGPoint(x: 0, y: 0),
            style: AnnotationStyle(color: .red, lineWidth: 3, fillOpacity: 0.25)
        )
        rectangle.update(to: CGPoint(x: 100, y: 100))

        XCTAssertTrue(rectangle.hitTest(CGPoint(x: 50, y: 50), tolerance: 4))
    }

    func testArrowIsHitAlongItsLine() {
        let arrow = ArrowAnnotation(start: CGPoint(x: 0, y: 0), style: .default)
        arrow.update(to: CGPoint(x: 100, y: 100))

        XCTAssertTrue(arrow.hitTest(CGPoint(x: 50, y: 52), tolerance: 4), "next to the line")
        XCTAssertFalse(arrow.hitTest(CGPoint(x: 10, y: 90), tolerance: 4), "off to the side")
    }

    func testDistanceToSegmentClampsToEnds() {
        let start = CGPoint(x: 0, y: 0)
        let end = CGPoint(x: 10, y: 0)

        // A point past the end of the segment is measured to that end, not to an infinite line.
        XCTAssertEqual(GeometryMath.distance(from: CGPoint(x: 20, y: 0), toSegment: start, end), 10)
        XCTAssertEqual(GeometryMath.distance(from: CGPoint(x: 5, y: 3), toSegment: start, end), 3)
    }

    // MARK: - Object viability

    func testTinyShapesAreDiscarded() {
        let rectangle = RectangleAnnotation(start: .zero, style: .default)
        rectangle.update(to: CGPoint(x: 2, y: 2))
        XCTAssertFalse(rectangle.isMeaningful)

        let arrow = ArrowAnnotation(start: .zero, style: .default)
        arrow.update(to: CGPoint(x: 3, y: 0))
        XCTAssertFalse(arrow.isMeaningful)

        let text = TextAnnotation(origin: .zero, style: .default, text: "   ")
        XCTAssertFalse(text.isMeaningful, "whitespace is not text")
    }

    func testCounterIsAlwaysMeaningful() {
        let counter = CounterAnnotation(center: .zero, number: 1, style: .default)
        XCTAssertTrue(counter.isMeaningful, "a circle is placed with a single click")
    }

    // MARK: - Moving

    func testMoveShiftsBothEndsOfArrow() {
        let arrow = ArrowAnnotation(start: CGPoint(x: 10, y: 10), style: .default)
        arrow.update(to: CGPoint(x: 50, y: 30))
        let before = arrow.boundingBox

        arrow.move(by: CGVector(dx: 15, dy: -5))

        XCTAssertEqual(arrow.boundingBox.minX, before.minX + 15, accuracy: 0.001)
        XCTAssertEqual(arrow.boundingBox.minY, before.minY - 5, accuracy: 0.001)
        XCTAssertEqual(arrow.boundingBox.width, before.width, accuracy: 0.001)
    }

    func testPencilPathSkipsDuplicatePoints() {
        let path = PathAnnotation(start: .zero, style: .default)
        path.update(to: CGPoint(x: 0.2, y: 0.2))
        XCTAssertFalse(path.isMeaningful, "points right next to each other are not a stroke")

        path.update(to: CGPoint(x: 20, y: 20))
        XCTAssertTrue(path.isMeaningful)
    }

    // MARK: - Style

    func testPaletteIsRedGreenWhiteBlackThenYourOwn() {
        XCTAssertEqual(AnnotationStyle.Palette.colors, [.systemRed, .systemGreen, .white, .black])
        XCTAssertEqual(AnnotationStyle.Palette.customIndex, 4)
    }

    func testFillStepsWalkUpAndBackToNone() {
        let next = AnnotationStyle.FillOpacity.next(after:)
        XCTAssertEqual(next(0), 0.3)
        XCTAssertEqual(next(0.3), 0.6)
        XCTAssertEqual(next(0.6), 1)
        XCTAssertEqual(next(1), 0)
        XCTAssertEqual(next(0.45), 0.6, "from wherever the slider left it, the next step up")
    }

    func testLineEndsWalkArrowDoublePlain() {
        XCTAssertEqual(AnnotationStyle.LineEnds.end.next, .both)
        XCTAssertEqual(AnnotationStyle.LineEnds.both.next, .none)
        XCTAssertEqual(AnnotationStyle.LineEnds.none.next, .end)
    }

    func testTheSystemFontHasNineWeights() {
        XCTAssertEqual(LabelFont.weights(of: nil).count, 9)
    }

    /// Any installed family lists its upright weights once each, lightest first.
    func testAFamilyListsItsUprightWeightsLightestFirst() {
        let weights = LabelFont.weights(of: "Helvetica Neue")
        XCTAssertGreaterThan(weights.count, 2)
        XCTAssertEqual(weights.map(\.rawValue), weights.map(\.rawValue).sorted())
        XCTAssertEqual(Set(weights.map(\.rawValue)).count, weights.count, "no two faces of one weight")
        for weight in weights {
            let font = LabelFont.font(size: 12, weight: weight, family: "Helvetica Neue")
            XCTAssertFalse(font.fontDescriptor.symbolicTraits.contains(.italic), font.fontName)
        }
    }

    func testAnUnknownFamilyFallsBackToTheSystemFont() {
        XCTAssertEqual(
            LabelFont.font(size: 18, weight: .bold, family: "No Such Family Anywhere"),
            NSFont.systemFont(ofSize: 18, weight: .bold)
        )
    }

    /// A label's size is its own now: the width steps belong to shapes.
    func testALabelsSizeNoLongerFollowsTheLineWidth() {
        var style = AnnotationStyle.default
        style.lineWidth = 12
        let label = TextAnnotation(origin: .zero, style: style, text: "Hi")
        XCTAssertEqual(label.fontSize, 18)
    }

    /// Dragging a corner resizes the text about the opposite corner, which stays put.
    func testResizingALabelKeepsThePinnedCorner() {
        let label = TextAnnotation(origin: CGPoint(x: 40, y: 40), style: .default, text: "Hello")
        let pinned = SelectionGeometry.Corner.topLeft.point(of: label.boundingBox)

        label.resize(from: label.geometry, to: 36, pinning: .topLeft)

        XCTAssertEqual(label.style.textSize, 36)
        XCTAssertEqual(SelectionGeometry.Corner.topLeft.point(of: label.boundingBox).x, pinned.x, accuracy: 0.5)
        XCTAssertEqual(SelectionGeometry.Corner.topLeft.point(of: label.boundingBox).y, pinned.y, accuracy: 0.5)
    }

    func testTextControlsShowForASelectedLabelUnderV() {
        let chrome = EditorChromeModel()
        chrome.tool = .select
        XCTAssertFalse(chrome.showsTextControls)
        chrome.selectedKind = .text
        XCTAssertTrue(chrome.showsTextControls, "a label selected under V gets its own controls, not the shapes' fill")
    }

    func testHexGoesThereAndBack() throws {
        let color = try XCTUnwrap(ColorHex.color("#AF52DE"))
        XCTAssertEqual(ColorHex.string(color), "#AF52DE")
        XCTAssertEqual(try ColorHex.string(XCTUnwrap(ColorHex.color(" af52de "))), "#AF52DE")
        XCTAssertNil(ColorHex.color("#AF52D"))
        XCTAssertNil(ColorHex.color("+AF52D"))
        XCTAssertNil(ColorHex.color("#GG52DE"))
    }

    /// A label turned with the shot turns about its own corner: the line of text runs down from
    /// it, and its height goes to the left.
    func testATurnedLabelKeepsItsCornerAndLiesDown() {
        let label = TextAnnotation(origin: CGPoint(x: 50, y: 20), style: .default, text: "A long label")
        let level = label.boundingBox
        label.rotate(clockwise: true, in: CGSize(width: 400, height: 300))

        XCTAssertEqual(label.origin, CGPoint(x: 280, y: 50), "the corner moved with the shot")
        let turned = label.boundingBox
        XCTAssertEqual(turned.width, level.height, accuracy: 0.5)
        XCTAssertEqual(turned.height, level.width, accuracy: 0.5)
        XCTAssertLessThan(turned.minX, label.origin.x, "its height lies to the left of the corner")
    }

    func testLineWidthStepsClampAtEdges() {
        let steps = AnnotationStyle.LineWidth.steps

        XCTAssertEqual(AnnotationStyle.LineWidth.next(after: steps[0]), steps[1])
        XCTAssertEqual(AnnotationStyle.LineWidth.next(after: steps[steps.count - 1]), steps[steps.count - 1])
        XCTAssertEqual(AnnotationStyle.LineWidth.previous(before: steps[0]), steps[0])
    }

    /// The selection frame and the grab area are the same rectangle; if they drift apart, the
    /// object starts being dragged where no frame is visible (or the other way round).
    func testSelectionFrameIsBoundingBoxWithInset() {
        let rectangle = RectangleAnnotation(start: CGPoint(x: 10, y: 10), style: .default)
        rectangle.update(to: CGPoint(x: 60, y: 40))

        let inset = RectangleAnnotation.selectionInset
        let frame = rectangle.selectionFrame

        XCTAssertEqual(frame.minX, rectangle.boundingBox.minX - inset, accuracy: 0.001)
        XCTAssertEqual(frame.width, rectangle.boundingBox.width + inset * 2, accuracy: 0.001)
    }

    /// An arrow and a pencil stroke have no area at all — their frame has to catch the mouse
    /// too.
    func testSelectionFrameCatchesInsideThinShapes() {
        let arrow = ArrowAnnotation(start: CGPoint(x: 0, y: 0), style: .default)
        arrow.update(to: CGPoint(x: 100, y: 100))

        XCTAssertTrue(arrow.selectionFrame.contains(CGPoint(x: 10, y: 90)), "far from the line")
        XCTAssertFalse(arrow.hitTest(CGPoint(x: 10, y: 90), tolerance: 4))
    }

    func testToolHotKeysAreUniqueAndResolvable() {
        let hotKeys = AnnotationTool.allCases.map(\.hotKey)

        XCTAssertEqual(Set(hotKeys).count, hotKeys.count, "two letters for one tool is a bug")
        XCTAssertEqual(AnnotationTool.tool(forHotKey: "D"), .pencil, "case doesn't matter")
        XCTAssertNil(AnnotationTool.tool(forHotKey: "z"))
    }

    func testTextStylesCycleInOrder() {
        XCTAssertEqual(AnnotationStyle.TextStyle.plain.next, .outline)
        XCTAssertEqual(AnnotationStyle.TextStyle.outline.next, .plate)
        XCTAssertEqual(AnnotationStyle.TextStyle.plate.next, .plain)
    }

    /// White letters on a dark plate, black on a light one — decided by luminance.
    func testPlateLettersContrastWithThePlate() {
        XCTAssertEqual(AnnotationStyle.contrastingTextColor(on: .systemRed), .white)
        XCTAssertEqual(AnnotationStyle.contrastingTextColor(on: .systemBlue), .white)
        XCTAssertEqual(AnnotationStyle.contrastingTextColor(on: .black), .white)
        XCTAssertEqual(AnnotationStyle.contrastingTextColor(on: .systemYellow), .black)
        XCTAssertEqual(AnnotationStyle.contrastingTextColor(on: .white), .black)
    }

    /// A plate reaches past the letters, so the selection frame and the hit area grow with it.
    @MainActor
    func testPlateWidensTheLabelsBox() {
        var style = AnnotationStyle.default
        let plain = TextAnnotation(origin: .zero, style: style, text: "Label")
        style.textStyle = .plate
        let plated = TextAnnotation(origin: .zero, style: style, text: "Label")

        XCTAssertGreaterThan(plated.boundingBox.width, plain.boundingBox.width)
        XCTAssertEqual(plated.textFrame, plain.textFrame, "the letters stay where they were")
    }

    // MARK: - R's shapes

    private func shape(_ kind: AnnotationStyle.ShapeKind, _ rect: CGRect, fill: CGFloat = 0) -> RectangleAnnotation {
        var style = AnnotationStyle(color: .red, lineWidth: 3, fillOpacity: fill)
        style.shapeKind = kind
        let shape = RectangleAnnotation(start: rect.origin, style: style)
        shape.update(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return shape
    }

    /// A rectangle made a circle is the circle in its middle, and back it is the same rectangle:
    /// the drawn corners are kept, only what is drawn in them changes.
    func testARectangleMadeACircleAndBackIsTheSameRectangle() {
        let drawn = shape(.rectangle, CGRect(x: 0, y: 0, width: 200, height: 100))

        drawn.style.shapeKind = .circle
        XCTAssertEqual(drawn.rect, CGRect(x: 50, y: 0, width: 100, height: 100))

        drawn.style.shapeKind = .rectangle
        XCTAssertEqual(drawn.rect, CGRect(x: 0, y: 0, width: 200, height: 100))
    }

    /// A circle is drawn round whatever the drag, from the corner where it began.
    func testACircleIsDrawnRound() {
        let circle = shape(.circle, CGRect(x: 100, y: 100, width: 0, height: 0))
        circle.update(to: CGPoint(x: 40, y: 70))

        XCTAssertEqual(circle.rect, CGRect(x: 70, y: 70, width: 30, height: 30))
    }

    /// ⇧ while drawing: a square, and a triangle with equal sides.
    func testShiftDrawsAnEvenShape() {
        let square = shape(.rectangle, CGRect(x: 0, y: 0, width: 0, height: 0))
        square.drawsEven = true
        square.update(to: CGPoint(x: 80, y: 50))
        XCTAssertEqual(square.rect.size, CGSize(width: 50, height: 50))

        let triangle = shape(.triangle, CGRect(x: 0, y: 0, width: 0, height: 0))
        triangle.drawsEven = true
        triangle.update(to: CGPoint(x: 100, y: 200))
        XCTAssertEqual(triangle.rect.width, 100, accuracy: 0.001)
        XCTAssertEqual(triangle.rect.height, 100 * sqrt(3) / 2, accuracy: 0.001)
    }

    /// A shape is hit by its own outline, not by the box around it.
    func testCirclesTrianglesAndDiamondsAreHitByTheirOutline() {
        let box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let circle = shape(.circle, box)
        XCTAssertTrue(circle.hitTest(CGPoint(x: 0, y: 50), tolerance: 4), "on the ring")
        XCTAssertFalse(circle.hitTest(CGPoint(x: 50, y: 50), tolerance: 4), "the empty middle")
        XCTAssertFalse(circle.hitTest(CGPoint(x: 2, y: 2), tolerance: 4), "the box's corner is not the circle")

        let diamond = shape(.diamond, box, fill: 0.6)
        XCTAssertTrue(diamond.hitTest(CGPoint(x: 50, y: 50), tolerance: 4), "filled, hit inside")
        XCTAssertFalse(diamond.hitTest(CGPoint(x: 8, y: 8), tolerance: 4), "the empty corner of its box")

        let triangle = shape(.triangle, box)
        XCTAssertTrue(triangle.hitTest(CGPoint(x: 50, y: 1), tolerance: 4), "the apex")
        XCTAssertFalse(triangle.hitTest(CGPoint(x: 5, y: 5), tolerance: 4), "beside the apex")
    }

    /// A circle keeps round: only its corners resize it, and it has nothing to turn.
    func testACircleHasOnlyCornersAndNoTurning() {
        let circle = shape(.circle, CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertFalse(CanvasHandles.hasHandle(.right, on: circle))
        XCTAssertTrue(CanvasHandles.hasHandle(.topLeft, on: circle))
        XCTAssertFalse(CanvasHandles.canTurn(circle))

        let triangle = shape(.triangle, CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertTrue(CanvasHandles.hasHandle(.right, on: triangle))
        XCTAssertTrue(CanvasHandles.canTurn(triangle))
    }
}
