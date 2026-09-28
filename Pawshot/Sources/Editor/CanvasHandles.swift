import CoreGraphics

/// What a press on the selected object grabs under V, before it could move the object.
enum CanvasHandle: Equatable {
    /// A corner or a side of a rectangle, a blur or a label. The sides are not drawn: the cursor
    /// shows them, the way the recording region's are.
    case box(SelectionGeometry.Handle)
    /// Just outside a corner: turning. Nothing is drawn there either.
    case turn
    case lineStart, lineEnd
    /// The diamond halfway along a line: bending it.
    case bend
    /// The button beside a line that walks its heads round.
    case heads
}

/// Which handles each object has, where they are and which one is under the mouse. No drawing
/// and no state, so the rules are covered by tests; the canvas draws and drags what this finds.
@MainActor
enum CanvasHandles {
    /// The side of a square handle — the label's size handles, as they were.
    static let squareSide: CGFloat = 8
    static let pointRadius: CGFloat = 5
    /// On a line shorter than `minimumSide` the end circles shrink, so the line between them can
    /// still be grabbed to move it.
    static let smallPointRadius: CGFloat = 3
    static let buttonRadius: CGFloat = 9
    /// A frame smaller than this carries its handles on a frame grown to it, so the object's own
    /// middle stays free for moving.
    static let minimumSide: CGFloat = 24

    private static let cornerReach: CGFloat = 7
    private static let sideReach: CGFloat = 5
    private static let pointReach: CGFloat = 8

    /// The frame the handles of a rectangle, a blur or a label sit on, as it is drawn.
    static func handleBox(of annotation: Annotation) -> SelectionGeometry.RotatedBox? {
        let inset = RectangleAnnotation.selectionInset
        return switch annotation {
        case let rectangle as RectangleAnnotation:
            rectangle.box.grown(by: rectangle.style.lineWidth / 2 + inset, minimumSide: minimumSide)
        case let blur as BlurAnnotation:
            blur.shape.grown(by: inset, minimumSide: minimumSide)
        case let label as TextAnnotation:
            label.box.grown(by: inset, minimumSide: minimumSide)
        default:
            nil
        }
    }

    /// A turned circle looks the same, so a circle has no turning.
    static func canTurn(_ annotation: Annotation) -> Bool {
        if let shape = annotation as? RectangleAnnotation {
            return !shape.style.shapeKind.isRound
        }
        return annotation is TextAnnotation
    }

    /// A label's top and bottom sides change nothing — its height is its text's. A circle has only
    /// its corners: a side would pull it into an oval.
    static func hasHandle(_ handle: SelectionGeometry.Handle, on annotation: Annotation) -> Bool {
        guard handle != .inside else { return false }
        if annotation is TextAnnotation {
            return handle != .top && handle != .bottom
        }
        if let shape = annotation as? RectangleAnnotation, shape.style.shapeKind.isRound {
            return ![.top, .bottom, .left, .right].contains(handle)
        }
        return true
    }

    static func endRadius(of arrow: ArrowAnnotation) -> CGFloat {
        hypot(arrow.end.x - arrow.start.x, arrow.end.y - arrow.start.y) < minimumSide ? smallPointRadius : pointRadius
    }

    static func headsButtonCentre(of arrow: ArrowAnnotation) -> CGPoint {
        SelectionGeometry.headsButtonCentre(
            start: arrow.start,
            end: arrow.end,
            bentMiddle: arrow.control == nil ? nil : arrow.middle,
            offset: buttonRadius + 10 + arrow.style.lineWidth / 2
        )
    }

    /// The handle under `point` on a selected object, if any.
    static func handle(at point: CGPoint, of annotation: Annotation) -> CanvasHandle? {
        if let arrow = annotation as? ArrowAnnotation {
            return lineHandle(at: point, of: arrow)
        }
        guard let box = handleBox(of: annotation) else { return nil }

        if let handle = SelectionGeometry.handle(
            at: box.toLocal(point),
            of: box.local,
            edgeReach: sideReach,
            cornerReach: cornerReach
        ), hasHandle(handle, on: annotation) {
            return .box(handle)
        }
        if canTurn(annotation), SelectionGeometry.isRotationZone(point, of: box) {
            return .turn
        }
        return nil
    }

    private static func lineHandle(at point: CGPoint, of arrow: ArrowAnnotation) -> CanvasHandle? {
        func distance(to other: CGPoint) -> CGFloat {
            hypot(point.x - other.x, point.y - other.y)
        }

        if distance(to: headsButtonCentre(of: arrow)) <= buttonRadius + 2 {
            return .heads
        }
        let toStart = distance(to: arrow.start)
        let toEnd = distance(to: arrow.end)
        if min(toStart, toEnd) <= pointReach {
            return toStart < toEnd ? .lineStart : .lineEnd
        }
        if distance(to: arrow.middle) <= pointReach {
            return .bend
        }
        return nil
    }

    enum CursorKind: Equatable {
        /// A resize arrow for the handle as it lies on screen — a turned box turns its arrows.
        case resize(SelectionGeometry.Handle)
        case turn
        /// Moving a point: an end of a line, or its bend.
        case point
        case button
    }

    static func cursorKind(for handle: CanvasHandle, of annotation: Annotation) -> CursorKind {
        switch handle {
        case let .box(side):
            .resize(SelectionGeometry.screenHandle(side, turnedBy: handleBox(of: annotation)?.angle ?? 0))
        case .turn:
            .turn
        case .lineStart, .lineEnd, .bend:
            .point
        case .heads:
            .button
        }
    }
}
