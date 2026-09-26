import AppKit

/// A pencil stroke: a polyline through the points that arrived during the drag.
@MainActor
final class PathAnnotation: Annotation {
    let id = UUID()
    var style: AnnotationStyle

    private var points: [CGPoint]

    init(start: CGPoint, style: AnnotationStyle) {
        points = [start]
        self.style = style
    }

    var boundingBox: CGRect {
        guard let first = points.first else { return .zero }

        var rect = CGRect(origin: first, size: .zero)
        for point in points.dropFirst() {
            rect = rect.union(CGRect(origin: point, size: .zero))
        }
        let slack = style.lineWidth / 2 + 1
        return rect.insetBy(dx: -slack, dy: -slack)
    }

    var isMeaningful: Bool {
        points.count > 1
    }

    func update(to point: CGPoint) {
        // Mouse points arrive densely; near-duplicates only make the path heavier.
        if let last = points.last, hypot(point.x - last.x, point.y - last.y) < 1 {
            return
        }
        points.append(point)
    }

    func move(by delta: CGVector) {
        for index in points.indices {
            points[index].x += delta.dx
            points[index].y += delta.dy
        }
    }

    func draw() {
        guard let first = points.first else { return }

        let path = NSBezierPath()
        path.move(to: first)
        for point in points.dropFirst() {
            path.line(to: point)
        }
        path.lineWidth = style.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        style.color.setStroke()
        path.stroke()
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        let slack = tolerance + style.lineWidth
        guard points.count > 1 else {
            guard let only = points.first else { return false }
            return hypot(point.x - only.x, point.y - only.y) <= slack
        }

        for index in 0 ..< (points.count - 1) {
            if GeometryMath.distance(from: point, toSegment: points[index], points[index + 1]) <= slack {
                return true
            }
        }
        return false
    }
}
