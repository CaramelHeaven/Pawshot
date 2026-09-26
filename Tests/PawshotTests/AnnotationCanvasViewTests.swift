import AppKit
import Carbon.HIToolbox
@testable import Pawshot
import SwiftUI
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
            style: AnnotationStyle(color: .green, lineWidth: 2, fillOpacity: 0.25)
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

    // MARK: - A line and a rectangle hand over to V

    /// Released after A or R, the new object is selected and the editor is in V: it can be moved or
    /// given other ends at once. The pencil keeps drawing — see the test above.
    func testALineOrARectangleComesOutSelectedInV() throws {
        for (letter, keyCode) in [("a", kVK_ANSI_A), ("r", kVK_ANSI_R)] {
            let (canvas, document, _) = try makeCanvas()
            try press(canvas, letter, keyCode: keyCode)

            try drag(canvas, [CGPoint(x: 20, y: 20), CGPoint(x: 60, y: 50), CGPoint(x: 100, y: 90)])

            let drawn = try XCTUnwrap(document.annotations.first, letter)
            XCTAssertTrue(document.selection === drawn, "\(letter): what was drawn is selected")
            XCTAssertEqual(canvas.tool, .select, letter)
        }
    }

    /// A toolbar pick while a label is being typed finishes the label but keeps the pick: only the
    /// user's own ways of finishing a label switch to V.
    func testPickingAToolWhileTypingKeepsThatTool() throws {
        let (canvas, document, _) = try makeCanvas()
        try press(canvas, "t", keyCode: kVK_ANSI_T)
        try drag(canvas, [CGPoint(x: 30, y: 40)])
        canvas.typeIntoTextEditor("Hello")

        canvas.select(tool: .rectangle)

        XCTAssertEqual(document.annotations.count, 1)
        XCTAssertEqual(canvas.tool, .rectangle)
        XCTAssertNil(document.selection)
    }

    // MARK: - Text

    /// A click with T opens a label right there; it reaches the document only when the typing is
    /// done, and then comes out selected with the editor in V.
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
        XCTAssertTrue(document.selection === label, "the finished label is selected")
        XCTAssertEqual(canvas.tool, .select)
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
        XCTAssertEqual(canvas.tool, .text, "nothing to select, so the tool stays")
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
        XCTAssertEqual(document.style.fillOpacity, 1, "a plate with no fill to take its opacity from arrives solid")
        try press(canvas, "f", keyCode: kVK_ANSI_F)
        XCTAssertEqual(document.style.textStyle, .plain)
    }

    // MARK: - Palette, fill, line ends

    func testDigitsPickTheFourColoursAndFiveAsksForTheOwnOne() throws {
        let (canvas, document, _) = try makeCanvas()
        let delegate = CanvasDelegateSpy()
        canvas.delegate = delegate

        try press(canvas, "2", keyCode: kVK_ANSI_2)
        XCTAssertEqual(document.style.color, .systemGreen)
        try press(canvas, "3", keyCode: kVK_ANSI_3)
        XCTAssertEqual(document.style.color, .white)
        try press(canvas, "4", keyCode: kVK_ANSI_4)
        XCTAssertEqual(document.style.color, .black)
        try press(canvas, "4", keyCode: kVK_ANSI_4)
        XCTAssertEqual(document.style.color, .black, "4 no longer flips to white")

        try press(canvas, "5", keyCode: kVK_ANSI_5)
        XCTAssertEqual(delegate.customColorRequests, 1)
    }

    func testFWalksTheFillSteps() throws {
        let (canvas, document, _) = try makeCanvas()
        try press(canvas, "r", keyCode: kVK_ANSI_R)

        var seen: [CGFloat] = []
        for _ in 0 ..< 4 {
            try press(canvas, "f", keyCode: kVK_ANSI_F)
            seen.append(document.style.fillOpacity)
        }
        XCTAssertEqual(seen, [0.3, 0.6, 1, 0])
    }

    /// A again with the line already on walks its ends instead of picking the tool once more.
    func testAWalksTheLineEnds() throws {
        let (canvas, document, _) = try makeCanvas()

        try press(canvas, "a", keyCode: kVK_ANSI_A)
        XCTAssertEqual(canvas.tool, .arrow)
        XCTAssertEqual(document.style.lineEnds, .end, "the first A only picks the tool")

        try press(canvas, "a", keyCode: kVK_ANSI_A)
        XCTAssertEqual(document.style.lineEnds, .both)
        try press(canvas, "a", keyCode: kVK_ANSI_A)
        XCTAssertEqual(document.style.lineEnds, .none)
        try press(canvas, "a", keyCode: kVK_ANSI_A)
        XCTAssertEqual(document.style.lineEnds, .end)
    }

    // MARK: - The cursor under something drawn on top

    /// SwiftUI drawn over a representable view is invisible to `hitTest`: AppKit finds the canvas
    /// under the panel as well. Measured here, which is why the panel reports its frame instead.
    func testHitTestSeesTheCanvasUnderASwiftUIPanel() throws {
        let document = try makeDocument(crop: CGRect(x: 0, y: 0, width: 200, height: 200))
        let canvas = AnnotationCanvasView(document: document)
        let content = NSHostingView(rootView: CanvasOnly(canvas: canvas)
            .frame(width: 200, height: 200)
            .overlay(alignment: .bottom) {
                Color.gray.frame(width: 120, height: 40).contentShape(.rect).onTapGesture {}
            })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = content
        content.layoutSubtreeIfNeeded()

        // Window coordinates count from the bottom left: the panel is at y 0…40.
        let hit = content.hitTest(content.convert(CGPoint(x: 100, y: 20), from: nil))
        XCTAssertTrue(hit === canvas, "if this changes, hitTest could replace the reported frame")
    }

    /// What the floating tools report is their frame as drawn — with the scale in it. Measured, since
    /// the canvas's exclusion depends on it.
    func testAFrameMeasuredInsideAScaleIsTheScaledOne() {
        final class Box { var frame: CGRect = .zero }
        let box = Box()
        let content = NSHostingView(rootView: Color.gray
            .frame(width: 100, height: 40)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { box.frame = $0 }
            .scaleEffect(1.5, anchor: .bottom)
            .frame(width: 200, height: 200, alignment: .bottom))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(box.frame.width, 150, accuracy: 1)
    }

    /// The canvas leaves the cursor alone inside the frame the floating tools report.
    func testTheCanvasLeavesTheCursorToTheFloatingTools() throws {
        let document = try makeDocument(crop: CGRect(x: 0, y: 0, width: 200, height: 200))
        let canvas = AnnotationCanvasView(document: document)
        XCTAssertTrue(canvas.ownsCursor(atWindowPoint: CGPoint(x: 100, y: 20)))

        canvas.cursorExclusion = CGRect(x: 40, y: 0, width: 120, height: 40)

        XCTAssertFalse(canvas.ownsCursor(atWindowPoint: CGPoint(x: 100, y: 20)), "over the tools")
        XCTAssertTrue(canvas.ownsCursor(atWindowPoint: CGPoint(x: 100, y: 150)), "over the open shot")
    }

    // MARK: - Text size and weight

    private func pressShifted(_ canvas: AnnotationCanvasView, _ letter: String, keyCode: Int) throws {
        try canvas.keyDown(with: XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: letter,
            charactersIgnoringModifiers: letter,
            isARepeat: false,
            keyCode: UInt16(keyCode)
        )))
    }

    /// With text, [ ] are the size and ⇧[ ⇧] the weight; with shapes, [ ] stay the width.
    func testBracketsAreSizeAndShiftedBracketsWeightForText() throws {
        // The test host is the app, and it picks up the family chosen in its real settings.
        let family = LabelFont.family
        LabelFont.family = nil
        defer { LabelFont.family = family }
        let (canvas, document, _) = try makeCanvas()
        try press(canvas, "t", keyCode: kVK_ANSI_T)
        let width = document.style.lineWidth

        try press(canvas, "]", keyCode: kVK_ANSI_RightBracket)
        XCTAssertEqual(document.style.textSize, 24)
        XCTAssertEqual(document.style.lineWidth, width, "the width is left alone")

        try pressShifted(canvas, "}", keyCode: kVK_ANSI_RightBracket)
        XCTAssertEqual(document.style.textWeight, .bold, "semibold → bold")

        try press(canvas, "r", keyCode: kVK_ANSI_R)
        try press(canvas, "]", keyCode: kVK_ANSI_RightBracket)
        XCTAssertEqual(document.style.lineWidth, AnnotationStyle.LineWidth.next(after: width))
    }

    /// A drag from a selected label's corner handle makes the text bigger, as one step of ⌘Z.
    func testDraggingALabelsCornerResizesIt() throws {
        let (canvas, document, undoManager) = try makeCanvas()
        let label = TextAnnotation(origin: CGPoint(x: 30, y: 30), style: .default, text: "Hi")
        undoManager.beginUndoGrouping()
        document.add(label)
        undoManager.endUndoGrouping()
        canvas.select(tool: .select)
        document.selection = label
        let corner = SelectionGeometry.Corner.bottomRight.point(of: label.selectionFrame)

        undoManager.beginUndoGrouping()
        try drag(canvas, [corner, CGPoint(x: corner.x + 20, y: corner.y + 10), CGPoint(x: corner.x + 40, y: corner.y + 20)])
        undoManager.endUndoGrouping()

        XCTAssertGreaterThan(label.style.textSize, 18)
        XCTAssertEqual(document.annotations.count, 1, "resized, not drawn")
        undoManager.undo()
        XCTAssertEqual(label.style.textSize, 18)
    }

    // MARK: - A turned label

    /// The field that edits a label on a turned shot must turn the same way, or the caret runs
    /// across the letters instead of along them. Converting the field's own points into the canvas
    /// shows which way AppKit actually turned it — nothing else here can see the screen.
    func testTheTextFieldTurnsWithATurnedLabel() throws {
        let document = try makeDocument(crop: CGRect(x: 0, y: 0, width: 200, height: 200))
        let canvas = AnnotationCanvasView(document: document)
        let label = TextAnnotation(origin: CGPoint(x: 60, y: 30), style: .default, text: "Hello")
        label.rotate(clockwise: true, in: CGSize(width: 200, height: 200))

        let editor = NSTextView(frame: .zero)
        canvas.addSubview(editor)
        canvas.place(editor, over: label)

        let start = editor.convert(CGPoint.zero, to: canvas)
        let along = editor.convert(CGPoint(x: 20, y: 0), to: canvas)

        XCTAssertEqual(start.x, label.origin.x, accuracy: 0.5, "the text starts at the label's corner")
        XCTAssertEqual(start.y, label.origin.y, accuracy: 0.5)
        XCTAssertEqual(along.x, start.x, accuracy: 0.5, "turned clockwise, the line of text runs down")
        XCTAssertEqual(along.y, start.y + 20, accuracy: 0.5)
    }
}

@MainActor
private final class CanvasDelegateSpy: AnnotationCanvasDelegate {
    var customColorRequests = 0

    func canvasDidChangeTool(_: AnnotationCanvasView) {}
    func canvasDidChangeStyle(_: AnnotationCanvasView) {}
    func canvasDidRequestClose(_: AnnotationCanvasView) {}
    func canvasDidRequestCustomColor(_: AnnotationCanvasView) {
        customColorRequests += 1
    }
}

private struct CanvasOnly: NSViewRepresentable {
    let canvas: AnnotationCanvasView

    func makeNSView(context _: Context) -> AnnotationCanvasView {
        canvas
    }

    func updateNSView(_: AnnotationCanvasView, context _: Context) {}
}
