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
            style: AnnotationStyle(color: .red, lineWidth: 3, isFilled: true)
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

    func testPaletteLastKeyTogglesBlackAndWhite() {
        let lastIndex = AnnotationStyle.Palette.colors.count - 1

        let toWhite = AnnotationStyle.Palette.color(forKeyIndex: lastIndex, current: .black)
        XCTAssertEqual(toWhite, .white)

        let backToBlack = AnnotationStyle.Palette.color(forKeyIndex: lastIndex, current: toWhite)
        XCTAssertEqual(backToBlack, .black)
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
}
