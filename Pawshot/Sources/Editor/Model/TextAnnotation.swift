import AppKit

/// A text label. Two shapes, the way Figma and tldraw make them: a click gives text as wide as
/// what is typed (lines break only on Return), a drag gives a box of that width that wraps.
///
/// The canvas draws it from the model even while it is being typed — the text field on top only
/// carries the caret and the selection — so what is typed is exactly what gets exported.
@MainActor
final class TextAnnotation: Reshapable {
    let id = UUID()
    var style: AnnotationStyle {
        didSet { cachedSize = nil }
    }

    var text: String {
        didSet { cachedSize = nil }
    }

    /// `nil` — as wide as the text. A number — the width of the box the text wraps inside. Scales
    /// with the text when a corner is dragged.
    var fixedWidth: CGFloat? {
        didSet { cachedSize = nil }
    }

    /// The top left corner of the text in image coordinates.
    private(set) var origin: CGPoint

    /// How far the label is turned, in radians, clockwise on screen: by the shot's quarter turns
    /// made after it was placed, and by its own turning handle. The label is laid out level at
    /// `origin` and then turned about that corner as a whole, so it stays where it was drawn.
    private(set) var angle: CGFloat = 0

    /// Level layout → where it is on the shot.
    var turn: CGAffineTransform {
        CGAffineTransform(translationX: origin.x, y: origin.y)
            .rotated(by: angle)
            .translatedBy(x: -origin.x, y: -origin.y)
    }

    private var cachedSize: CGSize?

    init(origin: CGPoint, style: AnnotationStyle, text: String = "", fixedWidth: CGFloat? = nil) {
        self.origin = origin
        self.style = style
        self.text = text
        self.fixedWidth = fixedWidth
    }

    var fontSize: CGFloat {
        style.textSize
    }

    var font: NSFont {
        LabelFont.font(size: fontSize, weight: style.textWeight)
    }

    /// What a handle drag changes, taken and put back as one for undo.
    struct Geometry: Equatable {
        var textSize: CGFloat
        var fixedWidth: CGFloat?
        var origin: CGPoint
        var angle: CGFloat = 0
    }

    var geometry: Geometry {
        get { Geometry(textSize: style.textSize, fixedWidth: fixedWidth, origin: origin, angle: angle) }
        set {
            style.textSize = newValue.textSize
            fixedWidth = newValue.fixedWidth
            origin = newValue.origin
            angle = newValue.angle
        }
    }

    var shape: Geometry {
        get { geometry }
        set { geometry = newValue }
    }

    /// A new size from a corner drag. A wrapping box widens with its letters, so the lines break
    /// where they did; and the label moves so the `pinned` corner of its frame stays put — the one
    /// opposite the handle. Works for a turned label too: the corner is the turned frame's.
    func resize(from start: Geometry, to size: CGFloat, pinning pinned: SelectionGeometry.Corner) {
        geometry = start
        let before = box.corner(pinned)
        style.textSize = size
        fixedWidth = start.fixedWidth.map { $0 * size / start.textSize }
        let after = box.corner(pinned)
        origin.x += before.x - after.x
        origin.y += before.y - after.y
    }

    /// A side dragged: the label becomes a box `width` wide that the text wraps inside, and the
    /// other side stays put. `rightSide` — the right side was dragged, the left one is pinned.
    func setWidth(from start: Geometry, to width: CGFloat, rightSide: Bool) {
        geometry = start
        let side: CGFloat = rightSide ? -1 : 1
        let before = box.toWorld(CGPoint(x: side * box.size.width / 2, y: 0))
        fixedWidth = width
        let after = box.toWorld(CGPoint(x: side * box.size.width / 2, y: 0))
        origin.x += before.x - after.x
        origin.y += before.y - after.y
    }

    /// Turned by its handle to `angle`, about the middle of the label, which stays put.
    func rotate(from start: Geometry, to angle: CGFloat) {
        geometry = start
        let before = box.center
        self.angle = angle
        let after = box.center
        origin.x += before.x - after.x
        origin.y += before.y - after.y
    }

    /// The label's frame as it lies on the shot — what its handles sit on.
    var box: SelectionGeometry.RotatedBox {
        let level = levelBounds
        return SelectionGeometry.RotatedBox(
            center: CGPoint(x: level.midX, y: level.midY).applying(turn),
            size: level.size,
            angle: angle
        )
    }

    /// The family changed in Settings: the measured size no longer holds.
    func invalidateLayout() {
        cachedSize = nil
    }

