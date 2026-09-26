import AppKit

@MainActor
final class RectangleAnnotation: Annotation {
    let id = UUID()
    var style: AnnotationStyle

    private var start: CGPoint
    private var end: CGPoint

    /// A normalised rectangle — it can be dragged in any direction. Computed by the same
    /// function as the region selection during a capture.
    var rect: CGRect {
        SelectionGeometry.rect(from: start, to: end)
    }

    init(start: CGPoint, style: AnnotationStyle) {
        self.start = start
        end = start
        self.style = style
    }

    var boundingBox: CGRect {
        rect.insetBy(dx: -style.lineWidth / 2, dy: -style.lineWidth / 2)
    }

    var isMeaningful: Bool {
        rect.width >= 3 && rect.height >= 3
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
        // Softly rounded corners, scaled with the stroke so a thick frame doesn't look pinched.
        let radius = min(max(3, style.lineWidth), min(rect.width, rect.height) / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.lineWidth = style.lineWidth

        if style.isFilled {
            style.color.withAlphaComponent(0.25).setFill()
            path.fill()
        }

        style.color.setStroke()
        path.stroke()
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        if style.isFilled, rect.contains(point) {
            return true
        }

        // An unfilled rectangle is hit by its border: between the outer and the inner edge.
        let slack = tolerance + style.lineWidth / 2
        let outer = rect.insetBy(dx: -slack, dy: -slack)
        let inner = rect.insetBy(dx: slack, dy: slack)

        return outer.contains(point) && !inner.contains(point)
    }
}
