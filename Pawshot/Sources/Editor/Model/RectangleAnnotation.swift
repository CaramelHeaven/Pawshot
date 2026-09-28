import AppKit

@MainActor
final class RectangleAnnotation: Reshapable {
    let id = UUID()
    var style: AnnotationStyle

    private var start: CGPoint
    private var end: CGPoint
    /// Turned about its own centre, in radians, clockwise on screen. The corners in `start` and
    /// `end` are those of the level rectangle.
    private(set) var angle: CGFloat = 0

    /// The level rectangle — before the turn. A normalised one: it can be dragged in any
    /// direction. Computed by the same function as the region selection during a capture.
    var rect: CGRect {
        SelectionGeometry.rect(from: start, to: end)
    }

    init(start: CGPoint, style: AnnotationStyle) {
        self.start = start
        end = start
        self.style = style
    }

    /// The rectangle as it lies on the shot: centre, size, turn.
    var box: SelectionGeometry.RotatedBox {
        SelectionGeometry.RotatedBox(center: CGPoint(x: rect.midX, y: rect.midY), size: rect.size, angle: angle)
    }

    var shape: SelectionGeometry.RotatedBox {
        get { box }
        set {
            start = CGPoint(x: newValue.center.x - newValue.size.width / 2, y: newValue.center.y - newValue.size.height / 2)
            end = CGPoint(x: newValue.center.x + newValue.size.width / 2, y: newValue.center.y + newValue.size.height / 2)
            angle = newValue.angle
        }
    }

    var boundingBox: CGRect {
        box.grown(by: style.lineWidth / 2).bounds
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

    func rotateQuarter(clockwise: Bool, mapping turn: (CGPoint) -> CGPoint) {
        guard angle != 0 else {
            start = turn(start)
            end = turn(end)
            return
        }
        // A turned rectangle keeps its sides and gains a quarter: its centre goes where the turn
        // takes it.
        var turned = box
        turned.center = turn(turned.center)
        turned.angle = SelectionGeometry.normalizedAngle(angle + (clockwise ? .pi / 2 : -.pi / 2))
        shape = turned
    }

    func draw() {
        let rect = rect
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if angle != 0 {
            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX, yBy: rect.midY)
            transform.rotate(byRadians: angle)
            transform.translateX(by: -rect.midX, yBy: -rect.midY)
            transform.concat()
        }

        // Softly rounded corners, scaled with the stroke so a thick frame doesn't look pinched.
        let radius = min(max(3, style.lineWidth), min(rect.width, rect.height) / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.lineWidth = style.lineWidth

        if style.isFilled {
            style.color.withAlphaComponent(style.fillOpacity).setFill()
            path.fill()
        }

        style.color.setStroke()
        path.stroke()
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        // Tested in the rectangle's own level system, so a turned one is hit where it is drawn.
        let local = box.toLocal(point)
        let level = box.local
        if style.isFilled, level.contains(local) {
            return true
        }

        // An unfilled rectangle is hit by its border: between the outer and the inner edge.
        let slack = tolerance + style.lineWidth / 2
        let outer = level.insetBy(dx: -slack, dy: -slack)
        let inner = level.insetBy(dx: slack, dy: slack)

        return outer.contains(local) && !inner.contains(local)
    }
}
