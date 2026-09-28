import AppKit

@MainActor
final class ArrowAnnotation: Reshapable {
    let id = UUID()
    var style: AnnotationStyle

    private(set) var start: CGPoint
    private(set) var end: CGPoint
    /// Where the line is bent to, dragged by the diamond in its middle; `nil` — straight.
    private(set) var control: CGPoint?
    /// A single head at `start` instead of `end` — the second stop of the heads button. The line
    /// keeps the direction it was drawn in, so the toolbar's three looks mean what they always did.
    var pointsBack = false

    init(start: CGPoint, style: AnnotationStyle) {
        self.start = start
        end = start
        self.style = style
    }

    /// What the handles change: the ends and the bend.
    struct Shape: Equatable {
        var start: CGPoint
        var end: CGPoint
        var control: CGPoint?
    }

    var shape: Shape {
        get { Shape(start: start, end: end, control: control) }
        set {
            start = newValue.start
            end = newValue.end
            control = newValue.control
        }
    }

    var hasHeadAtEnd: Bool {
        style.lineEnds == .both || (style.lineEnds == .end && !pointsBack)
    }

    var hasHeadAtStart: Bool {
        style.lineEnds == .both || (style.lineEnds == .end && pointsBack)
    }

    /// Where the diamond is: halfway along the line, bent or not.
    var middle: CGPoint {
        guard let control else { return CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2) }
        return SelectionGeometry.curvePoint(start: start, control: control, end: end, at: 0.5)
    }

    private var samples: [CGPoint] {
        SelectionGeometry.curveSamples(start: start, control: control, end: end)
    }

    var boundingBox: CGRect {
        let points = samples
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let rect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
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
        control = control.map { CGPoint(x: $0.x + delta.dx, y: $0.y + delta.dy) }
    }

    func rotateQuarter(clockwise _: Bool, mapping turn: (CGPoint) -> CGPoint) {
        start = turn(start)
        end = turn(end)
        control = control.map(turn)
    }

    /// One object for a plain line, an arrow and a double arrow — only the heads differ, so a
    /// drawn line can become any of the three later, as one step of undo.
    func draw() {
        style.color.setStroke()
        style.color.setFill()

        // A head points along the line where it arrives: from the bend for a bent line.
        let startAngle = atan2(start.y - (control ?? end).y, start.x - (control ?? end).x)
        let endAngle = atan2(end.y - (control ?? start).y, end.x - (control ?? start).x)

        // The shaft stops short of a tip: otherwise the line sticks out from under the head.
        let pullBack = headLength * 0.75
        let shaftStart = hasHeadAtStart
            ? CGPoint(x: start.x - cos(startAngle) * pullBack, y: start.y - sin(startAngle) * pullBack)
            : start
        let shaftEnd = hasHeadAtEnd
            ? CGPoint(x: end.x - cos(endAngle) * pullBack, y: end.y - sin(endAngle) * pullBack)
            : end

        let shaft = NSBezierPath()
        shaft.move(to: shaftStart)
        if let control {
            // Quadratic → cubic: AppKit only draws the latter.
            shaft.curve(
                to: shaftEnd,
                controlPoint1: CGPoint(x: shaftStart.x + (control.x - shaftStart.x) * 2 / 3, y: shaftStart.y + (control.y - shaftStart.y) * 2 / 3),
                controlPoint2: CGPoint(x: shaftEnd.x + (control.x - shaftEnd.x) * 2 / 3, y: shaftEnd.y + (control.y - shaftEnd.y) * 2 / 3)
            )
        } else {
            shaft.line(to: shaftEnd)
        }
        shaft.lineWidth = style.lineWidth
        shaft.lineCapStyle = .round
        shaft.stroke()

        if hasHeadAtEnd {
            drawHead(at: end, pointing: endAngle)
        }
        if hasHeadAtStart {
            drawHead(at: start, pointing: startAngle)
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
        let points = samples
        return zip(points, points.dropFirst()).contains { a, b in
            GeometryMath.distance(from: point, toSegment: a, b) <= tolerance + style.lineWidth
        }
    }

    // MARK: - The heads button

    /// Where the heads go, and in which order the button walks them: at the end → at the start →
    /// at both → at the end. A plain line gets a head at the end — the button is about heads.
    struct Heads: Equatable {
        var lineEnds: AnnotationStyle.LineEnds
        var pointsBack: Bool

        var next: Heads {
            switch (lineEnds, pointsBack) {
            case (.end, false): Heads(lineEnds: .end, pointsBack: true)
            case (.end, true): Heads(lineEnds: .both, pointsBack: false)
            default: Heads(lineEnds: .end, pointsBack: false)
            }
        }

        /// The picture on the button, drawn along the line from start to end.
        var glyph: String {
            switch (lineEnds, pointsBack) {
            case (.both, _): "↔"
            case (.end, true): "←"
            case (.end, false): "→"
            case (.none, _): "—"
            }
        }
    }

    var heads: Heads {
        get { Heads(lineEnds: style.lineEnds, pointsBack: pointsBack) }
        set {
            style.lineEnds = newValue.lineEnds
            pointsBack = newValue.pointsBack
        }
    }
}
