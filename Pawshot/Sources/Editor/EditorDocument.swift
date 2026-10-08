import AppKit
import os

/// The editor's state: the captured frame, the crop, the list of annotations, the selection and
/// the current style. Every change goes through here so undo lives in one place instead of being
/// smeared across views.
///
/// The whole captured display is kept alive for as long as the editor window is open — that is
/// what makes resizing the shot possible at all: growing the crop only needs pixels that were
/// already captured, and re-capturing the screen would give a different one (Pawshot is active by
/// then, so menus and popovers are already gone).
@MainActor
final class EditorDocument {
    /// The frozen frame of the whole display the shot was taken from. Turned with the shot, so
    /// growing the shot by the window's edge keeps working after a turn.
    private(set) var frame: CapturedFrame

    /// The visible region, in **points of the captured frame** — the coordinate system every
    /// annotation lives in. Changing it doesn't move a single annotation.
    private(set) var cropRect: CGRect

    /// The cropped shot itself, in pixels. Rebuilt whenever the crop changes.
    private(set) var image: CGImage

    /// The shot size in points.
    var imageSize: CGSize {
        cropRect.size
    }

    /// The frame size in points — the hard limit for any crop.
    var frameSize: CGSize {
        frame.displayFrame.size
    }

    let blurSource: BlurSource

    private(set) var annotations: [Annotation] = []
    /// Told on change too: the toolbar shows the selected object's style, and the ends of a
    /// selected line.
    var selection: Annotation? {
        didSet {
            if selection !== oldValue {
                let kind = selection.map(Self.kind) ?? "none"
                Self.logger.notice("selected \(kind, privacy: .public)")
                settlePreview()
                onChange?()
            }
        }
    }

    var style: AnnotationStyle = .default
    private var drawingColors: AnnotationDefaultColors
    private var activeColorGroup: AnnotationColorGroup?
    /// A palette choice made in V with nothing selected belongs to the next drawing tool.
    private var pendingColor: NSColor?

    /// Lets the canvas know it's time to redraw.
    var onChange: (() -> Void)?

    /// Told when the crop changed, so the canvas can resize itself and the window can follow.
    var onCropChange: (() -> Void)?

    weak var undoManager: UndoManager?

    private var lastCounterNumber = 0

    init?(frame: CapturedFrame, cropRect: CGRect, defaultColors: AnnotationDefaultColors = .init()) {
        guard let image = Self.cutout(of: frame, cropRect: cropRect) else {
            let width = frame.image.width
            let height = frame.image.height
            Self.logger.error("document: crop \(Int(cropRect.width))×\(Int(cropRect.height)) at \(Int(cropRect.minX)),\(Int(cropRect.minY)) could not be cut out of the \(width)×\(height) px frame, no editor")
            return nil
        }

        self.frame = frame
        self.cropRect = cropRect
        self.image = image
        blurSource = BlurSource(image: image, frame: cropRect)
        drawingColors = defaultColors
    }

    /// A and R share a colour; D and T each keep theirs. Returning to V leaves the last colour
    /// on the toolbar, while re-entering a drawing tool loads its own colour again.
    func activateColor(for tool: AnnotationTool) {
        activeColorGroup = tool.colorGroup
        guard let group = activeColorGroup else { return }
        if let pendingColor {
            drawingColors[group] = pendingColor
            self.pendingColor = nil
        }
        style.color = drawingColors[group]
        onChange?()
    }

    /// A settings change wins over this window's manual colour for that group, without touching
    /// any annotation already on the shot.
    func defaultColorDidChange(_ color: NSColor, for group: AnnotationColorGroup) {
        drawingColors[group] = color
        pendingColor = nil
        if activeColorGroup == group {
            style.color = color
            onChange?()
        }
    }

    /// The palette and keys 1…5 take this same route. An object selected under V changes alone;
    /// otherwise the colour belongs to the active tool for this editor window.
    func pickColor(_ color: NSColor) {
        settlePreview()
        if let selection {
            var changed = selection.style
            guard changed.color != color else { return }
            changed.color = color
            apply(style: changed, to: selection)
            return
        }

        style.color = color
        if let group = activeColorGroup {
            drawingColors[group] = color
        } else {
            pendingColor = color
        }
        onChange?()
    }

    // MARK: - Crop

