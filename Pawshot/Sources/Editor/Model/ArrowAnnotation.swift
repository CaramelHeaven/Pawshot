import AppKit

@MainActor
final class ArrowAnnotation: Annotation {
    let id = UUID()
    var style: AnnotationStyle

    private var start: CGPoint
    private var end: CGPoint

    init(start: CGPoint, style: AnnotationStyle) {
        self.start = start
        end = start
        self.style = style
    }

    var boundingBox: CGRect {
        let rect = SelectionGeometry.rect(from: start, to: end)
        let slack = headLength / 2
        return rect.insetBy(dx: -slack, dy: -slack)
    }

    var isMeaningful: Bool {
        hypot(end.x - start.x, end.y - start.y) >= 6
    }

    /// The head grows together with the line width, otherwise on a thick arrow it looks like a
    /// pinhead.
    private var headLength: CGFloat {
        max(12, style.lineWidth * 4.5)
    }

    func update(to point: CGPoint) {
        end = point
    }

    func move(by delta: CGVector) {
        start.x += delta.dx
        start.y += delta.dy
        end.x += delta.dx
        end.y += delta.dy
    }

    func draw() {
        style.color.setStroke()
        style.color.setFill()

        let angle = atan2(end.y - start.y, end.x - start.x)
        // The tail stops short of the tip: otherwise the line sticks out from under the head.
        let shaftEnd = CGPoint(
            x: end.x - cos(angle) * headLength * 0.75,
            y: end.y - sin(angle) * headLength * 0.75
        )

        let shaft = NSBezierPath()
        shaft.move(to: start)
        shaft.line(to: shaftEnd)
        shaft.lineWidth = style.lineWidth
        shaft.lineCapStyle = .round
        shaft.stroke()

        let spread = CGFloat.pi / 7
        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: CGPoint(
            x: end.x - cos(angle - spread) * headLength,
            y: end.y - sin(angle - spread) * headLength
        ))
        head.line(to: CGPoint(
            x: end.x - cos(angle + spread) * headLength,
            y: end.y - sin(angle + spread) * headLength
        ))
        head.close()
        head.fill()
        // Stroking the head as well rounds its three corners: a sharp arrowhead reads as a
        // cursor, a rounded one as a drawn mark.
        head.lineWidth = max(1, style.lineWidth * 0.6)
        head.lineJoinStyle = .round
        head.stroke()
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        GeometryMath.distance(from: point, toSegment: start, end) <= tolerance + style.lineWidth
    }
}
