import CoreGraphics
import Foundation

/// Pure selection arithmetic — no AppKit and no state, so it can be covered by tests. The most
/// dangerous part of the feature lives here: converting coordinates between AppKit (origin at the
/// bottom left, Y axis up) and CoreGraphics/ScreenCaptureKit (origin at the top left, Y axis
/// down). A sign mistake produces a shot of a different part of the screen — one that looks a lot
/// like the right one.
enum SelectionGeometry {
    /// A rectangle from two points: it can be dragged in any direction.
    static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    /// The square in the middle of `rect`, as wide as its shorter side — where a circle drawn in
    /// that box lies, so a rectangle turned into a circle keeps its place.
    static func centredSquare(in rect: CGRect) -> CGRect {
        let side = min(rect.width, rect.height)
        return CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
    }

    /// A triangle in `rect`, its apex at the top middle — Y goes down, as in the captured frame.
    static func trianglePoints(in rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    /// A diamond in `rect`: the middles of its sides, clockwise from the top.
    static func diamondPoints(in rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY),
        ]
    }

    /// A point of a frame `size` after the frame is turned a quarter, in a system with its origin at
    /// the top left and Y going down — the captured frame's. Clockwise, the top left corner lands
    /// top right: `(x, y)` → `(H − y, x)`. The frame is `H × W` afterwards.
    static func rotatedQuarter(_ point: CGPoint, in size: CGSize, clockwise: Bool) -> CGPoint {
        clockwise
            ? CGPoint(x: size.height - point.y, y: point.x)
            : CGPoint(x: point.y, y: size.width - point.x)
    }

    /// A quarter turn about a point, in the same Y-down system: clockwise, what was to the right of
    /// `centre` ends up below it.
    static func rotatedQuarter(_ point: CGPoint, around centre: CGPoint, clockwise: Bool) -> CGPoint {
        let dx = point.x - centre.x
        let dy = point.y - centre.y
        return clockwise
            ? CGPoint(x: centre.x - dy, y: centre.y + dx)
            : CGPoint(x: centre.x + dy, y: centre.y - dx)
    }

    /// A SwiftUI `.global` frame → the window's own coordinates, through a reference both sides
    /// know: the shot, measured by SwiftUI (`shotInSwiftUI`, Y down) and by AppKit (`shotInWindow`,
    /// Y up). Where SwiftUI's global space starts — under the title bar, under the toolbar — is not
    /// something to assume: converting through the content view came out a title bar off,
    /// measured in `AnnotationCanvasViewTests`.
    static func windowRect(fromSwiftUI rect: CGRect, shotInSwiftUI: CGRect, shotInWindow: CGRect) -> CGRect {
        CGRect(
            x: shotInWindow.minX + (rect.minX - shotInSwiftUI.minX),
            y: shotInWindow.maxY - (rect.maxY - shotInSwiftUI.minY),
            width: rect.width,
            height: rect.height
        )
    }

    /// How big the editor's tools are drawn over the shot. Under 75% the cells are too small to hit
    /// and their letters too small to read; over 150% they cover too much of the shot; and never
    /// wider than the window — `panelWidth` is their width at 100%.
    static func toolsScale(_ requested: CGFloat, panelWidth: CGFloat, availableWidth: CGFloat) -> CGFloat {
        let minimum: CGFloat = 0.75
        var maximum: CGFloat = 1.5
        if panelWidth > 0 {
            maximum = min(maximum, availableWidth / panelWidth)
        }
        return max(minimum, min(requested, maximum))
    }

    /// A corner of a rectangle in the Y-down system: `top` is the smaller Y.
    enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        var opposite: Corner {
            switch self {
            case .topLeft: .bottomRight
            case .topRight: .bottomLeft
            case .bottomLeft: .topRight
            case .bottomRight: .topLeft
            }
        }

        func point(of rect: CGRect) -> CGPoint {
            switch self {
            case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
            case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
            }
        }
    }

    /// The corner of `rect` within `radius` of `point`, if any — the handles on a selected label.
    static func corner(of rect: CGRect, near point: CGPoint, radius: CGFloat) -> Corner? {
        Corner.allCases.first { corner in
            let handle = corner.point(of: rect)
            return abs(handle.x - point.x) <= radius && abs(handle.y - point.y) <= radius
        }
    }

    /// Dragging a corner away from the fixed opposite one: how much bigger the thing gets. The
    /// distance ratio, so the drag works along the diagonal whichever corner is held.
    static func cornerScale(anchor: CGPoint, start: CGPoint, current: CGPoint) -> CGFloat {
        let before = hypot(start.x - anchor.x, start.y - anchor.y)
        guard before > 0 else { return 1 }
        return hypot(current.x - anchor.x, current.y - anchor.y) / before
    }

    /// The same for a rectangle: its corners turn, and it comes back normalised.
    static func rotatedQuarter(_ rect: CGRect, in size: CGSize, clockwise: Bool) -> CGRect {
        self.rect(
            from: rotatedQuarter(CGPoint(x: rect.minX, y: rect.minY), in: size, clockwise: clockwise),
            to: rotatedQuarter(CGPoint(x: rect.maxX, y: rect.maxY), in: size, clockwise: clockwise)
        )
    }

    /// A miss instead of a selection: a single click or a shaky hand.
    static func isTooSmall(_ rect: CGRect, minimumSide: CGFloat = 4) -> Bool {
        rect.width < minimumSide || rect.height < minimumSide
    }

    /// AppKit global coordinates → CoreGraphics global coordinates.
    ///
    /// - Parameter primaryScreenMaxY: the top edge of the primary screen in AppKit coordinates,
    ///   i.e. `NSMaxY(NSScreen.screens[0].frame)`. The primary one, not the current one: in
    ///   CoreGraphics the whole system shares a single origin.
    static func convertToCoreGraphics(rect: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenMaxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// CoreGraphics global coordinates → AppKit global coordinates. The flip is its own inverse:
    /// the same arithmetic as `convertToCoreGraphics`, named for the direction it is used in.
    static func convertToAppKit(rect: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
        convertToCoreGraphics(rect: rect, primaryScreenMaxY: primaryScreenMaxY)
    }

    /// A rectangle in global AppKit coordinates → the same rectangle in the coordinates of a
    /// window that covers `screenFrame` exactly (origin at the screen's bottom left).
    static func localRect(of area: CGRect, in screenFrame: CGRect) -> CGRect {
        area.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }

    /// The mouse position → a point inside the overlay of a given screen.
    ///
    /// `NSEvent.mouseLocation` is AppKit's: global, origin at the bottom left of the primary
    /// screen, Y growing upwards. The overlay view is flipped and local to its own screen, so both
    /// corrections are needed — the shift to the screen's own origin and the Y flip. Used to show
    /// the crosshair badge and the window highlight before the mouse has moved at all.
    static func viewPoint(forMouse mouse: CGPoint, on screenFrame: CGRect) -> CGPoint {
        CGPoint(
            x: mouse.x - screenFrame.minX,
            y: screenFrame.maxY - mouse.y
        )
    }

    /// The region in the display's own coordinate system — what `SCStreamConfiguration.sourceRect`
    /// expects.
    static func sourceRect(displayRect: CGRect, displayFrame: CGRect) -> CGRect {
        displayRect.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
    }

    /// Shot size in pixels: points × display scale, rounded down but never to zero.
    static func pixelSize(of rect: CGRect, scale: CGFloat) -> (width: Int, height: Int) {
        (max(1, Int(rect.width * scale)), max(1, Int(rect.height * scale)))
    }

    /// Selection → a rectangle in the pixels of the frozen display frame.
    ///
    /// The frame is captured whole and lives in pixels, while the selection arrives in points and
    /// in global coordinates, so both corrections are needed: a shift by the display origin and a
    /// multiplication by the scale. The frame and the selection share an origin — top left — so
    /// the Y axis is not flipped here.
    ///
    /// Returns `nil` when nothing is left of the region after clipping it to the frame bounds:
    /// that means the frame and the screen have diverged, and cropping blindly is worse than
    /// showing an error.
    static func cropRect(
        displayRect: CGRect,
        displayFrame: CGRect,
        scale: CGFloat,
        imagePixelSize: CGSize
    ) -> CGRect? {
        pixelRect(
            of: sourceRect(displayRect: displayRect, displayFrame: displayFrame),
            scale: scale,
            imagePixelSize: imagePixelSize
        )
    }

    /// A rectangle in the frame's own points → the same rectangle in the frame's pixels.
    ///
    /// The editor keeps its crop in points, but cutting it out of the captured frame needs pixels,
    /// so this conversion runs on every crop change and on every export.
    static func pixelRect(of rect: CGRect, scale: CGFloat, imagePixelSize: CGSize) -> CGRect? {
        // The origin is rounded down and the sides to the nearest value: that way the region
        // doesn't drift by half a pixel and doesn't collapse to zero on a very thin strip.
        let pixels = CGRect(
            x: (rect.minX * scale).rounded(.down),
            y: (rect.minY * scale).rounded(.down),
            width: max(1, (rect.width * scale).rounded()),
            height: max(1, (rect.height * scale).rounded())
        )

        let clipped = pixels.intersection(CGRect(origin: .zero, size: imagePixelSize))
        return clipped.isEmpty ? nil : clipped
    }

    /// How far each edge of the crop was dragged, in points of the captured frame. Positive means
    /// outwards, i.e. the crop grows on that side.
    struct CropEdgeDeltas: Equatable {
        var left: CGFloat = 0
        var top: CGFloat = 0
        var right: CGFloat = 0
        var bottom: CGFloat = 0

        var isEmpty: Bool {
            left == 0 && top == 0 && right == 0 && bottom == 0
        }
    }

    /// The minimum side of a crop, in points. A shot smaller than this can't be worked with, and a
    /// zero-sized one would break every downstream calculation.
    static let minimumCropSide: CGFloat = 32

    /// Grows or shrinks the crop by dragging its edges, clamped to the captured frame.
    ///
    /// The frame is all there is: nothing exists outside the display that was captured, so an edge
    /// that reaches the boundary simply stops. The same call handles shrinking — a negative delta
    /// pulls an edge inwards — down to `minimumCropSide`.
    static func resizedCrop(
        _ crop: CGRect,
        by deltas: CropEdgeDeltas,
        limitedTo frameSize: CGSize,
        minimumSide: CGFloat = minimumCropSide
    ) -> CGRect {
        let horizontal = resizedSpan(
            start: crop.minX,
            end: crop.maxX,
            lower: deltas.left,
            upper: deltas.right,
            limit: frameSize.width,
            minimum: minimumSide
        )
        let vertical = resizedSpan(
            start: crop.minY,
            end: crop.maxY,
            lower: deltas.top,
            upper: deltas.bottom,
            limit: frameSize.height,
            minimum: minimumSide
        )

        return CGRect(
            x: horizontal.start,
            y: vertical.start,
            width: horizontal.end - horizontal.start,
            height: vertical.end - vertical.start
        )
    }

    /// One axis of `resizedCrop`. The edge that was actually dragged gives way first: if the span
    /// hits the minimum, the dragged edge stops instead of pushing the opposite one across the
    /// frame.
    private static func resizedSpan(
        start: CGFloat,
        end: CGFloat,
        lower: CGFloat,
        upper: CGFloat,
        limit: CGFloat,
        minimum: CGFloat
    ) -> (start: CGFloat, end: CGFloat) {
        guard limit > 0 else { return (0, 0) }

        let minimum = min(minimum, limit)
        var newStart = min(max(0, start - lower), limit)
        var newEnd = min(max(0, end + upper), limit)

        if newEnd - newStart < minimum {
            if lower != 0 {
                newStart = newEnd - minimum
            } else {
                newEnd = newStart + minimum
            }

            // The correction itself can run off the frame — pull the whole span back inside.
            if newStart < 0 {
                newStart = 0
                newEnd = minimum
            }
            if newEnd > limit {
                newEnd = limit
                newStart = limit - minimum
            }
        }

        return (newStart, newEnd)
    }

    /// Position of the coordinates badge: bottom right of the cursor by default.
    ///
    /// Near a screen edge the badge flips to the opposite side, otherwise the text runs past the
    /// boundary and can't be read. Coordinates are in the view's system with the origin at the top
    /// left (`isFlipped = true`), so "below" means +Y.
    static func badgeOrigin(
        cursor: CGPoint,
        badgeSize: CGSize,
        bounds: CGRect,
        offset: CGFloat = 14
    ) -> CGPoint {
        var x = cursor.x + offset
        var y = cursor.y + offset

        if x + badgeSize.width > bounds.maxX {
            x = cursor.x - offset - badgeSize.width
        }
        if y + badgeSize.height > bounds.maxY {
            y = cursor.y - offset - badgeSize.height
        }

        // If the screen is so small that neither side fits — pin it to the edge, as long as the
        // badge stays visible.
        x = min(max(bounds.minX, x), max(bounds.minX, bounds.maxX - badgeSize.width))
        y = min(max(bounds.minY, y), max(bounds.minY, bounds.maxY - badgeSize.height))

        return CGPoint(x: x, y: y)
    }

    /// The pixel size of a recording of `rect` (points) at `scale` pixels per point.
    ///
    /// Rounded down to even numbers: HEVC and H.264 encode 4:2:0 video in 2×2 blocks, and an odd
    /// width is either rejected or padded with a green line on the edge. Never below 2×2.
    static func recordingPixelSize(of rect: CGRect, scale: CGFloat) -> (width: Int, height: Int) {
        func even(_ value: CGFloat) -> Int {
            max(2, Int((value * scale).rounded(.down)) & ~1)
        }
        return (even(rect.width), even(rect.height))
    }

    /// Where the recording pill goes, in AppKit screen coordinates (origin bottom left): centred
    /// under the recorded area, above it when there's no room below, and inside the bottom of the
    /// screen when the area fills it — a full-screen recording. The pill is left out of the
    /// recording itself, so sitting on top of the area costs nothing but a covered corner.
    static func pillOrigin(below area: CGRect, pillSize: CGSize, visibleFrame: CGRect, gap: CGFloat = 12) -> CGPoint {
        let x = min(
            max(visibleFrame.minX + gap, area.midX - pillSize.width / 2),
            visibleFrame.maxX - gap - pillSize.width
        )

        let below = area.minY - gap - pillSize.height
        if below >= visibleFrame.minY + gap {
            return CGPoint(x: x, y: below)
        }
        let above = area.maxY + gap
        if above + pillSize.height <= visibleFrame.maxY - gap {
            return CGPoint(x: x, y: above)
        }
        return CGPoint(x: x, y: visibleFrame.minY + gap * 2)
    }

    /// Position of the loupe: above and to the left of the cursor, the side the badge doesn't use.
    /// Near an edge it flips to the other side, the same way the badge does, and it never leaves
    /// the screen. Coordinates are the view's, origin at the top left.
    static func loupeOrigin(
        cursor: CGPoint,
        loupeSize: CGSize,
        bounds: CGRect,
        offset: CGFloat = 20
    ) -> CGPoint {
        var x = cursor.x - offset - loupeSize.width
        var y = cursor.y - offset - loupeSize.height

        if x < bounds.minX {
            x = cursor.x + offset
        }
        if y < bounds.minY {
            y = cursor.y + offset
        }

        x = min(max(bounds.minX, x), max(bounds.minX, bounds.maxX - loupeSize.width))
        y = min(max(bounds.minY, y), max(bounds.minY, bounds.maxY - loupeSize.height))

        return CGPoint(x: x, y: y)
    }

    /// The pixel of the frozen frame under a point of the view: the view works in points, the
    /// frame in pixels, and the pixel is the one whose square contains the point.
    static func pixel(under point: CGPoint, scale: CGFloat, imagePixelSize: CGSize) -> CGPoint {
        let x = min(max(0, (point.x * scale).rounded(.down)), max(0, imagePixelSize.width - 1))
        let y = min(max(0, (point.y * scale).rounded(.down)), max(0, imagePixelSize.height - 1))
        return CGPoint(x: x, y: y)
    }

    /// The square of pixels the loupe magnifies: `radius` pixels on each side of `pixel`, so the
    /// pixel under the cursor is always the middle one. At the edge of the frame the square slides
    /// inwards instead of shrinking — the loupe keeps its size, and the marked pixel moves off
    /// centre, which is honest about where the cursor is.
    static func loupeSampleRect(around pixel: CGPoint, radius: Int, imagePixelSize: CGSize) -> CGRect {
        let side = CGFloat(radius * 2 + 1)
        var x = pixel.x - CGFloat(radius)
        var y = pixel.y - CGFloat(radius)

        x = min(max(0, x), max(0, imagePixelSize.width - side))
        y = min(max(0, y), max(0, imagePixelSize.height - side))

        return CGRect(
            x: x,
            y: y,
            width: min(side, imagePixelSize.width),
            height: min(side, imagePixelSize.height)
        )
    }

    /// The four L-shaped corners drawn over a frame: the frame corners of the app icon, used on the
    /// selection, the thumbnails and the About tile.
    ///
    /// Each bracket is three points: the end of the horizontal arm, the corner, the end of the
    /// vertical arm. An arm never runs past the middle of its side, so on a thin selection the two
    /// brackets of a side meet instead of crossing.
    static func cornerBrackets(for rect: CGRect, armLength: CGFloat) -> [[CGPoint]] {
        let horizontal = max(0, min(armLength, rect.width / 2))
        let vertical = max(0, min(armLength, rect.height / 2))

        return [
            [
                CGPoint(x: rect.minX + horizontal, y: rect.minY),
                CGPoint(x: rect.minX, y: rect.minY),
                CGPoint(x: rect.minX, y: rect.minY + vertical),
            ],
            [
                CGPoint(x: rect.maxX - horizontal, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY + vertical),
            ],
            [
                CGPoint(x: rect.minX + horizontal, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.maxY - vertical),
            ],
            [
                CGPoint(x: rect.maxX - horizontal, y: rect.maxY),
                CGPoint(x: rect.maxX, y: rect.maxY),
                CGPoint(x: rect.maxX, y: rect.maxY - vertical),
            ],
        ]
    }

    // MARK: - Adjusting a recording region

    /// The part of a selection under the cursor, in view coordinates (origin top left).
    enum Handle: Equatable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
        case inside
    }

    /// Which handle `point` grabs, if any. Corners win over edges and edges over the inside, so a
    /// press a few points off a corner resizes rather than moves. `nil` outside the grab zone: the
    /// press starts a new selection.
    /// Where a grabbed edge or corner goes: it follows the mouse by the distance the mouse moved,
    /// not to the mouse itself. With grab zones 10–16 pt wide, snapping the edge to the pointer made
    /// it jump on the first pixel of the drag.
    static func handleTarget(_ handle: Handle, of rect: CGRect, grabbedAt grab: CGPoint, mouse: CGPoint) -> CGPoint {
        let x: CGFloat = switch handle {
        case .left, .topLeft, .bottomLeft: rect.minX
        case .right, .topRight, .bottomRight: rect.maxX
        case .top, .bottom, .inside: grab.x
        }
        let y: CGFloat = switch handle {
        case .top, .topLeft, .topRight: rect.minY
        case .bottom, .bottomLeft, .bottomRight: rect.maxY
        case .left, .right, .inside: grab.y
        }
        return CGPoint(x: mouse.x + (x - grab.x), y: mouse.y + (y - grab.y))
    }

    /// The corners reach 16 pt each way — the length of the drawn bracket's arms, so a press
    /// anywhere on an arm takes the corner. The edges reach 10 pt either side of the line, so a
    /// press just outside still takes the edge instead of wiping the region. On a small region
    /// both shrink to a quarter of the side, so its middle can still be grabbed.
    static func handle(at point: CGPoint, of rect: CGRect, edgeReach: CGFloat = 10, cornerReach: CGFloat = 16) -> Handle? {
        let edgeX = min(edgeReach, rect.width / 4)
        let edgeY = min(edgeReach, rect.height / 4)
        let cornerX = max(min(cornerReach, rect.width / 4), edgeX)
        let cornerY = max(min(cornerReach, rect.height / 4), edgeY)

        let corners: [(Handle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
        ]
        for (handle, corner) in corners where abs(point.x - corner.x) <= cornerX && abs(point.y - corner.y) <= cornerY {
            return handle
        }

        let withinX = point.x >= rect.minX && point.x <= rect.maxX
        let withinY = point.y >= rect.minY && point.y <= rect.maxY
        if withinY, abs(point.x - rect.minX) <= edgeX {
            return .left
        }
        if withinY, abs(point.x - rect.maxX) <= edgeX {
            return .right
        }
        if withinX, abs(point.y - rect.minY) <= edgeY {
            return .top
        }
        if withinX, abs(point.y - rect.maxY) <= edgeY {
            return .bottom
        }
        return rect.contains(point) ? .inside : nil
    }

    /// A drag from `anchor` to `point`, held to `aspect` (width / height) when there is one. The
    /// point is pulled into `bounds` first, so the result never leaves them and never loses its
    /// proportions to clipping.
    static func rect(from anchor: CGPoint, to point: CGPoint, aspect: CGFloat?, within bounds: CGRect) -> CGRect {
        let end = CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
        guard let aspect, aspect > 0 else { return rect(from: anchor, to: end) }

        var width = abs(end.x - anchor.x)
        var height = abs(end.y - anchor.y)
        if height == 0 || width / height > aspect {
            width = height * aspect
        } else {
            height = width / aspect
        }
        return CGRect(
            x: end.x < anchor.x ? anchor.x - width : anchor.x,
            y: end.y < anchor.y ? anchor.y - height : anchor.y,
            width: width,
            height: height
        )
    }

    /// Where the far corner of an even shape goes — a square, an equilateral triangle's box —
    /// drawn from `start` towards `point`, as a square drawn with ⇧ is in any editor: from the
    /// corner the drag began at, whichever way it went.
    static func evenEnd(from start: CGPoint, to point: CGPoint, aspect: CGFloat) -> CGPoint {
        let even = rect(from: start, to: point, aspect: aspect, within: .infinite)
        return CGPoint(x: point.x < start.x ? even.minX : even.maxX, y: point.y < start.y ? even.minY : even.maxY)
    }

    /// `rect` with the grabbed handle dragged to `point`, inside `bounds`.
    ///
    /// A corner keeps the opposite corner in place. An edge moves only itself — and with a fixed
    /// aspect it also resizes the other side around its middle, which is the only way an edge can
    /// keep the proportions.
    ///
    /// `fromCenter` — ⌥ held — mirrors the change about the middle of `rect`: what the dragged
    /// side gains, the opposite side gains too, as far as the nearer screen edge allows.
    static func resized(
        _ rect: CGRect,
        dragging handle: Handle,
        to point: CGPoint,
        aspect: CGFloat?,
        within bounds: CGRect,
        fromCenter: Bool = false
    ) -> CGRect {
        if fromCenter {
            let oneSided = resized(rect, dragging: handle, to: point, aspect: aspect, within: bounds)
            let width = min(
                max(0, rect.width + 2 * (oneSided.width - rect.width)),
                2 * min(rect.midX - bounds.minX, bounds.maxX - rect.midX)
            )
            let height = min(
                max(0, rect.height + 2 * (oneSided.height - rect.height)),
                2 * min(rect.midY - bounds.minY, bounds.maxY - rect.midY)
            )
            return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        }

        let x = min(max(point.x, bounds.minX), bounds.maxX)
        let y = min(max(point.y, bounds.minY), bounds.maxY)

        let opposite: CGPoint? = switch handle {
        case .topLeft: CGPoint(x: rect.maxX, y: rect.maxY)
        case .topRight: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomRight: CGPoint(x: rect.minX, y: rect.minY)
        default: nil
        }
        if let opposite {
            return self.rect(from: opposite, to: CGPoint(x: x, y: y), aspect: aspect, within: bounds)
        }

        switch handle {
        case .left, .right:
            let fixed = handle == .left ? rect.maxX : rect.minX
            let width = abs(x - fixed)
            let originX = min(x, fixed)
            guard let aspect, aspect > 0 else {
                return CGRect(x: originX, y: rect.minY, width: width, height: rect.height)
            }
            let room = 2 * min(rect.midY - bounds.minY, bounds.maxY - rect.midY)
            let height = min(width / aspect, room)
            let fitted = height * aspect
            return CGRect(
                x: handle == .left ? fixed - fitted : fixed,
                y: rect.midY - height / 2,
                width: fitted,
                height: height
            ).standardized

        case .top, .bottom:
            let fixed = handle == .top ? rect.maxY : rect.minY
            let height = abs(y - fixed)
            let originY = min(y, fixed)
            guard let aspect, aspect > 0 else {
                return CGRect(x: rect.minX, y: originY, width: rect.width, height: height)
            }
            let room = 2 * min(rect.midX - bounds.minX, bounds.maxX - rect.midX)
            let width = min(height * aspect, room)
            let fitted = width / aspect
            return CGRect(
                x: rect.midX - width / 2,
                y: handle == .top ? fixed - fitted : fixed,
                width: width,
                height: fitted
            ).standardized

        default:
            return rect
        }
    }

    /// `rect` shifted by `delta`, stopped at the edges of `bounds` rather than cut by them.
    static func moved(_ rect: CGRect, by delta: CGSize, within bounds: CGRect) -> CGRect {
        CGRect(
            x: min(max(rect.minX + delta.width, bounds.minX), bounds.maxX - rect.width),
            y: min(max(rect.minY + delta.height, bounds.minY), bounds.maxY - rect.height),
            width: rect.width,
            height: rect.height
        )
    }

    /// The smallest zone worth hiding, in points on either side.
    static let minimumZoneSide: CGFloat = 8

    /// A zone drawn over a recording region, as fractions of the region: 0…1, origin top left —
    /// the way the timeline keeps it, so it survives any size of the file, and follows the region
    /// when that moves. Cut to the region; `nil` when what is left is smaller than
    /// `minimumZoneSide` either way.
    static func zoneFractions(of zone: CGRect, in region: CGRect) -> CGRect? {
        let inside = zone.standardized.intersection(region)
        guard !inside.isNull, inside.width >= minimumZoneSide, inside.height >= minimumZoneSide,
              region.width > 0, region.height > 0
        else { return nil }
        return CGRect(
            x: (inside.minX - region.minX) / region.width,
            y: (inside.minY - region.minY) / region.height,
            width: inside.width / region.width,
            height: inside.height / region.height
        )
    }

    /// The inverse: where a zone kept as fractions lies on the region now.
    static func zone(fromFractions fractions: CGRect, in region: CGRect) -> CGRect {
        CGRect(
            x: region.minX + fractions.minX * region.width,
            y: region.minY + fractions.minY * region.height,
            width: fractions.width * region.width,
            height: fractions.height * region.height
        )
    }

    /// Four bars round `area`, `thickness` wide, none over it: what a paused recording's region is
    /// grabbed by. Left, right, then the bars at `minY` and at `maxY`; the side bars include the
    /// corners, so the ring has no gap for a click to slip through. Inside `area` there is no bar
    /// at all — a click in the region goes to the app being recorded, as it did before the pause.
    static func grabBars(around area: CGRect, thickness: CGFloat) -> [CGRect] {
        let tall = area.height + 2 * thickness
        return [
            CGRect(x: area.minX - thickness, y: area.minY - thickness, width: thickness, height: tall),
            CGRect(x: area.maxX, y: area.minY - thickness, width: thickness, height: tall),
            CGRect(x: area.minX, y: area.minY - thickness, width: area.width, height: thickness),
            CGRect(x: area.minX, y: area.maxY, width: area.width, height: thickness),
        ]
    }

    /// `rect` reshaped to `aspect`: the same area and the same middle, shrunk if it no longer fits
    /// `bounds`, then moved back inside them. Keeping the area — rather than fitting into the old
    /// rectangle — is what lets the proportions be cycled without the region shrinking each time.
    static func applying(aspect: CGFloat, to rect: CGRect, within bounds: CGRect) -> CGRect {
        let area = max(rect.width * rect.height, 1)
        var width = (area * aspect).squareRoot()
        var height = width / aspect
        let shrink = min(1, bounds.width / width, bounds.height / height)
        width *= shrink
        height *= shrink

        let centred = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        return moved(centred, by: .zero, within: bounds)
    }

    /// The region that records exactly `pixelWidth × pixelHeight` at `outputScale` pixels per
    /// point, centred on `center` and kept inside `bounds`. `nil` when it doesn't fit the display:
    /// a typed size is a promise about the file, and a cropped one would break it.
    static func exactRect(
        pixelWidth: Int,
        pixelHeight: Int,
        outputScale: CGFloat,
        around center: CGPoint,
        within bounds: CGRect
    ) -> CGRect? {
        let size = CGSize(width: CGFloat(pixelWidth) / outputScale, height: CGFloat(pixelHeight) / outputScale)
        guard size.width >= 1, size.height >= 1, size.width <= bounds.width, size.height <= bounds.height
        else { return nil }

        let centred = CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        return moved(centred, by: .zero, within: bounds)
    }

    // MARK: - Grips, the magnet and the drop onto a window

    /// How far the mouse goes from a press before the press counts as a drag. A plain click
    /// beside a recording region must leave the region alone.
    static func isDrag(from start: CGPoint, to point: CGPoint, threshold: CGFloat = 3) -> Bool {
        hypot(point.x - start.x, point.y - start.y) > threshold
    }

    /// Whether the cursor is close enough to a region for its grip pills to show.
    static func isNear(_ point: CGPoint, to rect: CGRect, reach: CGFloat = 44) -> Bool {
        rect.insetBy(dx: -reach, dy: -reach).contains(point)
    }

    /// The pills on the middles of a region's edges, each centred on its edge line: 34 × 5 pt,
    /// and 56 × 7 for the one under the cursor. A side under 80 pt has none — the pill would run
    /// into the corner brackets, and the edge is still grabbed by its zone.
    static func gripPills(for rect: CGRect, hot: Handle?) -> [(handle: Handle, frame: CGRect)] {
        func pill(_ handle: Handle) -> (handle: Handle, frame: CGRect) {
            let length: CGFloat = handle == hot ? 56 : 34
            let thickness: CGFloat = handle == hot ? 7 : 5
            let horizontal = handle == .top || handle == .bottom
            let size = horizontal ? CGSize(width: length, height: thickness) : CGSize(width: thickness, height: length)
            let center = switch handle {
            case .top: CGPoint(x: rect.midX, y: rect.minY)
            case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
            case .left: CGPoint(x: rect.minX, y: rect.midY)
            default: CGPoint(x: rect.maxX, y: rect.midY)
            }
            return (handle, CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
        }
        let shortest: CGFloat = 80
        return (rect.width >= shortest ? [pill(.top), pill(.bottom)] : [])
            + (rect.height >= shortest ? [pill(.left), pill(.right)] : [])
    }

    /// The lines a dragged region sticks to: `xs` and `ys` take its edges, the two middles take
    /// its middle.
    struct SnapLines: Equatable {
        var xs: [CGFloat] = []
        var ys: [CGFloat] = []
        var middleX: CGFloat?
        var middleY: CGFloat?
    }

    /// Where a guide line is drawn while the region sticks; `nil` on an axis that sticks to nothing.
    struct SnapGuides: Equatable {
        var x: CGFloat?
        var y: CGFloat?
    }

    /// The edges of the screen, its middle, and the edges of `windows` (view coordinates, front
    /// to back) that can be seen. An edge counts when its window is the one on top right beside
    /// the edge, at the height — or, for a line across, the x — nearest to the region's middle:
    /// an edge lying under another window is a line nobody sees.
    static func snapLines(windows: [CGRect], bounds: CGRect, around rect: CGRect) -> SnapLines {
        var lines = SnapLines(xs: [bounds.minX, bounds.maxX], ys: [bounds.minY, bounds.maxY], middleX: bounds.midX, middleY: bounds.midY)
        for (index, window) in windows.enumerated() where window.width > 2 && window.height > 2 {
            let y = min(max(rect.midY, window.minY + 1), window.maxY - 1)
            let x = min(max(rect.midX, window.minX + 1), window.maxX - 1)
            func onTop(_ point: CGPoint) -> Bool {
                windows.firstIndex { $0.contains(point) } == index
            }
            if window.minX > bounds.minX, onTop(CGPoint(x: window.minX + 1, y: y)) {
                lines.xs.append(window.minX)
            }
            if window.maxX < bounds.maxX, onTop(CGPoint(x: window.maxX - 1, y: y)) {
                lines.xs.append(window.maxX)
            }
            if window.minY > bounds.minY, onTop(CGPoint(x: x, y: window.minY + 1)) {
                lines.ys.append(window.minY)
            }
            if window.maxY < bounds.maxY, onTop(CGPoint(x: x, y: window.maxY - 1)) {
                lines.ys.append(window.maxY)
            }
        }
        return lines
    }

    /// The nearest of `lines` to `value` within `tolerance`, and how far it is.
    private static func nearest(_ lines: [CGFloat], to value: CGFloat, tolerance: CGFloat) -> (line: CGFloat, shift: CGFloat)? {
        lines
            .map { (line: $0, shift: $0 - value) }
            .filter { abs($0.shift) <= tolerance }
            .min { abs($0.shift) < abs($1.shift) }
    }

    /// A region being moved, pulled onto the nearest line on each axis — by an edge, or by its
    /// middle onto the middle of the screen. The size never changes.
    static func snapped(
        moving rect: CGRect,
        to lines: SnapLines,
        within bounds: CGRect,
        tolerance: CGFloat = 6
    ) -> (rect: CGRect, guides: SnapGuides) {
        func pull(_ origin: CGFloat, _ length: CGFloat, _ edges: [CGFloat], _ middle: CGFloat?) -> (line: CGFloat, shift: CGFloat)? {
            let candidates = [nearest(edges, to: origin, tolerance: tolerance), nearest(edges, to: origin + length, tolerance: tolerance)]
                + [middle.flatMap { nearest([$0], to: origin + length / 2, tolerance: tolerance) }]
            return candidates.compactMap(\.self).min { abs($0.shift) < abs($1.shift) }
        }
        let x = pull(rect.minX, rect.width, lines.xs, lines.middleX)
        let y = pull(rect.minY, rect.height, lines.ys, lines.middleY)
        let shifted = rect.offsetBy(dx: x?.shift ?? 0, dy: y?.shift ?? 0)
        let inside = moved(shifted, by: .zero, within: bounds)
        return (inside, SnapGuides(x: inside.minX == shifted.minX ? x?.line : nil, y: inside.minY == shifted.minY ? y?.line : nil))
    }

    /// Where a dragged edge or corner is headed, pulled onto the nearest line: only on the axes
    /// that handle moves along.
    static func snapped(
        _ point: CGPoint,
        dragging handle: Handle,
        to lines: SnapLines,
        tolerance: CGFloat = 6
    ) -> (point: CGPoint, guides: SnapGuides) {
        let movesX = [.left, .right, .topLeft, .topRight, .bottomLeft, .bottomRight].contains(handle)
        let movesY = [.top, .bottom, .topLeft, .topRight, .bottomLeft, .bottomRight].contains(handle)
        let x = movesX ? nearest(lines.xs, to: point.x, tolerance: tolerance) : nil
        let y = movesY ? nearest(lines.ys, to: point.y, tolerance: tolerance) : nil
        return (CGPoint(x: x?.line ?? point.x, y: y?.line ?? point.y), SnapGuides(x: x?.line, y: y?.line))
    }

    /// The window a dragged region offers to fit: the one on top under the region's middle, and
    /// only while that middle is close to the window's own — within `tolerance` of its shorter
    /// side, both ways. Anywhere else over the window the region is simply laid on top of it.
    /// `windows` are in view coordinates, front to back; the answer is an index into them.
    static func fitCandidate(
        center: CGPoint,
        windows: [CGRect],
        tolerance: CGFloat = 0.15,
        minimumSide: CGFloat = 60
    ) -> Int? {
        guard let index = windows.firstIndex(where: { $0.contains(center) }) else { return nil }
        let window = windows[index]
        let shorter = min(window.width, window.height)
        let reach = shorter * tolerance
        guard shorter >= minimumSide, abs(center.x - window.midX) <= reach, abs(center.y - window.midY) <= reach
        else { return nil }
        return index
    }

    /// A region fitted to a window, grabbed again: back at `size`, with the grabbed spot the same
    /// share of the way across and down as it was in the fitted one, and still on the screen.
    static func restored(size: CGSize, grabbedAt grab: CGPoint, in fitted: CGRect, within bounds: CGRect) -> CGRect {
        let shareX = fitted.width > 0 ? (grab.x - fitted.minX) / fitted.width : 0.5
        let shareY = fitted.height > 0 ? (grab.y - fitted.minY) / fitted.height : 0.5
        let rect = CGRect(
            x: grab.x - size.width * shareX,
            y: grab.y - size.height * shareY,
            width: size.width,
            height: size.height
        )
        return moved(rect, by: .zero, within: bounds)
    }

    /// An arrow key: the region shifted by `delta`, or — `resizing`, ⌥ held — its right and bottom
    /// edges moved by it. Stops at the screen, and never shrinks the region out of reach.
    static func nudged(_ rect: CGRect, by delta: CGSize, resizing: Bool, within bounds: CGRect) -> CGRect {
        guard resizing else { return moved(rect, by: delta, within: bounds) }
        let smallest: CGFloat = 8
        return CGRect(
            x: rect.minX,
            y: rect.minY,
            width: min(max(rect.width + delta.width, smallest), bounds.maxX - rect.minX),
            height: min(max(rect.height + delta.height, smallest), bounds.maxY - rect.minY)
        )
    }

    /// Where the recording toolbar goes, in view coordinates (origin top left): the middle of the
    /// bottom of the screen, whatever the region does.
    static func toolbarOrigin(toolbarSize: CGSize, bounds: CGRect, inset: CGFloat = 48) -> CGPoint {
        CGPoint(x: bounds.midX - toolbarSize.width / 2, y: bounds.maxY - toolbarSize.height - inset)
    }

    /// Where the size label goes while an edge or a corner is dragged: just outside that edge,
    /// by its middle — or by the corner — and pushed back inside the screen.
    static func edgeLabelOrigin(
        for handle: Handle,
        of rect: CGRect,
        labelSize: CGSize,
        bounds: CGRect,
        gap: CGFloat = 8
    ) -> CGPoint {
        let x: CGFloat = switch handle {
        case .left, .topLeft, .bottomLeft: rect.minX - gap - labelSize.width
        case .right, .topRight, .bottomRight: rect.maxX + gap
        case .top, .bottom, .inside: rect.midX - labelSize.width / 2
        }
        let y: CGFloat = switch handle {
        case .top, .topLeft, .topRight: rect.minY - gap - labelSize.height
        case .bottom, .bottomLeft, .bottomRight: rect.maxY + gap
        case .left, .right, .inside: rect.midY - labelSize.height / 2
        }
        return CGPoint(
            x: min(max(bounds.minX, x), bounds.maxX - labelSize.width),
            y: min(max(bounds.minY, y), bounds.maxY - labelSize.height)
        )
    }

    // MARK: - Handles on drawn objects

    /// A rectangle turned about its own centre, in the Y-down system: a positive angle turns it
    /// clockwise on screen. The editor keeps a rotated rectangle and a turned label this way, and
    /// their handles sit on its corners.
    struct RotatedBox: Equatable {
        var center: CGPoint
        var size: CGSize
        /// Radians.
        var angle: CGFloat = 0

        /// The box unturned, around the origin — the system its handles are found in.
        var local: CGRect {
            CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        }

        /// A point of the shot → the box's own unturned system, origin at its centre.
        func toLocal(_ point: CGPoint) -> CGPoint {
            let dx = point.x - center.x
            let dy = point.y - center.y
            return CGPoint(x: dx * cos(angle) + dy * sin(angle), y: -dx * sin(angle) + dy * cos(angle))
        }

        func toWorld(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: center.x + point.x * cos(angle) - point.y * sin(angle),
                y: center.y + point.x * sin(angle) + point.y * cos(angle)
            )
        }

        func corner(_ corner: Corner) -> CGPoint {
            toWorld(corner.point(of: local))
        }

        /// The same box grown by `inset` on every side, and to at least `minimumSide` — where the
        /// handles of a very small object go, so its middle can still be grabbed.
        func grown(by inset: CGFloat, minimumSide: CGFloat = 0) -> RotatedBox {
            RotatedBox(
                center: center,
                size: CGSize(
                    width: max(size.width + inset * 2, minimumSide),
                    height: max(size.height + inset * 2, minimumSide)
                ),
                angle: angle
            )
        }

        /// The axis-aligned rectangle around the turned box.
        var bounds: CGRect {
            let corners = Corner.allCases.map(corner)
            let xs = corners.map(\.x)
            let ys = corners.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
    }

    /// The box with a handle dragged: the edge or corner follows the mouse by how far it moved, in
    /// the box's own turned system, and the opposite side stays where it is on the shot.
    ///
    /// - `keepsAspect`: a corner keeps the proportions (⇧).
    /// - `fromCentre`: the opposite side mirrors the dragged one and the centre stays (⌥).
    /// - A side never shrinks under `minimumSide` and never flips over the opposite one.
    static func resized(
        _ box: RotatedBox,
        dragging handle: Handle,
        grabbedAt grab: CGPoint,
        mouse: CGPoint,
        keepsAspect: Bool,
        fromCentre: Bool,
        minimumSide: CGFloat
    ) -> RotatedBox {
        let local = box.local
        let target = handleTarget(handle, of: local, grabbedAt: box.toLocal(grab), mouse: box.toLocal(mouse))
        let sx: CGFloat = switch handle {
        case .left, .topLeft, .bottomLeft: -1
        case .right, .topRight, .bottomRight: 1
        default: 0
        }
        let sy: CGFloat = switch handle {
        case .top, .topLeft, .topRight: -1
        case .bottom, .bottomLeft, .bottomRight: 1
        default: 0
        }

        var width = box.size.width
        var height = box.size.height
        if sx != 0 {
            width = fromCentre ? 2 * sx * target.x : sx * (target.x - (-sx * local.width / 2))
            width = max(width, minimumSide)
        }
        if sy != 0 {
            height = fromCentre ? 2 * sy * target.y : sy * (target.y - (-sy * local.height / 2))
            height = max(height, minimumSide)
        }
        if keepsAspect, sx != 0, sy != 0, box.size.width > 0, box.size.height > 0 {
            let scale = max(width / box.size.width, height / box.size.height)
            width = max(box.size.width * scale, minimumSide)
            height = max(box.size.height * scale, minimumSide)
        }

        let centre = fromCentre
            ? CGPoint.zero
            : CGPoint(
                x: sx == 0 ? 0 : -sx * local.width / 2 + sx * width / 2,
                y: sy == 0 ? 0 : -sy * local.height / 2 + sy * height / 2
            )
        return RotatedBox(center: box.toWorld(centre), size: CGSize(width: width, height: height), angle: box.angle)
    }

    /// Whether `point` is in the turning zone of a box: just outside one of its corners, where
    /// Figma turns things. Nothing is drawn there — the cursor says it.
    static func isRotationZone(_ point: CGPoint, of box: RotatedBox, reach: CGFloat = 16) -> Bool {
        let local = box.toLocal(point)
        guard !box.local.insetBy(dx: -2, dy: -2).contains(local) else { return false }
        return Corner.allCases.contains { corner in
            let tip = corner.point(of: box.local)
            return hypot(local.x - tip.x, local.y - tip.y) <= reach
        }
    }

    /// The angle a turn drag has reached: the start angle plus how far the mouse went round the
    /// centre. With `snaps` it lands on whole multiples of `step` — 0°, 15°, 30°…
    static func turnedAngle(
        from start: CGFloat,
        centre: CGPoint,
        grab: CGPoint,
        mouse: CGPoint,
        snaps: Bool,
        step: CGFloat = .pi / 12
    ) -> CGFloat {
        let swept = atan2(mouse.y - centre.y, mouse.x - centre.x) - atan2(grab.y - centre.y, grab.x - centre.x)
        let angle = normalizedAngle(start + swept)
        return snaps ? normalizedAngle((angle / step).rounded() * step) : angle
    }

    /// An angle brought into (−π, π].
    static func normalizedAngle(_ angle: CGFloat) -> CGFloat {
        var result = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if result > .pi {
            result -= 2 * .pi
        }
        if result <= -.pi {
            result += 2 * .pi
        }
        return result
    }

    /// Degrees as a person reads them off a shot: counterclockwise is positive, like on a
    /// protractor — the Y-down angle with its sign turned.
    static func displayDegrees(_ angle: CGFloat) -> Int {
        let degrees = Int((-angle * 180 / .pi).rounded())
        return degrees == -180 ? 180 : degrees
    }

    /// The moving end of a line with ⇧: the same length, the direction rounded to `step`.
    static func snappedEnd(fixed: CGPoint, moving: CGPoint, step: CGFloat = .pi / 12) -> CGPoint {
        let length = hypot(moving.x - fixed.x, moving.y - fixed.y)
        let angle = (atan2(moving.y - fixed.y, moving.x - fixed.x) / step).rounded() * step
        return CGPoint(x: fixed.x + cos(angle) * length, y: fixed.y + sin(angle) * length)
    }

    /// A point of the quadratic curve from `start` to `end` bent by `control`.
    static func curvePoint(start: CGPoint, control: CGPoint, end: CGPoint, at t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
            y: u * u * start.y + 2 * u * t * control.y + t * t * end.y
        )
    }

    /// The control point that makes the curve pass through `middle` halfway along — what dragging
    /// the diamond on a line means. Dropped within `straightens` of the straight line's middle, the
    /// line is straight again: `nil`.
    static func control(through middle: CGPoint, start: CGPoint, end: CGPoint, straightens: CGFloat = 4) -> CGPoint? {
        let chordMiddle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        guard hypot(middle.x - chordMiddle.x, middle.y - chordMiddle.y) > straightens else { return nil }
        return CGPoint(x: 2 * middle.x - chordMiddle.x, y: 2 * middle.y - chordMiddle.y)
    }

    /// Points along a line, straight or bent — for hitting it with the mouse and for its frame.
    static func curveSamples(start: CGPoint, control: CGPoint?, end: CGPoint, count: Int = 24) -> [CGPoint] {
        guard let control else { return [start, end] }
        return (0 ... count).map { curvePoint(start: start, control: control, end: end, at: CGFloat($0) / CGFloat(count)) }
    }

    /// A bend carried along when an end of the line moves: the control point keeps its place
    /// relative to the line, so the arc turns and stretches with it instead of staying behind.
    static func carriedControl(
        _ control: CGPoint,
        from old: (start: CGPoint, end: CGPoint),
        to new: (start: CGPoint, end: CGPoint)
    ) -> CGPoint {
        let u = CGPoint(x: old.end.x - old.start.x, y: old.end.y - old.start.y)
        let length = u.x * u.x + u.y * u.y
        guard length > 0.0001 else { return control }
        let dx = control.x - old.start.x
        let dy = control.y - old.start.y
        let along = (dx * u.x + dy * u.y) / length
        let across = (-dx * u.y + dy * u.x) / length

        let v = CGPoint(x: new.end.x - new.start.x, y: new.end.y - new.start.y)
        return CGPoint(
            x: new.start.x + along * v.x - across * v.y,
            y: new.start.y + along * v.y + across * v.x
        )
    }

    /// Where the button that turns the heads sits: beside the middle of the line, on the side away
    /// from its bend (above a straight one), `offset` points clear of it.
    static func headsButtonCentre(start: CGPoint, end: CGPoint, bentMiddle: CGPoint?, offset: CGFloat) -> CGPoint {
        let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let length = max(hypot(end.x - start.x, end.y - start.y), 0.0001)
        var normal = CGPoint(x: (end.y - start.y) / length, y: -(end.x - start.x) / length)
        if let bentMiddle {
            if (bentMiddle.x - middle.x) * normal.x + (bentMiddle.y - middle.y) * normal.y > 0 {
                normal = CGPoint(x: -normal.x, y: -normal.y)
            }
        } else if normal.y > 0 {
            normal = CGPoint(x: -normal.x, y: -normal.y)
        }
        return CGPoint(x: middle.x + normal.x * offset, y: middle.y + normal.y * offset)
    }

    /// The handle a resize cursor should picture on a turned box: the handle's own direction
    /// turned by the box's angle and rounded to the nearest of the eight.
    static func screenHandle(_ handle: Handle, turnedBy angle: CGFloat) -> Handle {
        let order: [Handle] = [.right, .bottomRight, .bottom, .bottomLeft, .left, .topLeft, .top, .topRight]
        guard let index = order.firstIndex(of: handle) else { return handle }
        let steps = Int((angle / (.pi / 4)).rounded())
        return order[((index + steps) % 8 + 8) % 8]
    }

    // MARK: - Recording effects

    /// The mouse (AppKit screen coordinates) as a fraction of the recorded area, origin top left
    /// — how the event timeline stores positions. `nil` outside the area: a click there is not in
    /// the video.
    static func normalized(mouse: CGPoint, in area: CGRect) -> CGPoint? {
        guard area.width > 0, area.height > 0 else { return nil }
        let x = (mouse.x - area.minX) / area.width
        let y = (area.maxY - mouse.y) / area.height
        guard (0 ... 1).contains(x), (0 ... 1).contains(y) else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// A timeline fraction as a point in a layer of `size` — Core Animation's coordinates, origin
    /// bottom left, the same in the export and in the preview.
    static func layerPoint(_ normalized: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: normalized.x * size.width, y: (1 - normalized.y) * size.height)
    }

    /// The part of the recorded `area` a zoom mark will show, in AppKit screen coordinates: the
    /// area shrunk `scale` times, centred on the cursor and pulled back inside the area — the same
    /// rule `zoomOffset` applies at export, so the outline shown while recording is what the video
    /// will zoom to.
    static func zoomPreviewRect(cursor: CGPoint, area: CGRect, scale: CGFloat) -> CGRect {
        let size = CGSize(width: area.width / scale, height: area.height / scale)
        let x = min(max(cursor.x - size.width / 2, area.minX), area.maxX - size.width)
        let y = min(max(cursor.y - size.height / 2, area.minY), area.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// The shift that, applied after scaling by `scale` around the middle of a layer of `size`,
    /// brings `center` (layer coordinates) to the middle. The centre is first pulled in far enough
    /// that the zoomed picture still covers the whole frame — no empty edge ever slides in.
    static func zoomOffset(center: CGPoint, scale: CGFloat, size: CGSize) -> CGPoint {
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)
        let reachX = size.width / 2 * (1 - 1 / scale)
        let reachY = size.height / 2 * (1 - 1 / scale)
        let clamped = CGPoint(
            x: min(max(center.x, middle.x - reachX), middle.x + reachX),
            y: min(max(center.y, middle.y - reachY), middle.y + reachY)
        )
        return CGPoint(x: -scale * (clamped.x - middle.x), y: -scale * (clamped.y - middle.y))
    }

    // MARK: - The notch

    /// The recording pill tucked around the camera notch, in AppKit screen coordinates: as tall as
    /// the menu bar, the notch in the middle and a wing either side for the dot and the time.
    /// `extraHeight` grows it downwards for the buttons when the cursor comes near.
    ///
    /// Only the widths of the areas beside the notch are used — `auxiliaryTopLeftArea` and
    /// `auxiliaryTopRightArea` — so the answer doesn't depend on which coordinate space those
    /// rectangles come in. `nil` on a screen without a notch.
    static func notchPillFrame(
        screenFrame: CGRect,
        leftAreaWidth: CGFloat?,
        rightAreaWidth: CGFloat?,
        topInset: CGFloat,
        wing: CGFloat = 64,
        extraHeight: CGFloat = 0,
        minimumWidth: CGFloat = 0
    ) -> CGRect? {
        guard topInset > 0, let leftAreaWidth, let rightAreaWidth else { return nil }
        let notchMinX = screenFrame.minX + leftAreaWidth
        let notchMaxX = screenFrame.maxX - rightAreaWidth
        guard notchMaxX > notchMinX else { return nil }

        let width = max(notchMaxX - notchMinX + wing * 2, minimumWidth)
        let height = topInset + extraHeight
        return CGRect(
            x: (notchMinX + notchMaxX) / 2 - width / 2,
            y: screenFrame.maxY - height,
            width: width,
            height: height
        )
    }
}
