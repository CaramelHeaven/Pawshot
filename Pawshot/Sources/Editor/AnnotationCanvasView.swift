import AppKit
import Carbon.HIToolbox
import os

@MainActor
protocol AnnotationCanvasDelegate: AnyObject {
    func canvasDidChangeTool(_ canvas: AnnotationCanvasView)
    func canvasDidChangeStyle(_ canvas: AnnotationCanvasView)
    /// Key 5: the colour of one's own lives with the toolbar, not with the canvas.
    func canvasDidRequestCustomColor(_ canvas: AnnotationCanvasView)
}

/// The shot and the annotations on top of it. The view is exactly the size of the crop, so a
/// point inside it is a point of the shot — shifted by the crop origin, it is a point of the
/// captured frame, which is what annotations are stored in.
final class AnnotationCanvasView: NSView, NSMenuItemValidation {
    weak var delegate: AnnotationCanvasDelegate?

    let document: EditorDocument

    private(set) var tool: AnnotationTool = .select {
        didSet {
            guard tool != oldValue else { return }
            let from = oldValue.rawValue
            let to = tool.rawValue
            let by = NSApp.currentEvent?.type == .keyDown ? "key" : "mouse"
            Self.logger.notice("tool \(from, privacy: .public) → \(to, privacy: .public) by \(by, privacy: .public)")
            finishTextEditing()
            window?.invalidateCursorRects(for: self)
            delegate?.canvasDidChangeTool(self)
        }
    }

    /// The object currently being drawn with the mouse.
    private var draftAnnotation: Annotation?
    private var lastDragPoint: CGPoint?
    private var isMovingSelection = false

    /// A handle of the selected object being dragged: what each mouse position does to it, and how
    /// the gesture ends up as one step of ⌘Z.
    private struct Reshaping {
        /// Applies the mouse position and returns the chip's text, if the drag has a number to show.
        let update: (CGPoint, NSEvent.ModifierFlags) -> String?
        let finish: () -> Void
    }

    private var reshaping: Reshaping?
    /// The number shown by the cursor while a handle is dragged: a size, a length, an angle.
    private var reshapeChip: (text: String, at: CGPoint)?
    /// A move made by holding ⌘ under a drawing tool. The selection it makes is only for the
    /// duration of the drag: once it ends, the tool draws again and nothing stays selected.
    private var isTemporaryMove = false
    /// ⌘ is down right now — tracked for the cursor, which has to show the hand before the click.
    private var isCommandHeld = false

    private var textEditor: NSTextView?
    private var editingText: TextAnnotation?
    private var trackingArea: NSTrackingArea?

    private var cachedImage: NSImage

    init(document: EditorDocument) {
        self.document = document
        cachedImage = NSImage(cgImage: document.image, size: document.imageSize)
        super.init(frame: CGRect(origin: .zero, size: document.imageSize))

        document.onChange = { [weak self] in
            guard let self else { return }
            needsDisplay = true
            // The toolbar mirrors the selection: its colour, its fill, a line's ends.
            delegate?.canvasDidChangeStyle(self)
        }
    }

    /// The shot got bigger or smaller: the cutout is a different image now, and the view has to
    /// match its new size. Annotations are untouched on purpose — they live in the coordinates of
    /// the captured frame, not of the crop.
    ///
    /// Called by `EditorWindowController`, which owns the order of things during a resize: the
    /// canvas first, the window after it.
    func documentCropDidChange() {
        finishTextEditing()
        cachedImage = NSImage(cgImage: document.image, size: document.imageSize)
        updateFrameForCrop()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unused — the UI is built in code")
    }

    /// Coordinates run top to bottom, like the image's.
    override var isFlipped: Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    // MARK: - Tools and style

    /// Picking a tool clears the selection: while an object is selected, a drag inside its frame
    /// moves the object instead of drawing. Press a tool key and you're drawing again, including
    /// on top of what you just drew. The reset lives here rather than in `tool`'s `didSet`: that
    /// one stays silent when the tool hasn't changed, and pressing the same letter twice has to
    /// work.
    func select(tool: AnnotationTool) {
        if document.selection != nil {
            document.selection = nil
            needsDisplay = true
        }
        if tool == self.tool {
            // `tool`'s `didSet` stays silent on the same tool; the press itself is worth a line.
            let name = tool.rawValue
            Self.logger.notice("tool \(name, privacy: .public) again")
        }
        self.tool = tool
    }

    // MARK: - Size

    /// The shot is always shown at its own size — one point of the view is one point of the shot.
    private func updateFrameForCrop() {
        finishTextEditing()
        setFrameSize(document.imageSize)
        needsDisplay = true
    }

    // MARK: - Coordinates

    /// View point → a point of the captured frame. The view shows a window into the frame, and
    /// annotations are stored in the frame's coordinates so that resizing the shot never moves
    /// them — hence the shift by the crop origin.
    private func imagePoint(from event: NSEvent) -> CGPoint {
        let viewPoint = convert(event.locationInWindow, from: nil)
        return CGPoint(
            x: viewPoint.x + document.cropRect.minX,
            y: viewPoint.y + document.cropRect.minY
        )
    }

    /// A thin line is hard to hit dead on, so a hit counts within a few points of it.
    private var hitTolerance: CGFloat {
        6
    }

    // MARK: - Cursor

