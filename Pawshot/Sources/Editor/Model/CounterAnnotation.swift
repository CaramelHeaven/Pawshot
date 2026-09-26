import AppKit

/// A circle with a step number. The number is handed out by the document and never changes:
/// deleting neighbouring circles does not renumber the rest — CleanShot X and Shottr behave the
/// same way.
@MainActor
final class CounterAnnotation: Annotation {
    let id = UUID()
    var style: AnnotationStyle
    let number: Int

    private var center: CGPoint

    /// Quarter turns clockwise the shot made after the circle was placed: its digit turns with it.
    private(set) var quarterTurns = 0

    init(center: CGPoint, number: Int, style: AnnotationStyle) {
        self.center = center
        self.number = number
        self.style = style
    }

    private var radius: CGFloat {
        max(11, style.lineWidth * 4)
    }

    var boundingBox: CGRect {
        CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
    }

    /// A circle is placed with a single click, there is nothing to drag.
    var isMeaningful: Bool {
        true
    }

    func update(to point: CGPoint) {
        center = point
    }

    func move(by delta: CGVector) {
        center.x += delta.dx
        center.y += delta.dy
    }

    func rotateQuarter(clockwise: Bool, mapping turn: (CGPoint) -> CGPoint) {
        center = turn(center)
        quarterTurns = (quarterTurns + (clockwise ? 1 : 3)) % 4
    }

    func draw() {
        let circle = NSBezierPath(ovalIn: boundingBox)
        style.color.setFill()
        circle.fill()

        NSColor.white.setStroke()
        circle.lineWidth = 1.5
        circle.stroke()

        let text = "\(number)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.roundedFont(ofSize: radius * 1.1),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        NSGraphicsContext.saveGraphicsState()
        QuarterTurn.transform(quarterTurns, around: center).concat()
        text.draw(
            at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
            withAttributes: attributes
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        hypot(point.x - center.x, point.y - center.y) <= radius + tolerance
    }

    /// SF Rounded: the digits of a step counter read as a friendly badge rather than a code.
    private static func roundedFont(ofSize size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .semibold)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: rounded, size: size) ?? base
    }
}
