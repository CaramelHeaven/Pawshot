import AppKit

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
                onChange?()
            }
        }
    }

    var style: AnnotationStyle = .default

    /// Lets the canvas know it's time to redraw.
    var onChange: (() -> Void)?

    /// Told when the crop changed, so the canvas can resize itself and the window can follow.
    var onCropChange: (() -> Void)?

    weak var undoManager: UndoManager?

    private var lastCounterNumber = 0

    init?(frame: CapturedFrame, cropRect: CGRect) {
        guard let image = Self.cutout(of: frame, cropRect: cropRect) else { return nil }

        self.frame = frame
        self.cropRect = cropRect
        self.image = image
        blurSource = BlurSource(image: image, frame: cropRect)
    }

    // MARK: - Crop

    /// Applies a new crop.
    ///
    /// - Parameter undoable: `false` for the intermediate steps of a live resize — a drag produces
    ///   dozens of them, and each one landing in the undo stack would make `⌘Z` take a dozen
    ///   presses to undo a single gesture. The window registers one step per gesture through
    ///   `registerCropUndo(from:)` instead.
    func setCrop(_ rect: CGRect, undoable: Bool = true) {
        guard rect != cropRect, let cutout = Self.cutout(of: frame, cropRect: rect) else { return }

        let previous = cropRect
        cropRect = rect
        image = cutout
        blurSource.update(image: cutout, frame: rect)

        if undoable {
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
        guard previous != cropRect else { return }
        Stats.shared.add(.edgeFits)

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
        else { return }

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
        setHeads(arrow.heads.next, of: arrow)
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
        guard let selection else { return }
        remove(selection)
    }

    /// Wipes everything at once. There is no confirmation by the owner's decision — `⌘Z` is the
    /// safety net, so undo restores the whole list in its previous order.
    func removeAll() {
        guard !annotations.isEmpty else { return }

        let previous = annotations
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
        transform(&style)

        if let selection {
            var changed = selection.style
            transform(&changed)
            apply(style: changed, to: selection)
        } else {
            onChange?()
        }
    }

    func bringToFront(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0 === annotation }) else { return }
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
                action(document)
            }
        }
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
        else { return nil }

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

        guard let turned = context.makeImage() else { return nil }
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