    /// The colour of the letters: the style's colour, or black/white on a plate of that colour
    /// that is solid enough to be read against rather than through.
    var textColor: NSColor {
        style.textStyle == .plate && plateOpacity >= 0.5
            ? AnnotationStyle.contrastingTextColor(on: style.color)
            : style.color
    }

    /// The plate takes the fill's opacity. Zero would be an invisible plate, which is never what
    /// was meant: F sets it to solid on the way in, and this covers any other way of getting there.
    var plateOpacity: CGFloat {
        style.fillOpacity > 0 ? style.fillOpacity : 1
    }

    var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: textColor]
    }

    /// Where the letters are, in image coordinates. The text field that edits them is laid over
    /// exactly this rectangle.
    var textFrame: CGRect {
        CGRect(origin: origin, size: measuredSize)
    }

    private var plateRect: CGRect {
        textFrame.insetBy(dx: -fontSize * 0.35, dy: -fontSize * 0.12)
    }

    private var outlineWidth: CGFloat {
        fontSize * 0.08
    }

    /// Everything the label covers, before the turn.
    private var levelBounds: CGRect {
        switch style.textStyle {
        case .plain: textFrame.insetBy(dx: -2, dy: -2)
        case .outline: textFrame.insetBy(dx: -outlineWidth - 2, dy: -outlineWidth - 2)
        case .plate: plateRect.insetBy(dx: -2, dy: -2)
        }
    }

    var boundingBox: CGRect {
        angle == 0 ? levelBounds : box.bounds
    }

    var isMeaningful: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Text is not dragged with the mouse — it is typed.
    func update(to _: CGPoint) {}

    func move(by delta: CGVector) {
        origin.x += delta.dx
        origin.y += delta.dy
    }

    func rotateQuarter(clockwise: Bool, mapping turn: (CGPoint) -> CGPoint) {
        origin = turn(origin)
        angle = SelectionGeometry.normalizedAngle(angle + (clockwise ? .pi / 2 : -.pi / 2))
    }

    func draw() {
        guard !text.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if angle != 0 {
            let transform = NSAffineTransform()
            transform.translateX(by: origin.x, yBy: origin.y)
            transform.rotate(byRadians: angle)
            transform.translateX(by: -origin.x, yBy: -origin.y)
            transform.concat()
        }

        let string = text as NSString
        let frame = textFrame

        switch style.textStyle {
        case .plain:
            // A soft shadow under plain letters: red text on a dark screenshot otherwise sinks.
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = CGSize(width: 0, height: -1)
            shadow.set()
            string.draw(with: frame, options: Self.drawingOptions, attributes: attributes)
            NSGraphicsContext.restoreGraphicsState()

        case .outline:
            // The stroke first, the fill over it: only the outer half of the stroke shows, and the
            // letters keep their full weight.
            var stroke = attributes
            stroke[.strokeColor] = AnnotationStyle.contrastingTextColor(on: style.color)
            stroke[.strokeWidth] = outlineWidth * 2 / fontSize * 100
            string.draw(with: frame, options: Self.drawingOptions, attributes: stroke)
            string.draw(with: frame, options: Self.drawingOptions, attributes: attributes)

        case .plate:
            let plate = plateRect
            let radius = min(plate.height / 2, fontSize * 0.45)
            style.color.withAlphaComponent(plateOpacity).setFill()
            NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius).fill()
            string.draw(with: frame, options: Self.drawingOptions, attributes: attributes)
        }
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        box.local.insetBy(dx: -tolerance, dy: -tolerance).contains(box.toLocal(point))
    }

    /// The same layout rules the text field uses, so the caret lands on the letters drawn here.
    private static let drawingOptions: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    private var measuredSize: CGSize {
        if let cachedSize {
            return cachedSize
        }

        // Empty text still has to take up space, otherwise the caret has nowhere to stand.
        let string = (text.isEmpty ? " " : text) as NSString
        let bounds = string.boundingRect(
            with: CGSize(width: fixedWidth ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
            options: Self.drawingOptions,
            attributes: attributes
        )
        // A trailing newline adds a line the measurement doesn't count; the caret needs it.
        let extraLine = text.hasSuffix("\n") ? font.ascender - font.descender + font.leading : 0
        let measured = CGSize(
            width: fixedWidth ?? ceil(bounds.width),
            height: ceil(bounds.height + extraLine)
        )
        cachedSize = measured
        return measured
    }
}
