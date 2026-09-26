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
    /// The frozen frame of the whole display the shot was taken from.
    let frame: CapturedFrame

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
    var selection: Annotation?
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

    // MARK: - Changes

    func add(_ annotation: Annotation) {
        annotations.append(annotation)
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

    /// Changes the current style and, when something is selected, applies it to the selection —
    /// that's how every editor behaves: press "2" and the selected arrow turns green.
    func updateStyle(_ transform: (inout AnnotationStyle) -> Void) {
        transform(&style)

        if let selection {
            apply(style: style, to: selection)
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
