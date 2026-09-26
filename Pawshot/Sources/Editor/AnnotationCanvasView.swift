import AppKit
import Carbon.HIToolbox

@MainActor
protocol AnnotationCanvasDelegate: AnyObject {
    func canvasDidChangeTool(_ canvas: AnnotationCanvasView)
    func canvasDidChangeStyle(_ canvas: AnnotationCanvasView)
    func canvasDidRequestClose(_ canvas: AnnotationCanvasView)
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
            finishTextEditing()
            window?.invalidateCursorRects(for: self)
            delegate?.canvasDidChangeTool(self)
        }
    }

    /// The object currently being drawn with the mouse.
    private var draftAnnotation: Annotation?
    private var lastDragPoint: CGPoint?
    private var isMovingSelection = false
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
            self?.needsDisplay = true
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

    private func updateCursor(at point: CGPoint) {
        guard !isEditingText else { return }

        let moves = tool == .select || isCommandHeld
        if isMovingSelection {
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
            selection.drawSelectionIndicator()
        }
    }

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
            finishTextEditing()
            return
        }

        let point = imagePoint(from: event)

        // A double click on a label edits it, whatever the tool.
        if event.clickCount == 2, let text = textAnnotation(at: point) {
            draftAnnotation = nil
            startTextEditing(text)
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

        guard let annotation = tool.makeAnnotation(at: point, document: document) else { return }

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
            draftAnnotation.update(to: point)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
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

        // Not selected: the tool stays, and the next stroke starts a new object — even on top
        // of this one.
        if draftAnnotation.isMeaningful {
            document.add(draftAnnotation)
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

        editingText = annotation
        isEditingNewText = isNew
        textBeforeEditing = annotation.text
        if document.selection != nil {
            document.selection = nil
        }

        let editor = NSTextView(frame: textEditorFrame(for: annotation))
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

        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
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

        super.keyDown(with: event)
    }

    private func handleToolOrStyleKey(_ characters: String) -> Bool {
        if let tool = AnnotationTool.tool(forHotKey: characters) {
            select(tool: tool)
            return true
        }

        // Digits 1…6 are the palette.
        if let digit = Int(characters), (1 ... AnnotationStyle.Palette.colors.count).contains(digit) {
            document.updateStyle { style in
                style.color = AnnotationStyle.Palette.color(forKeyIndex: digit - 1, current: style.color)
            }
            delegate?.canvasDidChangeStyle(self)
            return true
        }

        switch characters {
        case "]":
            document.updateStyle { $0.lineWidth = AnnotationStyle.LineWidth.next(after: $0.lineWidth) }
            delegate?.canvasDidChangeStyle(self)
            return true
        case "[":
            document.updateStyle { $0.lineWidth = AnnotationStyle.LineWidth.previous(before: $0.lineWidth) }
            delegate?.canvasDidChangeStyle(self)
            return true
        case "f":
            // For text, F walks the label styles; for shapes it is still fill on/off.
            if tool == .text || document.selection is TextAnnotation {
                document.updateStyle { $0.textStyle = $0.textStyle.next }
            } else {
                document.updateStyle { $0.isFilled.toggle() }
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
        activeUndoManager?.undo()
    }

    @objc func redo(_: Any?) {
        activeUndoManager?.redo()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case Selector(("undo:")): activeUndoManager?.canUndo ?? false
        case Selector(("redo:")): activeUndoManager?.canRedo ?? false
        default: true
        }
    }

    private var activeUndoManager: UndoManager? {
        isEditingText ? textUndoManager : document.undoManager
    }

    /// The typing inside one text field — kept apart from the document, so ⌘Z while typing takes
    /// back letters rather than the last arrow.
    let textUndoManager = UndoManager()

    /// Esc cascades: first the text input, then the tool, then the selection, and only in an
    /// empty state does it close the window. Otherwise a single accidental press would cost all
    /// the work.
    override func cancelOperation(_: Any?) {
        if isEditingText {
            finishTextEditing()
            return
        }
        if tool != .select {
            select(tool: .select)
            return
        }
        if document.selection != nil {
            document.selection = nil
            needsDisplay = true
            return
        }
        delegate?.canvasDidRequestClose(self)
    }
}

// MARK: - Typing

extension AnnotationCanvasView: NSTextViewDelegate {
    /// Every keystroke goes into the label, and the canvas redraws it: the field itself shows only
    /// the caret.
    func textDidChange(_ notification: Notification) {
        guard let editor = notification.object as? NSTextView, let editingText else { return }
        editingText.text = editor.string
        editor.frame = textEditorFrame(for: editingText)
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

        finishTextEditing()
        return true
    }
}