    /// Applies a new crop.
    ///
    /// - Parameter undoable: `false` for the intermediate steps of a live resize — a drag produces
    ///   dozens of them, and each one landing in the undo stack would make `⌘Z` take a dozen
    ///   presses to undo a single gesture. The window registers one step per gesture through
    ///   `registerCropUndo(from:)` instead.
    func setCrop(_ rect: CGRect, undoable: Bool = true) {
        guard rect != cropRect else { return }
        guard let cutout = Self.cutout(of: frame, cropRect: rect) else {
            Self.logger.error("crop \(Int(rect.width))×\(Int(rect.height)) at \(Int(rect.minX)),\(Int(rect.minY)) could not be cut out")
            return
        }

        let previous = cropRect
        cropRect = rect
        image = cutout
        blurSource.update(image: cutout, frame: rect)

        if undoable {
            // The steps of a live resize stay quiet: the gesture's one line is `registerCropUndo`.
            Self.logger.notice("crop \(Int(previous.width))×\(Int(previous.height)) → \(Int(rect.width))×\(Int(rect.height)) pt")
            registerUndo { document in
                document.setCrop(previous)
            }
        }
        onCropChange?()
        onChange?()
    }

    /// Puts one undo step for a whole resize gesture. The step is undoable both ways: undoing it
    /// goes through `setCrop`, which registers the way back.
    func registerCropUndo(from previous: CGRect) {
        guard previous != cropRect else {
            Self.logger.notice("resize by the edge: the shot stayed \(Int(previous.width))×\(Int(previous.height)) pt")
            return
        }
        Stats.shared.add(.edgeFits)
        let now = cropRect
        Self.logger.notice("resize by the edge: crop \(Int(previous.width))×\(Int(previous.height)) → \(Int(now.width))×\(Int(now.height)) pt")

        registerUndo { document in
            document.setCrop(previous)
        }
    }

    private static func cutout(of frame: CapturedFrame, cropRect: CGRect) -> CGImage? {
        let pixelSize = CGSize(width: frame.image.width, height: frame.image.height)
        guard
            let pixels = SelectionGeometry.pixelRect(
                of: cropRect,
                scale: frame.scale,
                imagePixelSize: pixelSize
            )
        else { return nil }

        return frame.image.cropping(to: pixels)
    }

    // MARK: - Turning

    /// Turns the shot a quarter, with everything drawn on it — as if it had all been drawn
    /// afterwards. The whole captured frame turns rather than just the crop: every coordinate in
    /// the document stays "a point of the frame", so the canvas, the export and growing the shot
    /// by the window's edge need to know nothing about turns. One step of ⌘Z, which turns back.
    func rotate(clockwise: Bool) {
        let size = frameSize
        let turnedCrop = SelectionGeometry.rotatedQuarter(cropRect, in: size, clockwise: clockwise)
        guard
            let turnedFrame = frame.rotatedQuarter(clockwise: clockwise),
            let cutout = Self.cutout(of: turnedFrame, cropRect: turnedCrop)
        else {
            let width = frame.image.width
            let height = frame.image.height
            Self.logger.error("rotate: turning the \(width)×\(height) px frame failed")
            return
        }

        frame = turnedFrame
        cropRect = turnedCrop
        image = cutout
        for annotation in annotations {
            annotation.rotate(clockwise: clockwise, in: size)
        }
        blurSource.update(image: cutout, frame: turnedCrop)

        registerUndo { document in
            document.rotate(clockwise: !clockwise)
        }
        onCropChange?()
        onChange?()
    }

    /// ⌘L / ⌘R with something selected: only that object turns a quarter, about its own centre.
    /// One step of ⌘Z.
    func rotateSelection(clockwise: Bool) {
        guard let selection else { return }
        rotateAnnotation(selection, clockwise: clockwise)
    }

    private func rotateAnnotation(_ annotation: Annotation, clockwise: Bool) {
        annotation.rotateAroundItsCentre(clockwise: clockwise)
        registerUndo { document in
            document.rotateAnnotation(annotation, clockwise: !clockwise)
        }
        onChange?()
    }

    /// The end of a corner drag: the label is already at `geometry` from the live drag, and this
    /// records the whole gesture as one step of ⌘Z. New labels take the size too.
    func finishResizing(_ label: TextAnnotation, from previous: TextAnnotation.Geometry) {
        if label.geometry.textSize != previous.textSize {
            style.textSize = label.geometry.textSize
        }
        finishReshaping(label, from: previous)
    }

    /// The end of any handle drag: the object is already in its new shape from the live drag,
    /// and this records the whole gesture as one step of ⌘Z.
    func finishReshaping<Object: Reshapable>(_ object: Object, from previous: Object.Shape) {
        guard object.shape != previous else { return }
        Self.logger.notice("reshaped \(Self.kind(object), privacy: .public)")
        registerUndo { document in
            document.setShape(previous, of: object)
        }
        onChange?()
    }

    private func setShape<Object: Reshapable>(_ shape: Object.Shape, of object: Object) {
        let previous = object.shape
        object.shape = shape
        registerUndo { document in
            document.setShape(previous, of: object)
        }
        onChange?()
    }

