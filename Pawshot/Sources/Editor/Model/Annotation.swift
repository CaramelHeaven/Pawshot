import AppKit

/// An object drawn on top of the shot. All coordinates are in the captured frame's system, not
/// the window's and not the crop's: the canvas shifts them by the crop origin itself, so an
/// annotation stays put when the shot is resized.
@MainActor
protocol Annotation: AnyObject {
    var id: UUID { get }
    var style: AnnotationStyle { get set }

    /// Bounds for the selection frame. Line width is already accounted for.
    var boundingBox: CGRect { get }

    func draw()

    /// - Parameter tolerance: the tolerance in the frame's coordinates — a thin line is
    ///   impossible to hit dead on with the mouse.
    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool

    func move(by delta: CGVector)

    /// A quarter turn: every point of the object goes through `turn`, and whatever carries
    /// letters turns them too. Who turns it decides about what — the whole shot, or the object's
    /// own centre.
    func rotateQuarter(clockwise: Bool, mapping turn: (CGPoint) -> CGPoint)

    /// Whether the object is dragged by its "other end" right after being created.
    func update(to point: CGPoint)

    /// Finished drawing and released: `false` means the object is too small and gets thrown away.
    var isMeaningful: Bool { get }
}

extension Annotation {
    /// The gap between the object and its dashed selection frame.
    static var selectionInset: CGFloat {
        4
    }

    /// The shot was turned a quarter: the object turns with it, as if it had been drawn before.
    /// `frameSize` is the captured frame's size before the turn.
    func rotate(clockwise: Bool, in frameSize: CGSize) {
        rotateQuarter(clockwise: clockwise) {
            SelectionGeometry.rotatedQuarter($0, in: frameSize, clockwise: clockwise)
        }
    }

    /// ⌘L / ⌘R with the object selected: a quarter turn about the centre of its own frame, so it
    /// stays where it was.
    func rotateAroundItsCentre(clockwise: Bool) {
        let centre = CGPoint(x: boundingBox.midX, y: boundingBox.midY)
        rotateQuarter(clockwise: clockwise) {
            SelectionGeometry.rotatedQuarter($0, around: centre, clockwise: clockwise)
        }
    }

    /// The selection frame. It doubles as the grab area: a selected object is dragged by any point
    /// inside it, not only by the drawn lines. That is why the rectangle is computed in one place —
    /// otherwise the visible frame and what actually catches the mouse would drift apart.
    var selectionFrame: CGRect {
        boundingBox.insetBy(dx: -Self.selectionInset, dy: -Self.selectionInset)
    }

    /// A solid line in the paw colour, 4 pt clear of the object. The old 1 pt dashed line in the
    /// system accent sat right on a red frame and disappeared into it.
    func drawSelectionIndicator() {
        Tokens.pawNSColor.withAlphaComponent(0.95).setStroke()
        let path = NSBezierPath(roundedRect: selectionFrame, xRadius: 3, yRadius: 3)
        path.lineWidth = 1.5
        path.stroke()
    }
}

/// Turning something drawn by whole quarters, for the two objects that carry letters.
enum QuarterTurn {
    /// Clockwise on screen: the canvas and the export both draw with Y going down, where a
    /// positive angle turns clockwise.
    static func transform(_ quarterTurns: Int, around point: CGPoint) -> NSAffineTransform {
        let transform = NSAffineTransform()
        transform.translateX(by: point.x, yBy: point.y)
        transform.rotate(byDegrees: CGFloat(quarterTurns) * 90)
        transform.translateX(by: -point.x, yBy: -point.y)
        return transform
    }

    static func affine(_ quarterTurns: Int, around point: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: point.x, y: point.y)
            .rotated(by: CGFloat(quarterTurns) * .pi / 2)
            .translatedBy(x: -point.x, y: -point.y)
    }
}

/// Distance from a point to a segment — needed to hit arrows and pencil strokes with the mouse,
/// since they have no area.
enum GeometryMath {
    static func distance(from point: CGPoint, toSegment start: CGPoint, _ end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy

        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }

        // The point projected onto the line, clamped to the segment.
        var t = ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared
        t = min(max(t, 0), 1)

        let projection = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
        return hypot(point.x - projection.x, point.y - projection.y)
    }
}
