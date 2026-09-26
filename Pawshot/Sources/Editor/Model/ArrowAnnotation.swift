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

    func rotateQuarter(clockwise _: Bool, mapping turn: (CGPoint) -> CGPoint) {
        start = turn(start)
        end = turn(end)
    }

    /// One object for a plain line, an arrow and a double arrow — only the heads differ, so a
    /// drawn line can become any of the three later, as one step of undo.
    func draw() {
        style.color.setStroke()
        style.color.setFill()

        let angle = atan2(end.y - start.y, end.x - start.x)
        let hasEndHead = style.lineEnds != .none
        let hasStartHead = style.lineEnds == .both

        // The shaft stops short of a tip: otherwise the line sticks out from under the head.
        let pullBack = headLength * 0.75
        let shaftStart = hasStartHead
            ? CGPoint(x: start.x + cos(angle) * pullBack, y: start.y + sin(angle) * pullBack)
            : start
        let shaftEnd = hasEndHead
            ? CGPoint(x: end.x - cos(angle) * pullBack, y: end.y - sin(angle) * pullBack)
            : end

        let shaft = NSBezierPath()
        shaft.move(to: shaftStart)
        shaft.line(to: shaftEnd)
        shaft.lineWidth = style.lineWidth
        shaft.lineCapStyle = .round
        shaft.stroke()

        if hasEndHead {
            drawHead(at: end, pointing: angle)
        }
        if hasStartHead {
            drawHead(at: start, pointing: angle + .pi)
        }
    }

    private func drawHead(at tip: CGPoint, pointing angle: CGFloat) {
        let spread = CGFloat.pi / 7
        let head = NSBezierPath()
        head.move(to: tip)
        head.line(to: CGPoint(
            x: tip.x - cos(angle - spread) * headLength,
            y: tip.y - sin(angle - spread) * headLength
        ))
        head.line(to: CGPoint(
            x: tip.x - cos(angle + spread) * headLength,
            y: tip.y - sin(angle + spread) * headLength
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
