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
    static func handle(at point: CGPoint, of rect: CGRect, tolerance: CGFloat = 8) -> Handle? {
        guard rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return nil }

        let left = abs(point.x - rect.minX) <= tolerance
        let right = abs(point.x - rect.maxX) <= tolerance
        let top = abs(point.y - rect.minY) <= tolerance
        let bottom = abs(point.y - rect.maxY) <= tolerance

        switch (left, right, top, bottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        case (true, _, _, _): return .left
        case (_, true, _, _): return .right
        case (_, _, true, _): return .top
        case (_, _, _, true): return .bottom
        default: return rect.contains(point) ? .inside : nil
        }
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

    /// `rect` with the grabbed handle dragged to `point`, inside `bounds`.
    ///
    /// A corner keeps the opposite corner in place. An edge moves only itself — and with a fixed
    /// aspect it also resizes the other side around its middle, which is the only way an edge can
    /// keep the proportions.
    static func resized(
        _ rect: CGRect,
        dragging handle: Handle,
        to point: CGPoint,
        aspect: CGFloat?,
        within bounds: CGRect
    ) -> CGRect {
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

    /// Where the bar under a recording region goes, in view coordinates (origin top left): centred
    /// below the region, above it when there's no room, and inside its bottom edge when the region
    /// fills the screen.
    static func barOrigin(under rect: CGRect, barSize: CGSize, bounds: CGRect, gap: CGFloat = 12) -> CGPoint {
        let x = min(
            max(bounds.minX + gap, rect.midX - barSize.width / 2),
            bounds.maxX - gap - barSize.width
        )

        let below = rect.maxY + gap
        if below + barSize.height <= bounds.maxY - gap {
            return CGPoint(x: x, y: below)
        }
        let above = rect.minY - gap - barSize.height
        if above >= bounds.minY + gap {
            return CGPoint(x: x, y: above)
        }
        return CGPoint(x: x, y: rect.maxY - gap * 2 - barSize.height)
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