    /// The cursor is driven by hand rather than through `addCursorRect`: it has to change not only
    /// with the tool but also with whether the pointer is over the selected object — otherwise it
    /// is not obvious that the object can be dragged.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .cursorUpdate, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: imagePoint(from: event))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: imagePoint(from: event))
    }

    /// Where the tools float over the shot, in window coordinates; `nil` when they sit under it.
    var cursorExclusion: CGRect?

    /// Whether the canvas owns the cursor at this point of the window. The tracking area fires by
    /// geometry, under anything drawn on top too, and setting the tool's cursor under the floating
    /// tools took the resize cursor away from their grips. `hitTest` can't tell: SwiftUI content
    /// over a representable view is not a view of its own, and the canvas answers there too —
    /// measured in `AnnotationCanvasViewTests`. So the panel reports its frame instead.
    ///
    /// And only over the canvas itself: first responder, it gets mouse moves from all over the
    /// window, and setting the tool's cursor at the window's edge fought the system's resize cursor
    /// there — the edge that grows or crops the shot caught in about a pixel (the owner,
    /// 2026-09-30).
    func ownsCursor(atWindowPoint point: CGPoint) -> Bool {
        convert(visibleRect, to: nil).contains(point) && !(cursorExclusion?.contains(point) ?? false)
    }

    private func updateCursor(at point: CGPoint) {
        guard !isEditingText else { return }
        if let window, !ownsCursor(atWindowPoint: window.mouseLocationOutsideOfEventStream) {
            return
        }

        let moves = tool == .select || isCommandHeld
        if let (selection, handle) = handle(at: point) {
            Self.cursor(for: CanvasHandles.cursorKind(for: handle, of: selection)).set()
        } else if isMovingSelection {
            NSCursor.closedHand.set()
        } else if moves, isOverSelection(point) || (isCommandHeld && isOverAnnotation(point)) {
            NSCursor.openHand.set()
        } else {
            tool.cursor.set()
        }
    }

    private func isOverAnnotation(_ point: CGPoint) -> Bool {
        document.annotation(at: point, tolerance: hitTolerance) != nil
    }

    override func flagsChanged(with event: NSEvent) {
        isCommandHeld = event.modifierFlags.contains(.command)
        if let window {
            let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            updateCursor(at: CGPoint(
                x: location.x + document.cropRect.minX,
                y: location.y + document.cropRect.minY
            ))
        }
        super.flagsChanged(with: event)
    }

    // MARK: - Drawing

    override func draw(_: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        // Shift the origin onto the crop: after this the context speaks the coordinates of the
        // captured frame, which is what annotations are stored in.
        let transform = NSAffineTransform()
        transform.translateX(by: -document.cropRect.minX, yBy: -document.cropRect.minY)
        transform.concat()

        cachedImage.draw(in: document.cropRect)

        for annotation in document.annotations {
            annotation.draw()
        }
        draftAnnotation?.draw()

        if let editingText {
            // A new label isn't in the document until the typing is done, so it is drawn here.
            if isEditingNewText {
                editingText.draw()
            }
            drawEditingFrame(around: editingText)
        } else if let textPlacement {
            drawTextBoxPreview(textPlacement)
        }

        if let selection = document.selection {
            if tool == .select {
                drawHandles(of: selection)
            } else {
                selection.drawSelectionIndicator()
            }
        }
        if let reshapeChip {
            drawChip(reshapeChip.text, at: reshapeChip.at)
        }
    }

    // MARK: - Handles

    /// The handles of the selected object under V. A line has no frame — circles on its ends, a
    /// diamond halfway and the heads button beside it. A rectangle, a blur and a label get their
    /// frame turned with them and squares on its corners; their sides and the turning zones are
    /// not drawn, the cursor shows them. Anything else keeps the plain frame.
    private func drawHandles(of selection: Annotation) {
        if let arrow = selection as? ArrowAnnotation {
            drawLineHandles(of: arrow)
            return
        }
        guard let box = CanvasHandles.handleBox(of: selection) else {
            selection.drawSelectionIndicator()
            return
        }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: box.center.x, yBy: box.center.y)
        transform.rotate(byRadians: box.angle)
        transform.concat()

        let frame = NSBezierPath(roundedRect: box.local, xRadius: 3, yRadius: 3)
        frame.lineWidth = 1.5
        Tokens.pawNSColor.withAlphaComponent(0.95).setStroke()
        frame.stroke()
        for corner in SelectionGeometry.Corner.allCases {
            drawSquareHandle(at: corner.point(of: box.local))
        }
    }

    private func drawSquareHandle(at point: CGPoint) {
        let side = CanvasHandles.squareSide
        let handle = NSBezierPath(
            roundedRect: CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side),
            xRadius: 2,
            yRadius: 2
        )
        NSColor.white.setFill()
        handle.fill()
        Tokens.pawNSColor.setStroke()
        handle.lineWidth = 1.5
        handle.stroke()
    }

    private func drawLineHandles(of arrow: ArrowAnnotation) {
        let radius = CanvasHandles.endRadius(of: arrow)
        for point in [arrow.start, arrow.end] {
            let circle = NSBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
            NSColor.white.setFill()
            circle.fill()
            Tokens.pawNSColor.setStroke()
            circle.lineWidth = 1.5
            circle.stroke()
        }

        let middle = arrow.middle
        let diamond = NSBezierPath()
        diamond.move(to: CGPoint(x: middle.x, y: middle.y - 5))
        diamond.line(to: CGPoint(x: middle.x + 5, y: middle.y))
        diamond.line(to: CGPoint(x: middle.x, y: middle.y + 5))
        diamond.line(to: CGPoint(x: middle.x - 5, y: middle.y))
        diamond.close()
        NSColor.white.setFill()
        diamond.fill()
        Tokens.pawNSColor.setStroke()
        diamond.lineWidth = 1.5
        diamond.stroke()

        drawHeadsButton(of: arrow)
    }

    /// A small round button beside the line with what a click turns its heads into, drawn along
    /// the line: → at the end, ← at the start, ↔ at both.
    private func drawHeadsButton(of arrow: ArrowAnnotation) {
        let centre = CanvasHandles.headsButtonCentre(of: arrow)
        let radius = CanvasHandles.buttonRadius
        let button = NSBezierPath(ovalIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
        NSColor.white.withAlphaComponent(0.92).setFill()
        button.fill()
        NSColor.black.withAlphaComponent(0.25).setStroke()
        button.lineWidth = 1
        button.stroke()

        let glyph = arrow.heads.next.glyph as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.black.withAlphaComponent(0.75),
        ]
        let size = glyph.size(withAttributes: attributes)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: centre.x, yBy: centre.y)
        transform.rotate(byRadians: atan2(arrow.end.y - arrow.start.y, arrow.end.x - arrow.start.x))
        transform.concat()
        glyph.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2), withAttributes: attributes)
    }

    /// The black pill with a number that follows the cursor while a handle is dragged.
    private func drawChip(_ text: String, at point: CGPoint) {
        let string = text as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = string.size(withAttributes: attributes)
        let chip = CGRect(x: point.x + 14, y: point.y + 14, width: textSize.width + 12, height: textSize.height + 4)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: chip, xRadius: chip.height / 2, yRadius: chip.height / 2).fill()
        string.draw(at: CGPoint(x: chip.minX + 6, y: chip.minY + 2), withAttributes: attributes)
    }

    /// The handle under the point, on the object selected under V.
    private func handle(at point: CGPoint) -> (Annotation, CanvasHandle)? {
        guard tool == .select, let selection = document.selection else { return nil }
        return CanvasHandles.handle(at: point, of: selection).map { (selection, $0) }
    }

    /// Points of the shot → pixels of the file, for the chip: that is the size that comes out.
    private func pixels(_ points: CGFloat) -> Int {
        Int((points * document.frame.scale).rounded())
    }

    /// What dragging `handle` does to `selection`. Every drag starts from the shape taken here, so
    /// letting go of ⇧ or ⌥ mid-drag lands where the mouse is, not where the snap was.
    private func beginReshaping(_ selection: Annotation, by handle: CanvasHandle, grabbedAt grab: CGPoint) -> Reshaping? {
        switch (selection, handle) {
        case let (arrow as ArrowAnnotation, .lineStart), let (arrow as ArrowAnnotation, .lineEnd):
            let start = arrow.shape
            let movesStart = handle == .lineStart
            let tip = movesStart ? start.start : start.end
            return Reshaping(update: { [weak self] point, flags in
                var shape = start
                let fixed = movesStart ? start.end : start.start
                var moved = CGPoint(x: point.x + tip.x - grab.x, y: point.y + tip.y - grab.y)
                if flags.contains(.shift) {
                    moved = SelectionGeometry.snappedEnd(fixed: fixed, moving: moved)
                }
                if movesStart {
                    shape.start = moved
                } else {
                    shape.end = moved
                }
                shape.control = start.control.map {
                    SelectionGeometry.carriedControl($0, from: (start.start, start.end), to: (shape.start, shape.end))
                }
                arrow.shape = shape
                let length = hypot(shape.end.x - shape.start.x, shape.end.y - shape.start.y)
                let angle = atan2(shape.end.y - shape.start.y, shape.end.x - shape.start.x)
                return "\(self?.pixels(length) ?? 0) px · \(SelectionGeometry.displayDegrees(angle))°"
            }, finish: { [weak self] in
                self?.document.finishReshaping(arrow, from: start)
            })

        case let (arrow as ArrowAnnotation, .bend):
            let start = arrow.shape
            let middle = arrow.middle
            return Reshaping(update: { point, _ in
                var shape = start
                shape.control = SelectionGeometry.control(
                    through: CGPoint(x: point.x + middle.x - grab.x, y: point.y + middle.y - grab.y),
                    start: start.start,
                    end: start.end
                )
                arrow.shape = shape
                return nil
            }, finish: { [weak self] in
                self?.document.finishReshaping(arrow, from: start)
            })

        case let (label as TextAnnotation, .box(side)):
            return labelReshaping(label, side: side, grabbedAt: grab)

        case let (label as TextAnnotation, .turn):
            let start = label.shape
            let centre = label.box.center
            return Reshaping(update: { point, flags in
                let angle = SelectionGeometry.turnedAngle(
                    from: start.angle,
                    centre: centre,
                    grab: grab,
                    mouse: point,
                    snaps: flags.contains(.shift)
                )
                label.rotate(from: start, to: angle)
                return "\(SelectionGeometry.displayDegrees(angle))°"
            }, finish: { [weak self] in
                self?.document.finishReshaping(label, from: start)
            })

        case let (rectangle as RectangleAnnotation, .turn):
            let start = rectangle.shape
            return Reshaping(update: { point, flags in
                var shape = start
                shape.angle = SelectionGeometry.turnedAngle(
                    from: start.angle,
                    centre: start.center,
                    grab: grab,
                    mouse: point,
                    snaps: flags.contains(.shift)
                )
                rectangle.shape = shape
                return "\(SelectionGeometry.displayDegrees(shape.angle))°"
            }, finish: { [weak self] in
                self?.document.finishReshaping(rectangle, from: start)
            })

        case let (rectangle as RectangleAnnotation, .box(side)):
            // A circle stays one: its corners always keep the proportions.
            return boxReshaping(rectangle, side: side, grabbedAt: grab, alwaysKeepsAspect: rectangle.style.shapeKind.isRound)

        case let (blur as BlurAnnotation, .box(side)):
            return boxReshaping(blur, side: side, grabbedAt: grab)

        default:
            let kind = AnnotationTool.drawing(selection).rawValue
            let name = String(describing: handle)
            Self.logger.error("no reshaping for \(kind, privacy: .public) handle \(name, privacy: .public)")
            return nil
        }
    }

    /// A corner or a side of a rectangle or a blur: ⇧ keeps a corner's proportions, ⌥ grows it
    /// from the middle.
    private func boxReshaping<Object: Reshapable>(
        _ object: Object,
        side: SelectionGeometry.Handle,
        grabbedAt grab: CGPoint,
        alwaysKeepsAspect: Bool = false
    ) -> Reshaping? where Object.Shape == SelectionGeometry.RotatedBox {
        let start = object.shape
        return Reshaping(update: { [weak self] point, flags in
            let shape = SelectionGeometry.resized(
                start,
                dragging: side,
                grabbedAt: grab,
                mouse: point,
                keepsAspect: alwaysKeepsAspect || flags.contains(.shift),
                fromCentre: flags.contains(.option),
                minimumSide: 4
            )
            object.shape = shape
            return "\(self?.pixels(shape.size.width) ?? 0) × \(self?.pixels(shape.size.height) ?? 0)"
        }, finish: { [weak self] in
            self?.document.finishReshaping(object, from: start)
        })
    }

    /// A label's corner sets the size of its letters, as it always did; its left and right sides
    /// set the width its text wraps inside.
    private func labelReshaping(_ label: TextAnnotation, side: SelectionGeometry.Handle, grabbedAt grab: CGPoint) -> Reshaping? {
        let start = label.shape
        guard let box = CanvasHandles.handleBox(of: label) else { return nil }

        if side == .left || side == .right {
            let startWidth = label.fixedWidth ?? label.textFrame.width
            let startBox = label.box
            let rightSide = side == .right
            return Reshaping(update: { [weak self] point, _ in
                let delta = startBox.toLocal(point).x - startBox.toLocal(grab).x
                let width = max(label.fontSize, startWidth + (rightSide ? delta : -delta))
                label.setWidth(from: start, to: width, rightSide: rightSide)
                return "\(self?.pixels(width) ?? 0) px"
            }, finish: { [weak self] in
                self?.document.finishReshaping(label, from: start)
            })
        }

        let corner: SelectionGeometry.Corner = switch side {
        case .topLeft: .topLeft
        case .topRight: .topRight
        case .bottomLeft: .bottomLeft
        default: .bottomRight
        }
        let pinned = corner.opposite
        let anchor = box.corner(pinned)
        return Reshaping(update: { point, _ in
            let scale = SelectionGeometry.cornerScale(anchor: anchor, start: grab, current: point)
            let size = min(max(start.textSize * scale, 8), 400)
            label.resize(from: start, to: size, pinning: pinned)
            return "\(Int(size.rounded())) pt"
        }, finish: { [weak self] in
            self?.document.finishResizing(label, from: start)
        })
    }

    private static func cursor(for kind: CanvasHandles.CursorKind) -> NSCursor {
        switch kind {
        case let .resize(handle): NSCursor.frameResize(position: resizePosition(handle), directions: .all)
        case .turn: turnCursor
        case .point: NSCursor.crosshair
        case .button: NSCursor.arrow
        }
    }

    private static func resizePosition(_ handle: SelectionGeometry.Handle) -> NSCursor.FrameResizePosition {
        switch handle {
        case .topLeft: .topLeft
        case .top: .top
        case .topRight: .topRight
        case .right: .right
        case .bottomRight: .bottomRight
        case .bottom: .bottom
        case .bottomLeft: .bottomLeft
        case .left, .inside: .left
        }
    }

    /// AppKit has no turning cursor: a small curved arrow, black on a white outline so it reads on
    /// any shot, the way the overlay draws its crosshair.
    private static let turnCursor: NSCursor = {
        let size = CGSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            let arc = NSBezierPath()
            arc.appendArc(withCenter: CGPoint(x: 9, y: 9), radius: 5.5, startAngle: 200, endAngle: 470)
            arc.lineCapStyle = .round
            NSColor.white.setStroke()
            arc.lineWidth = 3.6
            arc.stroke()
            NSColor.black.setStroke()
            arc.lineWidth = 1.6
            arc.stroke()

            let tip = CGPoint(x: 9 + 5.5 * cos(470 * .pi / 180), y: 9 + 5.5 * sin(470 * .pi / 180))
            let head = NSBezierPath()
            head.move(to: CGPoint(x: tip.x + 3.5, y: tip.y))
            head.line(to: CGPoint(x: tip.x - 1.5, y: tip.y - 3))
            head.line(to: CGPoint(x: tip.x - 1.5, y: tip.y + 3))
            head.close()
            NSColor.white.setStroke()
            head.lineWidth = 1.5
            head.stroke()
            NSColor.black.setFill()
            head.fill()
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: 9, y: 9))
    }()

    /// A thin dashed frame around the label being typed: where it is, and how far it reaches.
    private func drawEditingFrame(around text: TextAnnotation) {
        let frame = NSBezierPath(rect: text.boundingBox.insetBy(dx: -2, dy: -2))
        frame.lineWidth = 1
        frame.setLineDash([3, 3], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        frame.stroke()
        frame.setLineDash([3, 3], count: 2, phase: 3)
        NSColor.black.withAlphaComponent(0.5).setStroke()
        frame.stroke()
    }

    /// While the text tool is being dragged: the box the text will wrap inside.
    private func drawTextBoxPreview(_ placement: TextPlacement) {
        guard let current = placement.current, placement.isBox(to: current) else { return }
        let box = CGRect(
            x: min(placement.start.x, current.x),
            y: placement.start.y,
            width: abs(current.x - placement.start.x),
            height: max(TextAnnotation(origin: .zero, style: document.style).fontSize * 1.3, 8)
        )
        let path = NSBezierPath(rect: box)
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        document.style.color.setStroke()
        path.stroke()
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)

        // A click outside the label being typed only finishes it — it doesn't also start the next
        // label or a stroke, which would be a surprise on top of a surprise.
        if isEditingText {
            finishTypingAndSelect()
            return
        }

        let point = imagePoint(from: event)

        // A double click on a label edits it, whatever the tool.
        if event.clickCount == 2, let text = textAnnotation(at: point) {
            draftAnnotation = nil
            startTextEditing(text)
            return
        }

        if let (selection, handle) = handle(at: point) {
            if handle == .heads, let arrow = selection as? ArrowAnnotation {
                document.turnHeads(of: arrow)
                needsDisplay = true
            } else {
                reshaping = beginReshaping(selection, by: handle, grabbedAt: point)
            }
            return
        }

        lastDragPoint = point
        dragOrigin = point

        let commandHeld = event.modifierFlags.contains(.command)
        isTemporaryMove = commandHeld && tool != .select

        switch CanvasInteraction.decide(
            tool: tool,
            isOverSelection: isOverSelection(point),
            commandHeld: commandHeld
        ) {
        case .moveSelection:
            isMovingSelection = true
            NSCursor.closedHand.set()
        case .selectUnderCursor:
            beginSelectionDrag(at: point)
        case .draw:
            beginDrawing(at: point, event: event)
        }
    }

    private func beginDrawing(at point: CGPoint, event _: NSEvent) {
        if tool == .text {
            // With the text tool, a click on a label edits it; anywhere else it starts a new one,
            // which the mouse-up decides the shape of.
            if let text = textAnnotation(at: point) {
                startTextEditing(text)
            } else {
                textPlacement = TextPlacement(start: point)
            }
            return
        }

        guard let annotation = tool.makeAnnotation(at: point, document: document) else {
            let name = tool.rawValue
            Self.logger.error("tool \(name, privacy: .public) made no object to draw")
            return
        }

        // Not selected: the tool stays, and the next press draws again.
        if tool.isSingleClick {
            document.add(annotation)
            needsDisplay = true
        } else {
            draftAnnotation = annotation
        }
    }

    /// A selected object is dragged by any point inside its frame, not only by its lines: for an
    /// unfilled rectangle `hitTest` deliberately catches the outline only, and a drag would never
    /// start in the middle of the shape.
    ///
    /// This does not extend to picking an object by clicking — that still goes through `hitTest`,
    /// otherwise among overlapping shapes the one with the wider frame would win instead of the
    /// one that was actually clicked.
    private func isOverSelection(_ point: CGPoint) -> Bool {
        guard let selection = document.selection else { return false }
        return selection.selectionFrame.contains(point)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = imagePoint(from: event)

        if let reshaping {
            reshapeChip = reshaping.update(point, event.modifierFlags).map { ($0, point) }
            needsDisplay = true
            return
        }

        defer { lastDragPoint = point }

        guard let lastDragPoint else { return }
        let delta = CGVector(dx: point.x - lastDragPoint.x, dy: point.y - lastDragPoint.y)

        if isMovingSelection, let selection = document.selection {
            selection.move(by: delta)
            needsDisplay = true
            return
        }

        if textPlacement != nil {
            textPlacement?.current = point
            needsDisplay = true
            return
        }

        guard let draftAnnotation else { return }

        // Holding space moves the unfinished object as a whole — a trick borrowed from Shottr.
        // Keyboard events don't arrive during a drag, so the key state is polled instead.
        if CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Space)) {
            draftAnnotation.move(by: delta)
        } else {
            // ⇧ draws a shape even: a square, a circle, an equilateral triangle.
            (draftAnnotation as? RectangleAnnotation)?.drawsEven = event.modifierFlags.contains(.shift)
            draftAnnotation.update(to: point)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let reshaping {
            self.reshaping = nil
            reshapeChip = nil
            reshaping.finish()
            delegate?.canvasDidChangeStyle(self)
            needsDisplay = true
            updateCursor(at: imagePoint(from: event))
            return
        }

        defer {
            lastDragPoint = nil
            isMovingSelection = false
            if isTemporaryMove {
                // The ⌘-move is over: back to drawing, with nothing left selected.
                isTemporaryMove = false
                document.selection = nil
                needsDisplay = true
            }
            updateCursor(at: imagePoint(from: event))
        }

        if isMovingSelection, let selection = document.selection, let start = dragOrigin {
            let point = imagePoint(from: event)
            let total = CGVector(dx: point.x - start.x, dy: point.y - start.y)
            // The object has already moved during the drag; the document gets the total offset
            // for the sake of undo.
            selection.move(by: CGVector(dx: -total.dx, dy: -total.dy))
            if total != .zero {
                let kind = AnnotationTool.drawing(selection).rawValue
                let commandHeld = isTemporaryMove
                Self.logger.notice("moved \(kind, privacy: .public) by \(Int(total.dx)),\(Int(total.dy)) pt, ⌘-held \(commandHeld, privacy: .public)")
            }
            document.move(selection, by: total)
            dragOrigin = nil
            return
        }

        if let placement = textPlacement {
            textPlacement = nil
            placeText(placement, releasedAt: imagePoint(from: event))
            return
        }

        guard let draftAnnotation else { return }
        self.draftAnnotation = nil

        // A line or a rectangle comes out selected, in V, ready to be moved or restyled. Anything
        // else is not selected: the tool stays, and the next stroke starts a new object — even on
        // top of this one.
        if draftAnnotation.isMeaningful {
            document.add(draftAnnotation)
            if tool.selectsWhatItDraws {
                tool = .select
                document.selection = draftAnnotation
            }
        } else {
            let kind = AnnotationTool.drawing(draftAnnotation).rawValue
            Self.logger.notice("\(kind, privacy: .public) too small, dropped")
        }
        needsDisplay = true
    }

    private var dragOrigin: CGPoint?

    private func beginSelectionDrag(at point: CGPoint) {
        let hit = document.annotation(at: point, tolerance: hitTolerance)
        document.selection = hit
        isMovingSelection = hit != nil
        if hit != nil {
            NSCursor.closedHand.set()
        }
        needsDisplay = true
    }

    // MARK: - Text

    /// A press of the text tool, until the mouse comes up: a click places text as wide as what is
    /// typed, a drag past a few points sets the width of a box the text wraps inside.
    struct TextPlacement {
        let start: CGPoint
        var current: CGPoint?

        static let dragThreshold: CGFloat = 4

        func isBox(to point: CGPoint) -> Bool {
            abs(point.x - start.x) > Self.dragThreshold
        }
    }

    private var textPlacement: TextPlacement?
    /// The label being typed isn't in the document yet: it goes in, as one step of undo, only if it
    /// ends up with words in it.
    private var isEditingNewText = false
    private var textBeforeEditing = ""

    private func textAnnotation(at point: CGPoint) -> TextAnnotation? {
        document.annotation(at: point, tolerance: hitTolerance) as? TextAnnotation
    }

    private func placeText(_ placement: TextPlacement, releasedAt point: CGPoint) {
        let annotation = if placement.isBox(to: point) {
            TextAnnotation(
                origin: CGPoint(x: min(placement.start.x, point.x), y: placement.start.y),
                style: document.style,
                fixedWidth: abs(point.x - placement.start.x)
            )
        } else {
            TextAnnotation(origin: placement.start, style: document.style)
        }
        startTextEditing(annotation, isNew: true)
    }

    /// Opens a label for typing. The text field is invisible apart from its caret and selection:
    /// the canvas keeps drawing the label itself from what is typed, so the letters on screen are
    /// the letters that get exported — style, outline and plate included.
    private func startTextEditing(_ annotation: TextAnnotation, isNew: Bool = false) {
        finishTextEditing()
        let length = annotation.text.count
        let isBox = annotation.fixedWidth != nil
        Self.logger.notice("text edit begins: \(isNew ? "new" : "existing", privacy: .public), \(length) chars, box \(isBox, privacy: .public)")

        editingText = annotation
        isEditingNewText = isNew
        textBeforeEditing = annotation.text
        if document.selection != nil {
            document.selection = nil
        }

        let editor = NSTextView(frame: .zero)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.font = annotation.font
        editor.textColor = .clear
        editor.insertionPointColor = annotation.style.textStyle == .plate
            ? annotation.textColor
            : annotation.style.color
        editor.selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.45),
        ]
        editor.isVerticallyResizable = true
        if let width = annotation.fixedWidth {
            editor.isHorizontallyResizable = false
            editor.textContainer?.widthTracksTextView = true
            editor.textContainer?.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        } else {
            editor.isHorizontallyResizable = true
            editor.textContainer?.widthTracksTextView = false
            editor.textContainer?.containerSize = CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: .greatestFiniteMagnitude
            )
        }
        editor.string = annotation.text
        place(editor, over: annotation)
        editor.setSelectedRange(NSRange(location: (annotation.text as NSString).length, length: 0))
        editor.delegate = self

        addSubview(editor)
        window?.makeFirstResponder(editor)
        textEditor = editor
        textUndoManager.removeAllActions()
        needsDisplay = true
    }

    /// The editor is a real subview, so its frame is in view coordinates: the label's frame has to
    /// come back from frame coordinates through the crop origin. A few points wider than the text,
    /// so the caret after the last letter has somewhere to stand.
    private func textEditorFrame(for annotation: TextAnnotation) -> CGRect {
        let frame = annotation.textFrame
        return CGRect(
            x: frame.minX - document.cropRect.minX,
            y: frame.minY - document.cropRect.minY,
            width: annotation.fixedWidth ?? frame.width + 4,
            height: frame.height
        )
    }

    /// Lays the field over the label. A label on a shot that was turned since is turned too: the
    /// field gets the level frame centred where the turned label is, and the same turn about its
    /// centre, so the caret walks along the letters on screen.
    func place(_ editor: NSTextView, over annotation: TextAnnotation) {
        let level = textEditorFrame(for: annotation)
        editor.frameCenterRotation = 0
        guard annotation.angle != 0 else {
            editor.frame = level
            return
        }

        let center = CGPoint(x: level.midX, y: level.midY).applying(
            CGAffineTransform(translationX: level.minX, y: level.minY)
                .rotated(by: annotation.angle)
                .translatedBy(x: -level.minX, y: -level.minY)
        )
        editor.frame = CGRect(
            x: center.x - level.width / 2,
            y: center.y - level.height / 2,
            width: level.width,
            height: level.height
        )
        // AppKit turns a positive angle counterclockwise; in this flipped view that is clockwise
        // on screen already. `AnnotationCanvasViewTests` pins which way it goes.
        editor.frameCenterRotation = annotation.angle * 180 / .pi
    }

    /// The user finished typing — Esc, ⌘↩ or a click elsewhere: the label comes out selected, in V,
    /// like a line or a rectangle does. Only these three: `finishTextEditing()` also runs when a
    /// tool is picked in the toolbar, and switching to V there would override that pick.
    func finishTypingAndSelect() {
        guard let label = editingText else { return }
        finishTextEditing()

        guard
            tool.selectsWhatItDraws || tool == .select,
            document.annotations.contains(where: { $0 === label })
        else { return }
        tool = .select
        document.selection = label
    }

    /// Finishes the input. A new label goes into the document if it has words; an edited one
    /// records its change as one step of undo; one that was emptied is removed.
    func finishTextEditing() {
        guard let textEditor, let editingText else { return }

        let typed = textEditor.string
        textEditor.removeFromSuperview()
        self.textEditor = nil
        self.editingText = nil
        textUndoManager.removeAllActions()

        let isMeaningful = !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let outcome = switch (isEditingNewText, isMeaningful) {
        case (true, true): "added"
        case (true, false): "discarded"
        case (false, true): typed == textBeforeEditing ? "unchanged" : "changed"
        case (false, false): "removed"
        }
        let typedLength = typed.count
        let previousLength = isEditingNewText ? 0 : textBeforeEditing.count
        Self.logger.notice("text edit ends: \(outcome, privacy: .public), \(typedLength) chars, was \(previousLength)")
        if isEditingNewText {
            editingText.text = typed
            if isMeaningful {
                document.add(editingText)
            }
        } else {
            // Live typing already wrote into the model; put the old words back first, so undo
            // records the change from them.
            editingText.text = textBeforeEditing
            if isMeaningful {
                document.setText(typed, for: editingText)
            } else {
                document.remove(editingText)
            }
        }
        isEditingNewText = false

        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    var isEditingText: Bool {
        textEditor != nil
    }

    /// Not private so a test can type without a keyboard.
    func typeIntoTextEditor(_ string: String) {
        textEditor?.string = string
        textEditor.map { textDidChange(Notification(name: NSText.didChangeNotification, object: $0)) }
    }

    // MARK: - Keyboard

    /// ⌘D on a Russian keyboard — see `KeyboardLayout.performMenuEquivalent`.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        KeyboardLayout.performMenuEquivalent(event) || super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard !isEditingText else {
            super.keyDown(with: event)
            return
        }

        // The Latin letter on the key, not the letter the layout printed: on ЙЦУКЕН `V` prints `м`
        // and `B` prints `и`, and reading the character meant no tool key worked there at all.
        let characters = KeyboardLayout.latinCharacter(for: event) ?? ""
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // ⇧[ and ⇧] step a label's weight. Matched by the key itself: with Shift the US layout
        // prints { and }, and other layouts print something else again.
        if modifiers == .shift, isTextContext,
           [kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket].contains(Int(event.keyCode))
        {
            let step = Int(event.keyCode) == kVK_ANSI_RightBracket ? 1 : -1
            document.updateStyle { $0.textWeight = LabelFont.weight(after: $0.textWeight, by: step) }
            delegate?.canvasDidChangeStyle(self)
            return
        }

        if modifiers.isEmpty {
            if handleToolOrStyleKey(characters) {
                return
            }
        }

        switch Int(event.keyCode) {
        case kVK_Delete, kVK_ForwardDelete:
            document.removeSelection()
            return
        case kVK_Return, kVK_ANSI_KeypadEnter:
            // Return on a selected label opens it for typing, as in Figma and Sketch.
            if let text = document.selection as? TextAnnotation {
                startTextEditing(text)
                return
            }
        default:
            break
        }

        // The key code and modifiers only: the character could be anything typed.
        let keyCode = event.keyCode
        let flags = modifiers.rawValue
        Self.logger.notice("key \(keyCode) (modifiers 0x\(String(flags, radix: 16), privacy: .public)) not an editor key, passed on")
        super.keyDown(with: event)
    }

    /// The keys that differ for text — F, [ ] and ⇧[ ⇧] — go to the label when T is on or a label
    /// is selected.
    private var isTextContext: Bool {
        tool == .text || document.selection is TextAnnotation
    }

    private func handleToolOrStyleKey(_ characters: String) -> Bool {
        if let tool = AnnotationTool.tool(forHotKey: characters) {
            // A again, with the line already on, walks its ends: arrow → double → plain. R again
            // walks the shapes: rectangle → circle → triangle → diamond.
            if tool == .arrow, self.tool == .arrow {
                document.updateStyle { $0.lineEnds = $0.lineEnds.next }
                delegate?.canvasDidChangeStyle(self)
            } else if tool == .rectangle, self.tool == .rectangle {
                document.updateStyle { $0.shapeKind = $0.shapeKind.next }
                delegate?.canvasDidChangeStyle(self)
            } else {
                select(tool: tool)
            }
            return true
        }

        // Digits 1…4 are the palette, 5 is the colour of one's own.
        if let digit = Int(characters) {
            let palette = AnnotationStyle.Palette.self
            if palette.colors.indices.contains(digit - 1) {
                document.pickColor(palette.colors[digit - 1])
                delegate?.canvasDidChangeStyle(self)
                return true
            }
            if digit - 1 == palette.customIndex {
                Self.logger.notice("key \(digit): own colour picker asked for")
                delegate?.canvasDidRequestCustomColor(self)
                return true
            }
        }

        switch characters {
        case "]":
            // A label's size; everything else's width.
            if isTextContext {
                document.updateStyle { $0.textSize = AnnotationStyle.TextSize.next(after: $0.textSize) }
            } else {
                document.updateStyle { $0.lineWidth = AnnotationStyle.LineWidth.next(after: $0.lineWidth) }
            }
            delegate?.canvasDidChangeStyle(self)
            return true
        case "[":
            if isTextContext {
                document.updateStyle { $0.textSize = AnnotationStyle.TextSize.previous(before: $0.textSize) }
            } else {
                document.updateStyle { $0.lineWidth = AnnotationStyle.LineWidth.previous(before: $0.lineWidth) }
            }
            delegate?.canvasDidChangeStyle(self)
            return true
        case "f":
            // For text, F walks the label styles; for shapes, the steps of the fill.
            if isTextContext {
                document.updateStyle(AnnotationStyle.nextTextStyle)
            } else {
                document.updateStyle { $0.fillOpacity = AnnotationStyle.FillOpacity.next(after: $0.fillOpacity) }
            }
            delegate?.canvasDidChangeStyle(self)
            return true
        case "c":
            // Wipes everything without a confirmation — the owner asked for it. ⌘Z brings it
            // back.
            document.removeAll()
            return true
        default:
            return false
        }
    }

    // MARK: - Undo

    /// ⌘Z and ⌘⇧Z are answered here, not by the window. Since the editor's content is an
    /// `NSHostingController`, `NSWindow.undoManager` is one SwiftUI supplies — not the one the
    /// document records into, and `windowWillReturnUndoManager` is no longer asked. The canvas is
    /// first in the responder chain, so it catches the action before the window does. While text is
    /// being typed, the text field's own undo manager takes the typing back instead.
    @objc func undo(_: Any?) {
        guard let manager = activeUndoManager, manager.canUndo else {
            let typing = isEditingText
            Self.logger.notice("undo: nothing to undo\(typing ? " (typing)" : "", privacy: .public)")
            return
        }
        Stats.shared.add(.undos)
        if isEditingText {
            Self.logger.notice("undo (typing)")
        }
        manager.undo()
    }

    @objc func redo(_: Any?) {
        guard activeUndoManager?.canRedo == true else {
            let typing = isEditingText
            Self.logger.notice("redo: nothing to redo\(typing ? " (typing)" : "", privacy: .public)")
            return
        }
        if isEditingText {
            Self.logger.notice("redo (typing)")
        }
        activeUndoManager?.redo()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): activeUndoManager?.canUndo ?? false
        case #selector(redo(_:)): activeUndoManager?.canRedo ?? false
        default: true
        }
    }

    private var activeUndoManager: UndoManager? {
        isEditingText ? textUndoManager : document.undoManager
    }

    /// The typing inside one text field — kept apart from the document, so ⌘Z while typing takes
    /// back letters rather than the last arrow.
    let textUndoManager = UndoManager()

    private static var logger: Logger {
        .pawshot("editor")
    }

    /// Esc cascades: first the text input, then the tool, then the selection — and there it
    /// stops. It never closes the window: the owner lost a shot to it once too often. Closing is
    /// ⌘W, or a tap of ⌘Q, which asks when there is work to lose (`QuitKey`).
    override func cancelOperation(_: Any?) {
        if isEditingText {
            finishTypingAndSelect()
            return
        }
        if tool != .select {
            select(tool: .select)
            return
        }
        if document.selection != nil {
            document.selection = nil
            needsDisplay = true
        } else {
            Self.logger.notice("Esc: nothing left to let go of")
        }
    }
}

// MARK: - Typing

extension AnnotationCanvasView: NSTextViewDelegate {
    /// Every keystroke goes into the label, and the canvas redraws it: the field itself shows only
    /// the caret.
    func textDidChange(_ notification: Notification) {
        guard let editor = notification.object as? NSTextView, let editingText else { return }
        editingText.text = editor.string
        place(editor, over: editingText)
        needsDisplay = true
    }

    /// The typing has an undo of its own, apart from the document's.
    func undoManager(for _: NSTextView) -> UndoManager? {
        textUndoManager
    }

    /// Esc and ⌘↩ finish the label; a plain Return is a new line.
    func textView(_: NSTextView, doCommandBy selector: Selector) -> Bool {
        let commandReturn = selector == #selector(NSResponder.insertNewline(_:))
            && NSApp.currentEvent?.modifierFlags.contains(.command) == true
        guard selector == #selector(NSResponder.cancelOperation(_:))
            || selector == #selector(NSTextView.complete(_:))
            || commandReturn
        else { return false }

        finishTypingAndSelect()
        return true
    }
}