    /// The button beside a selected line: its heads go one stop further — at the end, at the
    /// start, at both. Only this line changes, not the style new lines are drawn with.
    func turnHeads(of arrow: ArrowAnnotation) {
        let next = arrow.heads.next
        let name = next.lineEnds == .both ? "both" : next.pointsBack ? "start" : "end"
        Self.logger.notice("line heads → \(name, privacy: .public)")
        setHeads(next, of: arrow)
    }

    private func setHeads(_ heads: ArrowAnnotation.Heads, of arrow: ArrowAnnotation) {
        let previous = arrow.heads
        arrow.heads = heads
        registerUndo { document in
            document.setHeads(previous, of: arrow)
        }
        onChange?()
    }

    /// The family is shared by every label, so only their measured sizes go stale. Not a step of
    /// ⌘Z: it is a setting, not an edit.
    func labelFontDidChange() {
        for case let label as TextAnnotation in annotations {
            label.invalidateLayout()
        }
        onChange?()
    }

    // MARK: - Changes

    func add(_ annotation: Annotation) {
        annotations.append(annotation)
        let count = annotations.count
        Self.logger.notice("added \(Self.kind(annotation), privacy: .public), \(count) on the shot")
        Stats.shared.noteDrawn(annotation)
        registerUndo { document in
            document.remove(annotation)
        }
        onChange?()
    }

