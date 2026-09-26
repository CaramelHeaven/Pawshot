import AppKit
@testable import Pawshot
import XCTest

@MainActor
final class EditorDocumentTests: XCTestCase {
    private func makeDocument(
        crop: CGRect = CGRect(x: 0, y: 0, width: 400, height: 300),
        frameSize: CGSize = CGSize(width: 400, height: 300)
    ) -> EditorDocument {
        let context = CGContext(
            data: nil,
            width: Int(frameSize.width),
            height: Int(frameSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let frame = CapturedFrame(
            image: context.makeImage()!,
            displayFrame: CGRect(origin: .zero, size: frameSize),
            scale: 1
        )
        return EditorDocument(frame: frame, cropRect: crop)!
    }

    /// In the app the runloop closes undo groups. There is no runloop in a test, so every action
    /// is wrapped by hand — otherwise a single `undo()` would roll back everything at once.
    private func makeUndoManager(for document: EditorDocument) -> UndoManager {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        document.undoManager = undoManager
        return undoManager
    }

    private func step(_ undoManager: UndoManager, _ body: () -> Void) {
        undoManager.beginUndoGrouping()
        body()
        undoManager.endUndoGrouping()
    }

    func testAddAndRemoveAnnotation() {
        let document = makeDocument()
        let rectangle = RectangleAnnotation(start: CGPoint(x: 10, y: 10), style: .default)
        rectangle.update(to: CGPoint(x: 60, y: 40))

        document.add(rectangle)
        XCTAssertEqual(document.annotations.count, 1)

        document.remove(rectangle)
        XCTAssertTrue(document.annotations.isEmpty)
    }

    func testUndoRestoresRemovedAnnotationInPlace() {
        let document = makeDocument()
        let undoManager = makeUndoManager(for: document)

        let first = RectangleAnnotation(start: .zero, style: .default)
        let second = ArrowAnnotation(start: .zero, style: .default)
        step(undoManager) { document.add(first) }
        step(undoManager) { document.add(second) }
        step(undoManager) { document.remove(first) }

        XCTAssertEqual(document.annotations.count, 1)

        undoManager.undo()

        XCTAssertEqual(document.annotations.count, 2)
        // Order matters: it is also the drawing order, and a restored object must not float to
        // the top.
        XCTAssertTrue(document.annotations.first === first)
    }

    func testUndoRevertsMove() {
        let document = makeDocument()
        let undoManager = makeUndoManager(for: document)

        let rectangle = RectangleAnnotation(start: CGPoint(x: 10, y: 10), style: .default)
        rectangle.update(to: CGPoint(x: 50, y: 50))
        step(undoManager) { document.add(rectangle) }

        step(undoManager) { document.move(rectangle, by: CGVector(dx: 20, dy: -5)) }
        XCTAssertEqual(rectangle.rect.minX, 30)

        undoManager.undo()

        XCTAssertEqual(rectangle.rect.minX, 10)
        XCTAssertEqual(rectangle.rect.minY, 10)
    }

    func testRedoRepeatsUndoneMove() {
        let document = makeDocument()
        let undoManager = makeUndoManager(for: document)

        let rectangle = RectangleAnnotation(start: CGPoint(x: 0, y: 0), style: .default)
        rectangle.update(to: CGPoint(x: 40, y: 40))
        step(undoManager) { document.add(rectangle) }
        step(undoManager) { document.move(rectangle, by: CGVector(dx: 10, dy: 10)) }

        undoManager.undo()
        undoManager.redo()

        XCTAssertEqual(rectangle.rect.minX, 10)
    }

    /// The last object drawn sits on top — and it has to be hit first.
    func testHitTestPrefersTopmostAnnotation() {
        let document = makeDocument()

        let filled = AnnotationStyle(color: .red, lineWidth: 3, isFilled: true)
        let bottom = RectangleAnnotation(start: CGPoint(x: 0, y: 0), style: filled)
        bottom.update(to: CGPoint(x: 100, y: 100))
        let top = RectangleAnnotation(start: CGPoint(x: 20, y: 20), style: filled)
        top.update(to: CGPoint(x: 80, y: 80))

        document.add(bottom)
        document.add(top)

        XCTAssertTrue(document.annotation(at: CGPoint(x: 50, y: 50), tolerance: 4) === top)
    }

    func testCounterNumbersDoNotReuseAfterDeletion() {
        let document = makeDocument()

        XCTAssertEqual(document.nextCounterNumber(), 1)
        XCTAssertEqual(document.nextCounterNumber(), 2)

        let third = CounterAnnotation(center: .zero, number: document.nextCounterNumber(), style: .default)
        document.add(third)
        document.remove(third)

        // Numbers are not recomputed — CleanShot X and Shottr behave the same way.
        XCTAssertEqual(document.nextCounterNumber(), 4)
    }

    func testStyleChangeAppliesToSelectionAndIsUndoable() {
        let document = makeDocument()
        let undoManager = makeUndoManager(for: document)

        let arrow = ArrowAnnotation(start: .zero, style: .default)
        step(undoManager) { document.add(arrow) }
        document.selection = arrow

        step(undoManager) { document.updateStyle { $0.color = .systemBlue } }
        XCTAssertEqual(arrow.style.color, .systemBlue)

        undoManager.undo()
        XCTAssertEqual(arrow.style.color, AnnotationStyle.default.color)
    }

    func testRemoveAllClearsCanvasAndSelection() {
        let document = makeDocument()
        document.add(RectangleAnnotation(start: .zero, style: .default))
        let arrow = ArrowAnnotation(start: .zero, style: .default)
        document.add(arrow)
        document.selection = arrow

        document.removeAll()

        XCTAssertTrue(document.annotations.isEmpty)
        XCTAssertNil(document.selection)
    }

    func testUndoAfterRemoveAllRestoresEverythingInOrder() {
        let document = makeDocument()
        let undoManager = makeUndoManager(for: document)

        let first = RectangleAnnotation(start: .zero, style: .default)
        let second = ArrowAnnotation(start: .zero, style: .default)
        let third = CounterAnnotation(center: .zero, number: 1, style: .default)
        step(undoManager) { document.add(first) }
        step(undoManager) { document.add(second) }
        step(undoManager) { document.add(third) }

        step(undoManager) { document.removeAll() }
        XCTAssertTrue(document.annotations.isEmpty)

        undoManager.undo()

        // The order is the drawing order, and after an undo it has to be the same as before.
        XCTAssertEqual(document.annotations.count, 3)
        XCTAssertTrue(document.annotations[0] === first)
        XCTAssertTrue(document.annotations[1] === second)
        XCTAssertTrue(document.annotations[2] === third)
    }

    func testRemoveAllOnEmptyCanvasIsNoop() {
        let document = makeDocument()
        let undoManager = makeUndoManager(for: document)

        // Deliberately without a group: with `groupsByEvent = false` any undo registration
        // outside a group would trap. The test passes precisely because clearing an empty
        // document writes nothing.
        document.removeAll()

        XCTAssertFalse(undoManager.canUndo)
    }

    // MARK: - Crop

    func testUndoRestoresThePreviousCrop() {
        let document = makeDocument(crop: CGRect(x: 100, y: 100, width: 100, height: 100))
        let undoManager = makeUndoManager(for: document)

        step(undoManager) {
            document.setCrop(CGRect(x: 50, y: 100, width: 150, height: 100))
        }
        XCTAssertEqual(document.imageSize, CGSize(width: 150, height: 100))

        undoManager.undo()

        XCTAssertEqual(document.cropRect, CGRect(x: 100, y: 100, width: 100, height: 100))
        XCTAssertEqual(document.image.width, 100, "the cutout followed the crop back")
    }

    /// A live resize sets the crop on every mouse step; only the gesture as a whole belongs in the
    /// undo stack, otherwise ⌘Z has to be pressed dozens of times to undo one drag.
    func testIntermediateResizeStepsDoNotPileUpInUndo() {
        let document = makeDocument(crop: CGRect(x: 100, y: 100, width: 100, height: 100))
        let undoManager = makeUndoManager(for: document)
        let start = document.cropRect

        for width in stride(from: 110.0, through: 150.0, by: 10.0) {
            document.setCrop(CGRect(x: 100, y: 100, width: width, height: 100), undoable: false)
        }
        XCTAssertFalse(undoManager.canUndo, "nothing registered while the drag was running")

        step(undoManager) {
            document.registerCropUndo(from: start)
        }
        undoManager.undo()

        XCTAssertEqual(document.cropRect, start, "one press is enough")
    }

    /// Annotations are stored in the coordinates of the captured frame, so moving the crop must
    /// not touch them at all — neither the ones that stay visible nor the ones left outside.
    func testAnnotationsDoNotMoveWhenTheCropChanges() {
        let document = makeDocument(crop: CGRect(x: 100, y: 100, width: 100, height: 100))
        let arrow = ArrowAnnotation(start: CGPoint(x: 150, y: 150), style: .default)
        arrow.update(to: CGPoint(x: 190, y: 190))
        document.add(arrow)
        let before = arrow.boundingBox

        document.setCrop(CGRect(x: 50, y: 50, width: 200, height: 200))

        XCTAssertEqual(document.annotations.count, 1)
        XCTAssertEqual(arrow.boundingBox, before)
    }

    func testRemovingSelectedAnnotationClearsSelection() {
        let document = makeDocument()
        let arrow = ArrowAnnotation(start: .zero, style: .default)

        document.add(arrow)
        document.selection = arrow
        document.removeSelection()

        XCTAssertNil(document.selection)
        XCTAssertTrue(document.annotations.isEmpty)
    }
}
