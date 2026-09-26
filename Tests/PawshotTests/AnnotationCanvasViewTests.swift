import AppKit
import Carbon.HIToolbox
@testable import Pawshot
import XCTest

@MainActor
final class AnnotationCanvasViewTests: XCTestCase {
    /// A white frame with a red stripe down its left half. `CGContext` counts from the bottom left,
    /// but the X axis needs no flipping, so the stripe is simply the left half.
    private func makeDocument(crop: CGRect) throws -> EditorDocument {
        let size = CGSize(width: 200, height: 200)
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))

        let frame = try CapturedFrame(
            image: XCTUnwrap(context.makeImage()),
            displayFrame: CGRect(origin: .zero, size: size),
            scale: 1
        )
        return try XCTUnwrap(EditorDocument(frame: frame, cropRect: crop))
    }

    private func render(_ canvas: AnnotationCanvasView) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        return rep
    }

    private func color(_ rep: NSBitmapImageRep, atFraction point: CGPoint) throws -> NSColor {
        try XCTUnwrap(
            rep.colorAt(
                x: Int(CGFloat(rep.pixelsWide) * point.x),
                y: Int(CGFloat(rep.pixelsHigh) * point.y)
            )?.usingColorSpace(.deviceRGB)
        )
    }

    /// The canvas shows the crop, not the whole frame: a crop over the white half must not leak
    /// the red one.
    func testCanvasShowsTheCroppedRegionOnly() throws {
        let document = try makeDocument(crop: CGRect(x: 100, y: 0, width: 100, height: 200))
        let canvas = AnnotationCanvasView(document: document)

        let rep = try render(canvas)
        let sample = try color(rep, atFraction: CGPoint(x: 0.5, y: 0.5))

        XCTAssertGreaterThan(sample.blueComponent, 0.5, "the white half, not the red one")
    }

    /// Resizing the shot re-cuts it: the same canvas has to start showing the pixels that just
    /// joined the crop, and to grow to the new size.
    func testCanvasFollowsTheCropAfterAResize() throws {
        let document = try makeDocument(crop: CGRect(x: 100, y: 0, width: 100, height: 200))
        let canvas = AnnotationCanvasView(document: document)

        document.setCrop(CGRect(x: 0, y: 0, width: 100, height: 200))
        canvas.documentCropDidChange()

        let rep = try render(canvas)
        let sample = try color(rep, atFraction: CGPoint(x: 0.5, y: 0.5))

        XCTAssertEqual(canvas.frame.width, 100)
        XCTAssertGreaterThan(sample.redComponent, sample.blueComponent, "now over the red half")
    }

    /// The trap for the coordinate translation in `draw(_:)`: annotations are stored in the frame's
    /// coordinates, so an object at x = 110 of the frame has to land at x = 10 of a canvas whose
    /// crop starts at 100. Get the sign of the shift wrong and it lands off-canvas — silently.
    func testAnnotationIsDrawnRelativeToTheCrop() throws {
        let document = try makeDocument(crop: CGRect(x: 100, y: 100, width: 100, height: 100))
        let canvas = AnnotationCanvasView(document: document)

        let marker = RectangleAnnotation(
            start: CGPoint(x: 110, y: 110),
            style: AnnotationStyle(color: .green, lineWidth: 2, isFilled: true)
        )
        marker.update(to: CGPoint(x: 140, y: 140))
        document.add(marker)

        let rep = try render(canvas)
        let onMarker = try color(rep, atFraction: CGPoint(x: 0.25, y: 0.25))
        let awayFromIt = try color(rep, atFraction: CGPoint(x: 0.75, y: 0.75))

        XCTAssertGreaterThan(onMarker.greenComponent, onMarker.redComponent, "the marker is here")
        XCTAssertEqual(awayFromIt.greenComponent, awayFromIt.redComponent, accuracy: 0.05)
    }

    /// The tool keys used to be read straight off the character the layout produced, so on ЙЦУКЕН
    /// the blur key printed `и` and nothing happened. The key code is what carries the meaning.
    func testCyrillicKeyStillPicksTheTool() throws {
        let document = try makeDocument(crop: CGRect(origin: .zero, size: CGSize(width: 200, height: 200)))
        let canvas = AnnotationCanvasView(document: document)

        try canvas.keyDown(with: XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "и",
            charactersIgnoringModifiers: "и",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_B)
        )))

        XCTAssertEqual(canvas.tool, .blur)
    }

    // MARK: - Mouse and keys without a window

    /// The canvas has no window in these tests, so "window coordinates" are its own — flipped back,
    /// because `convert(_:from: nil)` expects AppKit's bottom-left origin.
    private func mouse(
        _ type: NSEvent.EventType,
        at point: CGPoint,
        in canvas: NSView,
        flags: NSEvent.ModifierFlags = [],
        clicks: Int = 1
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: CGPoint(x: point.x, y: canvas.bounds.height - point.y),
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clicks,
            pressure: 1
        ))
    }

    private func drag(
        _ canvas: AnnotationCanvasView,
        _ points: [CGPoint],
        flags: NSEvent.ModifierFlags = []
    ) throws {
        guard let first = points.first, let last = points.last else { return }
        try canvas.mouseDown(with: mouse(.leftMouseDown, at: first, in: canvas, flags: flags))
        for point in points.dropFirst() {
            try canvas.mouseDragged(with: mouse(.leftMouseDragged, at: point, in: canvas, flags: flags))
        }
        try canvas.mouseUp(with: mouse(.leftMouseUp, at: last, in: canvas, flags: flags))
    }

    private func press(_ canvas: AnnotationCanvasView, _ letter: String, keyCode: Int) throws {
        try canvas.keyDown(with: XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: letter,
            charactersIgnoringModifiers: letter,
            isARepeat: false,
            keyCode: UInt16(keyCode)
        )))
    }

    private func makeCanvas() throws -> (AnnotationCanvasView, EditorDocument, UndoManager) {
        let document = try makeDocument(crop: CGRect(origin: .zero, size: CGSize(width: 200, height: 200)))
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        document.undoManager = undoManager
        return (AnnotationCanvasView(document: document), document, undoManager)
    }

    // MARK: - The tool stays, nothing gets selected

    /// D, a stroke, and straight away another one starting inside the first one's frame: two
    /// strokes. It used to move the first stroke instead, because a new stroke came out selected
    /// and a selected object moved under any tool.
    func testPencilKeepsDrawingOnTopOfTheLastStroke() throws {
        let (canvas, document, _) = try makeCanvas()
        try press(canvas, "d", keyCode: kVK_ANSI_D)

        try drag(canvas, [CGPoint(x: 20, y: 20), CGPoint(x: 80, y: 60), CGPoint(x: 120, y: 120)])
        try drag(canvas, [CGPoint(x: 60, y: 60), CGPoint(x: 90, y: 40), CGPoint(x: 100, y: 30)])

        XCTAssertEqual(document.annotations.count, 2)
        XCTAssertNil(document.selection, "what was drawn is not selected")
        XCTAssertEqual(canvas.tool, .pencil)
    }

    /// Holding ⌘ moves whatever is under the cursor without leaving the drawing tool, and nothing
    /// stays selected afterwards.
    func testCommandDragMovesAnObjectUnderADrawingTool() throws {
        let (canvas, document, _) = try makeCanvas()
        let frame = RectangleAnnotation(start: CGPoint(x: 20, y: 20), style: .default)
        frame.update(to: CGPoint(x: 80, y: 80))
        document.add(frame)
        try press(canvas, "d", keyCode: kVK_ANSI_D)
        let before = frame.boundingBox.minX

        try drag(canvas, [CGPoint(x: 20, y: 50), CGPoint(x: 35, y: 50), CGPoint(x: 50, y: 50)], flags: [.command])

        XCTAssertEqual(document.annotations.count, 1, "moved, not drawn")
        XCTAssertEqual(frame.boundingBox.minX - before, 30, accuracy: 0.5)
        XCTAssertNil(document.selection)
        XCTAssertEqual(canvas.tool, .pencil)
    }

    // MARK: - Text

    /// A click with T opens a label right there; it reaches the document only when the typing is
    /// done, and the tool stays T for the next one.
    func testClickWithTheTextToolTypesALabelInPlace() throws {
        let (canvas, document, _) = try makeCanvas()
        try press(canvas, "t", keyCode: kVK_ANSI_T)

        try drag(canvas, [CGPoint(x: 30, y: 40)])
        XCTAssertTrue(canvas.isEditingText)
        XCTAssertTrue(document.annotations.isEmpty, "not in the document while it is being typed")

        canvas.typeIntoTextEditor("Hello")
        canvas.cancelOperation(nil)

        let label = try XCTUnwrap(document.annotations.first as? TextAnnotation)
        XCTAssertEqual(label.text, "Hello")
        XCTAssertNil(label.fixedWidth, "a click gives text as wide as what is typed")
        XCTAssertNil(document.selection)
        XCTAssertEqual(canvas.tool, .text)
        XCTAssertFalse(canvas.isEditingText)
    }

    /// A label left empty leaves no trace — not in the document, not in undo.
    func testEmptyLabelLeavesNothingBehind() throws {
        let (canvas, document, undoManager) = try makeCanvas()
        try press(canvas, "t", keyCode: kVK_ANSI_T)

        try drag(canvas, [CGPoint(x: 30, y: 40)])
        canvas.cancelOperation(nil)

        XCTAssertTrue(document.annotations.isEmpty)
        XCTAssertFalse(undoManager.canUndo)
    }

    /// Dragging the text tool sets the width of a box the text wraps inside.
    func testDraggingTheTextToolMakesAWrappingBox() throws {
        let (canvas, document, _) = try makeCanvas()
        try press(canvas, "t", keyCode: kVK_ANSI_T)

        try drag(canvas, [CGPoint(x: 20, y: 40), CGPoint(x: 80, y: 40), CGPoint(x: 120, y: 40)])
        canvas.typeIntoTextEditor("a label long enough to need more than one line in this box")
        canvas.cancelOperation(nil)

        let label = try XCTUnwrap(document.annotations.first as? TextAnnotation)
        XCTAssertEqual(label.fixedWidth ?? 0, 100, accuracy: 0.5)
        XCTAssertEqual(label.textFrame.width, 100, accuracy: 0.5)
        XCTAssertGreaterThan(label.textFrame.height, label.font.pointSize * 2, "it wrapped")
    }

    /// A double click on a label edits it with any tool, and the edit is one step of undo.
    func testDoubleClickEditsALabelAndUndoPutsTheOldWordsBack() throws {
        let (canvas, document, undoManager) = try makeCanvas()
        let label = TextAnnotation(origin: CGPoint(x: 30, y: 40), style: .default, text: "Old")
        undoManager.beginUndoGrouping()
        document.add(label)
        undoManager.endUndoGrouping()
        try press(canvas, "d", keyCode: kVK_ANSI_D)

        let point = CGPoint(x: label.textFrame.midX, y: label.textFrame.midY)
        try canvas.mouseDown(with: mouse(.leftMouseDown, at: point, in: canvas, clicks: 2))
        XCTAssertTrue(canvas.isEditingText)

        canvas.typeIntoTextEditor("New")
        undoManager.beginUndoGrouping()
        canvas.cancelOperation(nil)
        undoManager.endUndoGrouping()
        XCTAssertEqual(label.text, "New")
        XCTAssertEqual(document.annotations.count, 1)

        canvas.undo(nil)
        XCTAssertEqual(label.text, "Old")
    }

    /// With the text tool, F walks the label styles instead of toggling fill.
    func testFWalksTheTextStylesUnderTheTextTool() throws {
        let (canvas, document, _) = try makeCanvas()
        try press(canvas, "t", keyCode: kVK_ANSI_T)

        try press(canvas, "f", keyCode: kVK_ANSI_F)
        XCTAssertEqual(document.style.textStyle, .outline)
        try press(canvas, "f", keyCode: kVK_ANSI_F)
        XCTAssertEqual(document.style.textStyle, .plate)
        try press(canvas, "f", keyCode: kVK_ANSI_F)
        XCTAssertEqual(document.style.textStyle, .plain)
        XCTAssertFalse(document.style.isFilled, "fill of shapes is untouched")
    }
}