    func remove(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0 === annotation }) else { return }
        annotations.remove(at: index)

        if selection === annotation {
            selection = nil
        }

        registerUndo { document in
            document.insert(annotation, at: index)
        }
        onChange?()
    }

    func removeSelection() {
        guard let selection else {
            Self.logger.notice("delete: nothing selected")
            return
        }
        Self.logger.notice("deleted \(Self.kind(selection), privacy: .public)")
        remove(selection)
    }

    /// Wipes everything at once. There is no confirmation by the owner's decision — `⌘Z` is the
    /// safety net, so undo restores the whole list in its previous order.
    func removeAll() {
        guard !annotations.isEmpty else {
            Self.logger.notice("clear all: nothing to clear")
            return
        }

        let previous = annotations
        Self.logger.notice("cleared \(previous.count) objects")
        annotations.removeAll()
        selection = nil

        registerUndo { document in
            document.restore(previous)
        }
        onChange?()
    }

    private func restore(_ restored: [Annotation]) {
        annotations = restored
        registerUndo { document in
            document.removeAll()
        }
        onChange?()
    }

    func move(_ annotation: Annotation, by delta: CGVector) {
        annotation.move(by: delta)
        registerUndo { document in
            document.move(annotation, by: CGVector(dx: -delta.dx, dy: -delta.dy))
        }
        onChange?()
    }

    /// A finished edit of an existing label: one step of undo puts the old words back.
    func setText(_ text: String, for annotation: TextAnnotation) {
        let previous = annotation.text
        guard previous != text else { return }

        Self.logger.notice("label text \(previous.count) → \(text.count) chars")
        annotation.text = text
        registerUndo { document in
            document.setText(previous, for: annotation)
        }
        onChange?()
    }

    func apply(style: AnnotationStyle, to annotation: Annotation) {
        let previous = annotation.style
        annotation.style = style
        registerUndo { document in
            document.apply(style: previous, to: annotation)
        }
        onChange?()
    }

    /// Changes the current style and, when something is selected, makes the same change to the
    /// selection — that's how every editor behaves: press "2" and the selected arrow turns green.
    ///
    /// The same change, not the whole current style: turning a blue double arrow into a single one
    /// must not also paint it in whatever colour was picked since.
    func updateStyle(_ transform: (inout AnnotationStyle) -> Void) {
        // A slider let go: back to where it started, silently, so the change below is the one
        // step of undo from there.
        if let base = previewBase {
            previewBase = nil
            style = base.style
            base.selection?.style = base.selectionStyle ?? base.style
        }
        let before = style
        transform(&style)

        if let selection {
            let previous = selection.style
            var changed = previous
            transform(&changed)
            Self.logStyleChange(from: previous, to: changed, on: Self.kind(selection))
            apply(style: changed, to: selection)
        } else {
            Self.logStyleChange(from: before, to: style, on: "new objects")
            onChange?()
        }
    }

    /// What a slider shows while it moves: the same change as `updateStyle`, with no step of undo
    /// per tick. Every tick starts from the style before the drag, and `updateStyle` on letting go
    /// records the whole drag as one step.
    func previewStyle(_ transform: (inout AnnotationStyle) -> Void) {
        let base = previewBase ?? PreviewBase(style: style, selection: selection, selectionStyle: selection?.style)
        previewBase = base
        var previewed = base.style
        transform(&previewed)
        style = previewed
        if let selection = base.selection, var changed = base.selectionStyle {
            transform(&changed)
            selection.style = changed
        }
        onChange?()
    }

    /// A slider drag that never let go — the selection changed under it, the slider went away —
    /// keeps what it showed as one step of undo. Left standing, its base used to be restored by
    /// the next unrelated `updateStyle`, silently, onto an object no longer selected.
    private func settlePreview() {
        guard let base = previewBase else { return }
        previewBase = nil
        guard let annotation = base.selection, let previous = base.selectionStyle, annotation.style != previous else { return }
        Self.logger.notice("fill slider settled on selection change")
        registerUndo { document in
            document.apply(style: previous, to: annotation)
        }
    }

    private struct PreviewBase {
        let style: AnnotationStyle
        let selection: Annotation?
        let selectionStyle: AnnotationStyle?
    }

    private var previewBase: PreviewBase?

    func bringToFront(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0 === annotation }) else {
            Self.logger.error("bring to front: \(Self.kind(annotation), privacy: .public) is not on the shot")
            return
        }
        Self.logger.notice("brought \(Self.kind(annotation), privacy: .public) to front")
        annotations.append(annotations.remove(at: index))
        onChange?()
    }

    // MARK: - Queries

    /// Search from the top down: the object drawn last sits above and has to be hit first.
    func annotation(at point: CGPoint, tolerance: CGFloat) -> Annotation? {
        annotations.reversed().first { $0.hitTest(point, tolerance: tolerance) }
    }

    func nextCounterNumber() -> Int {
        lastCounterNumber += 1
        return lastCounterNumber
    }

    // MARK: - Undo

    private func insert(_ annotation: Annotation, at index: Int) {
        annotations.insert(annotation, at: min(index, annotations.count))
        registerUndo { document in
            document.remove(annotation)
        }
        onChange?()
    }

    private func registerUndo(_ action: @escaping @MainActor (EditorDocument) -> Void) {
        undoManager?.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated {
                let redoing = document.undoManager?.isRedoing ?? false
                Self.logger.notice("\(redoing ? "redo" : "undo", privacy: .public)")
                action(document)
            }
        }
    }

    // MARK: - Log

    private static var logger: Logger {
        .pawshot("editor")
    }

    private static func kind(_ annotation: Annotation) -> String {
        AnnotationTool.drawing(annotation).rawValue
    }

    /// Only the fields that changed, before → after.
    private static func logStyleChange(from old: AnnotationStyle, to new: AnnotationStyle, on target: String) {
        var changes: [String] = []
        if old.color != new.color {
            changes.append("colour \(ColorHex.string(old.color)) → \(ColorHex.string(new.color))")
        }
        if old.lineWidth != new.lineWidth {
            changes.append("width \(old.lineWidth) → \(new.lineWidth)")
        }
        if old.fillOpacity != new.fillOpacity {
            changes.append("fill \(Int((old.fillOpacity * 100).rounded()))% → \(Int((new.fillOpacity * 100).rounded()))%")
        }
        if old.textStyle != new.textStyle {
            changes.append("text \(old.textStyle) → \(new.textStyle)")
        }
        if old.textSize != new.textSize {
            changes.append("size \(old.textSize) → \(new.textSize)")
        }
        if old.textWeight != new.textWeight {
            changes.append("weight \(old.textWeight.rawValue) → \(new.textWeight.rawValue)")
        }
        if old.lineEnds != new.lineEnds {
            changes.append("ends \(old.lineEnds) → \(new.lineEnds)")
        }
        if old.shapeKind != new.shapeKind {
            changes.append("shape \(old.shapeKind) → \(new.shapeKind)")
        }
        let line = changes.isEmpty ? "no change" : changes.joined(separator: ", ")
        logger.notice("style: \(line, privacy: .public) on \(target, privacy: .public)")
    }
}

extension CapturedFrame {
    /// The same display turned a quarter: the pixels redrawn into a bitmap of swapped size, and the
    /// bounds with their width and height swapped. The origin is kept — it only says which screen
    /// the shot came from.
    func rotatedQuarter(clockwise: Bool) -> CapturedFrame? {
        let width = image.height
        let height = image.width
        guard
            let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
        else {
            Logger.pawshot("editor").error("rotate: no \(width)×\(height) px bitmap context to turn into")
            return nil
        }

        // The context has Y going up. Clockwise on screen is a negative angle there; the
        // translation brings the turned picture back into the bitmap.
        if clockwise {
            context.translateBy(x: 0, y: CGFloat(height))
            context.rotate(by: -.pi / 2)
        } else {
            context.translateBy(x: CGFloat(width), y: 0)
            context.rotate(by: .pi / 2)
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        guard let turned = context.makeImage() else {
            Logger.pawshot("editor").error("rotate: the turned \(width)×\(height) px bitmap gave no image")
            return nil
        }
        return CapturedFrame(
            image: turned,
            displayFrame: CGRect(
                origin: displayFrame.origin,
                size: CGSize(width: displayFrame.height, height: displayFrame.width)
            ),
            scale: scale
        )
    }
}
