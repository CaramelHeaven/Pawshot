import AppKit
import Carbon.HIToolbox
import os

@MainActor
protocol SelectionViewDelegate: AnyObject {
    /// A rectangle in view coordinates: origin at the top left, points, not pixels. `windowID` is
    /// set when a whole window was picked.
    func selectionView(_ view: SelectionView, didSelect rect: CGRect, windowID: CGWindowID?)
    func selectionViewDidCancel(_ view: SelectionView)
    /// M, S or X on the recording overlay: a setting that belongs to every screen, not to one.
    func selectionView(_ view: SelectionView, didToggle option: RecordingOverlayKey)
    /// The mode changed on one screen, and every other overlay has to follow.
    func selectionView(_ view: SelectionView, didSwitchTo mode: SelectionView.Mode)
}

/// The selection layer: dims everything around, draws the border and the coordinates badge.
final class SelectionView: NSView {
    /// What a click means right now.
    ///
    /// Space toggles between the two, the way ⌘⇧4 does in the system screenshot tool: drag a
    /// region, or point at a window and take it whole.
    enum Mode {
        case region
        case window
    }

    weak var delegate: SelectionViewDelegate?

    private(set) var mode: Mode = .region

    /// Windows as they were when the screen was frozen, front to back, in global coordinates.
    var windows: [CapturedWindow] = []

    /// The screen origin in global CoreGraphics coordinates — so the user sees the familiar screen
    /// coordinates rather than the ones local to the view.
    var screenOrigin: CGPoint = .zero

    /// The frozen screen frame underneath the dimming. A ready-made `NSImage` rather than a
    /// `CGImage`: the view has `isFlipped = true` and AppKit takes care of flipping the axis — but
    /// only inside `draw(in:)`, see the drawing below. Built once from the outside, not on every
    /// redraw.
    var background: NSImage? {
        didSet { needsDisplay = true }
    }

    /// The same frozen frame in pixels, for the loupe and for sizes in pixels of the file.
    var frameImage: CGImage?
    /// Pixels per point of this display.
    var scale: CGFloat = 1

    /// The key hints along the bottom, for the first few captures.
    var showsHints = false

    /// The 8× loupe, toggled with M for the rest of this capture.
    private var showsLoupe = false

    /// A screenshot ends on mouse up; a recording region stays to be adjusted and starts on ↩.
    var purpose: OverlayPurpose = .screenshot {
        didSet { needsDisplay = true }
    }

    /// The region last recorded on this display, drawn dashed while there is no new one. ↩ takes it.
    var ghost: CGRect? {
        didSet { needsDisplay = true }
    }

    /// Whether the file gets the display's own pixels (2x on Retina) or one pixel per point (1x).
    var nativeResolution = true {
        didSet { needsDisplay = true }
    }

    /// The proportions a recording region is held to.
    private(set) var aspect: AspectLock = .free
    private var sizeInput = SizeInput()
    /// What the current drag does to an existing recording region: move it or pull a handle.
    private var grabbedHandle: SelectionGeometry.Handle?
    private var grabbedSelection: CGRect?
    private var grabPoint: CGPoint?
    private var highlightedWindowID: CGWindowID?
    /// A press that landed on the sound bar: its drag and release are not a region either.
    private var ignoresBarClick = false

    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var cursorPoint: CGPoint?
    private var trackingArea: NSTrackingArea?
    /// The window under the cursor, in view coordinates.
    private var highlightedWindow: CGRect?

    private let dimColor = NSColor.black.withAlphaComponent(0.35)
    private static let logger = Logger(subsystem: "com.caramelheaven.pawshot", category: "overlay")

    /// Windows in Tahoe have strongly rounded corners, and the system gives no way to read another
    /// app's radius. A square hole around a rounded window left bright wedges of wallpaper in its
    /// corners; this constant rounds the hole to match. Tuned by eye.
    private static let windowCornerRadius: CGFloat = 16
    private static let loupeRadiusInPixels = 7
    private static let loupeZoom: CGFloat = 8

    /// Coordinates run top to bottom — the same way ScreenCaptureKit expects them.
    override var isFlipped: Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    /// The overlay pops up on top of another app, and the very first click has to start a
    /// selection instead of merely activating the window.
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    func reset() {
        dragStart = nil
        selection = nil
        cursorPoint = nil
        highlightedWindow = nil
        highlightedWindowID = nil
        grabbedHandle = nil
        grabbedSelection = nil
        grabPoint = nil
        sizeInput.clear()
        needsDisplay = true
    }

    /// Pixels per point of the file being recorded.
    var outputScale: CGFloat {
        nativeResolution ? scale : 1
    }

    /// The recording region as it stands — a fresh selection, or else the ghost of the last one.
    var recordingRegion: CGRect? {
        if let selection, !SelectionGeometry.isTooSmall(selection) {
            return selection
        }
        return dragStart == nil ? ghost : nil
    }

    /// Starts the recording with what is on screen: the window under the cursor in window mode,
    /// otherwise the region. ↩, R and the Record button all end here.
    func commitRecording() {
        if mode == .window {
            guard let highlightedWindow else { return }
            delegate?.selectionView(self, didSelect: highlightedWindow, windowID: highlightedWindowID)
            return
        }
        guard let region = recordingRegion else { return }
        delegate?.selectionView(self, didSelect: region, windowID: nil)
    }

    /// Follows a mode switch made on another screen — the overlays are separate windows, but the
    /// mode is one for the whole capture.
    func apply(mode: Mode) {
        guard mode != self.mode else { return }

        self.mode = mode
        dragStart = nil
        selection = nil
        updateHighlight()
        window?.invalidateCursorRects(for: self)
        // Cursor rects only take effect on the next mouse event, and the whole point here is that
        // the switch is visible while the hand is still.
        applyCursor()
        needsDisplay = true
    }

    /// Puts the cursor where it actually is, without waiting for it to move.
    ///
    /// Everything the overlay shows — the coordinates badge, the window highlight — hangs off
    /// `cursorPoint`, and that used to be filled in only by `mouseMoved`. Until the hand nudged
    /// the mouse, the screen looked dead.
    func syncToCurrentMouseLocation() {
        guard let screenFrame = window?.screen?.frame else { return }

        cursorPoint = SelectionGeometry.viewPoint(
            forMouse: NSEvent.mouseLocation,
            on: screenFrame
        )
        updateHighlight()
        applyCursor()
        needsDisplay = true
    }

    func applyCursor() {
        (mode == .window ? Self.cameraCursor : Self.crosshairCursor).set()
    }

    // MARK: - Cursor and tracking

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: mode == .window ? Self.cameraCursor : Self.crosshairCursor)
    }

    /// Renders the camera cursor ahead of time.
    ///
    /// `cameraCursor` is lazy, and rendering an SF Symbol into an `NSCursor` is not free — without
    /// this the bill lands on the first press of space, which is exactly the moment that has to
    /// feel instant. Called at launch, together with the capture warm-up.
    static func prepareCursors() {
        _ = cameraCursor
        _ = crosshairCursor
        OverlayHUD.prepare()
    }

    /// A crosshair with a gap in the middle, so the pixel being aimed at stays visible, and a dark
    /// outline under the white lines, so it reads on a white page and a black terminal alike. The
    /// system crosshair is one thin black line and disappears on anything dark.
    private static let crosshairCursor: NSCursor = {
        let side: CGFloat = 25
        let center = side / 2
        let gap: CGFloat = 3
        let image = NSImage(size: CGSize(width: side, height: side), flipped: false) { _ in
            let path = NSBezierPath()
            path.move(to: CGPoint(x: center, y: 1))
            path.line(to: CGPoint(x: center, y: center - gap))
            path.move(to: CGPoint(x: center, y: center + gap))
            path.line(to: CGPoint(x: center, y: side - 1))
            path.move(to: CGPoint(x: 1, y: center))
            path.line(to: CGPoint(x: center - gap, y: center))
            path.move(to: CGPoint(x: center + gap, y: center))
            path.line(to: CGPoint(x: side - 1, y: center))
            path.lineCapStyle = .round

            NSColor.black.withAlphaComponent(0.65).setStroke()
            path.lineWidth = 3
            path.stroke()
            NSColor.white.setStroke()
            path.lineWidth = 1.25
            path.stroke()
            return true
        }

        return NSCursor(image: image, hotSpot: CGPoint(x: center, y: center))
    }()

    /// The camera cursor of the window mode. White, because it lives over a dimmed screen.
    private static let cameraCursor: NSCursor = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        let image = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: "Capture window")?
            .withSymbolConfiguration(configuration)
            ?? NSImage(size: CGSize(width: 22, height: 22))

        return NSCursor(
            image: image,
            hotSpot: CGPoint(x: image.size.width / 2, y: image.size.height / 2)
        )
    }()

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cursorPoint = point
        updateHighlight()
        if OverlayHUD.barContains(point, in: self) {
            // Over the sound bar the hand is heading for a button, not drawing.
            NSCursor.arrow.set()
        } else {
            updateAdjustCursor(at: point)
        }
        needsDisplay = true
    }

    /// Over a recording region the cursor says what a press would do: a resize arrow on an edge
    /// or a corner, an open hand inside, the crosshair everywhere else.
    private func updateAdjustCursor(at point: CGPoint) {
        guard purpose == .recording, mode == .region, let selection, !selection.isEmpty else { return }

        let handle = SelectionGeometry.handle(at: point, of: selection)
        let position: NSCursor.FrameResizePosition? = switch handle {
        case .topLeft: .topLeft
        case .top: .top
        case .topRight: .topRight
        case .right: .right
        case .bottomRight: .bottomRight
        case .bottom: .bottom
        case .bottomLeft: .bottomLeft
        case .left: .left
        case .inside, nil: nil
        }

        if let position {
            NSCursor.frameResize(position: position, directions: .all).set()
        } else if handle == .inside {
            NSCursor.openHand.set()
        } else {
            applyCursor()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // A click on the sound bar belongs to its buttons. If one ever falls through to here it
        // must not start a new region and wipe the one drawn — and it is worth a log line, since
        // it means the bar lost a click.
        if OverlayHUD.barContains(point, in: self) {
            Self.logger.error("a click on the sound bar reached the overlay at \(Int(point.x), privacy: .public), \(Int(point.y), privacy: .public)")
            ignoresBarClick = true
            return
        }
        cursorPoint = point

        guard mode == .region else {
            // In window mode a press picks what is under the cursor; there is nothing to drag.
            updateHighlight()
            needsDisplay = true
            return
        }

        // A recording region that is already there: a press on it moves it or pulls a handle, a
        // press elsewhere starts a new one.
        if purpose == .recording, let selection, !selection.isEmpty,
           let handle = SelectionGeometry.handle(at: point, of: selection)
        {
            grabbedHandle = handle
            grabbedSelection = selection
            grabPoint = point
            if handle == .inside {
                NSCursor.closedHand.set()
            }
            return
        }

        dragStart = point
        selection = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .region, !ignoresBarClick else { return }
        let point = convert(event.locationInWindow, from: nil)
        cursorPoint = point

        if let grabbedHandle, let grabbedSelection, let grabPoint {
            selection = grabbedHandle == .inside
                ? SelectionGeometry.moved(
                    grabbedSelection,
                    by: CGSize(width: point.x - grabPoint.x, height: point.y - grabPoint.y),
                    within: bounds
                )
                : SelectionGeometry.resized(
                    grabbedSelection,
                    dragging: grabbedHandle,
                    to: point,
                    aspect: aspect.ratio,
                    within: bounds
                )
            needsDisplay = true
            return
        }

        guard let dragStart else { return }
        if purpose == .recording {
            selection = SelectionGeometry.rect(from: dragStart, to: point, aspect: aspect.ratio, within: bounds)
        } else {
            // The drag can run past the screen edge — clip it to our own bounds.
            selection = SelectionGeometry.rect(from: dragStart, to: point).intersection(bounds)
        }
        needsDisplay = true
    }

    override func mouseUp(with _: NSEvent) {
        if ignoresBarClick {
            ignoresBarClick = false
            return
        }
        if purpose == .recording, mode == .region {
            finishAdjusting()
            return
        }

        defer { reset() }

        if mode == .window {
            guard let highlightedWindow else {
                delegate?.selectionViewDidCancel(self)
                return
            }
            delegate?.selectionView(self, didSelect: highlightedWindow, windowID: highlightedWindowID)
            return
        }

        guard let selection, !SelectionGeometry.isTooSmall(selection) else {
            delegate?.selectionViewDidCancel(self)
            return
        }
        delegate?.selectionView(self, didSelect: selection, windowID: nil)
    }

    /// Mouse up on the recording overlay leaves the region alive. A click that drew nothing drops
    /// it, which brings the ghost of the last one back.
    private func finishAdjusting() {
        if grabbedHandle == nil, let selection, SelectionGeometry.isTooSmall(selection) {
            self.selection = nil
        }
        if grabbedHandle == .inside {
            NSCursor.openHand.set()
        }
        dragStart = nil
        grabbedHandle = nil
        grabbedSelection = nil
        grabPoint = nil
        needsDisplay = true
    }

    override func rightMouseDown(with _: NSEvent) {
        reset()
        delegate?.selectionViewDidCancel(self)
    }

    // MARK: - Keyboard

    /// Space toggles region ↔ window, the way it does in the system screenshot tool. Every other
    /// key is passed on, so Esc keeps reaching `cancelOperation`.
    override func keyDown(with event: NSEvent) {
        if purpose == .recording, handleRecordingKey(event) {
            return
        }

        // M is read off the physical key, like every letter in the app: on ЙЦУКЕН it prints "ь".
        if purpose == .screenshot, mode == .region, KeyboardLayout.latinCharacter(for: event)?.lowercased() == "m" {
            showsLoupe.toggle()
            OverlayHUD.hints.loupeIsOn = showsLoupe
            needsDisplay = true
            return
        }

        guard event.charactersIgnoringModifiers == " " else {
            return super.keyDown(with: event)
        }

        let next: Mode = mode == .region ? .window : .region
        apply(mode: next)
        OverlayHUD.hints.mode = next
        delegate?.selectionView(self, didSwitchTo: next)
    }

    /// The recording overlay's keys. Returns `false` for anything it doesn't own, so Space and
    /// Esc keep their usual meaning.
    private func handleRecordingKey(_ event: NSEvent) -> Bool {
        if event.keyCode == UInt16(kVK_Delete), !sizeInput.isEmpty {
            sizeInput.deleteBackward()
            needsDisplay = true
            return true
        }
        // Digits, and a separator once digits are there: a size is being typed.
        if mode == .region, let typed = KeyboardLayout.latinCharacter(for: event)?.first,
           typed.isNumber || !sizeInput.isEmpty, sizeInput.type(typed)
        {
            needsDisplay = true
            return true
        }

        switch RecordingOverlayKey.action(for: event) {
        case .start:
            if !sizeInput.isEmpty {
                applyTypedSize()
            } else {
                commitRecording()
            }
        case .aspect:
            guard mode == .region else { return true }
            aspect = aspect.next
            if let ratio = aspect.ratio, let selection, !selection.isEmpty {
                self.selection = SelectionGeometry.applying(aspect: ratio, to: selection, within: bounds)
            }
            needsDisplay = true
        case .scale:
            // One pixel per point is all a non-Retina display has; there is nothing to switch.
            guard scale > 1 else { return true }
            nativeResolution.toggle()
            delegate?.selectionView(self, didToggle: .scale)
        case let option?:
            delegate?.selectionView(self, didToggle: option)
        case nil:
            return false
        }
        return true
    }

    /// ↩ after typing `1920x1080`: a region of exactly that many pixels of the file, centred on the
    /// current region or the cursor. A size bigger than the display is dropped.
    private func applyTypedSize() {
        defer {
            sizeInput.clear()
            needsDisplay = true
        }
        guard let size = sizeInput.size else { return }

        let center = selection.flatMap { $0.isEmpty ? nil : CGPoint(x: $0.midX, y: $0.midY) }
            ?? cursorPoint
            ?? CGPoint(x: bounds.midX, y: bounds.midY)
        guard let exact = SelectionGeometry.exactRect(
            pixelWidth: size.width,
            pixelHeight: size.height,
            outputScale: outputScale,
            around: center,
            within: bounds
        ) else { return }

        aspect = .free
        selection = exact
    }

    override func cancelOperation(_: Any?) {
        // A size half typed goes first: one Esc must not throw the whole region away.
        if !sizeInput.isEmpty {
            sizeInput.clear()
            needsDisplay = true
            return
        }
        reset()
        delegate?.selectionViewDidCancel(self)
    }

    // MARK: - Drawing

    override func draw(_: CGRect) {
        // `draw(in:)` only: the variant with operation and fraction ignores the axis flip and puts
        // the frame upside down in this flipped view. The editor canvas draws its shot the same
        // way — its view is flipped too.
        background?.draw(in: bounds)

        dimColor.setFill()

        if mode == .window {
            drawWindowHighlight()
        } else if let selection, !selection.isEmpty {
            let path = NSBezierPath(rect: bounds)
            path.appendRect(selection)
            path.windingRule = .evenOdd
            path.fill()

            drawBorder(around: selection)
        } else {
            bounds.fill()
            if purpose == .recording, dragStart == nil, let ghost {
                drawGhost(ghost)
            }
        }

        if mode == .region, purpose == .screenshot {
            drawLoupe()
        }
        layOutHUD()
    }

    /// The hole around the window under the cursor, rounded to match the window, tinted with the
    /// paw colour so it reads as "this one" and not just "not dimmed".
    private func drawWindowHighlight() {
        guard let highlightedWindow, !highlightedWindow.isEmpty else {
            bounds.fill()
            return
        }

        let radius = Self.windowCornerRadius
        let hole = NSBezierPath(roundedRect: highlightedWindow, xRadius: radius, yRadius: radius)
        let dimming = NSBezierPath(rect: bounds)
        dimming.append(hole)
        dimming.windingRule = .evenOdd
        dimming.fill()

        Tokens.pawNSColor.withAlphaComponent(0.14).setFill()
        hole.fill()

        Tokens.pawNSColor.setStroke()
        let outline = NSBezierPath(
            roundedRect: highlightedWindow.insetBy(dx: 1, dy: 1),
            xRadius: radius - 1,
            yRadius: radius - 1
        )
        outline.lineWidth = 2
        outline.stroke()
    }

    private func drawBorder(around rect: CGRect) {
        // Two lines: dark on the outside, light on the inside — the border stays visible both on
        // a white page and on a dark terminal.
        NSColor.black.withAlphaComponent(0.6).setStroke()
        let outer = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
        outer.lineWidth = 1
        outer.stroke()

        NSColor.white.setStroke()
        let inner = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
        inner.lineWidth = 1
        inner.stroke()

        drawCornerBrackets(around: rect.insetBy(dx: -1.5, dy: -1.5))
    }

    /// The last recorded region, dashed: "↩ records this again".
    private func drawGhost(_ rect: CGRect) {
        let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1.5
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.black.withAlphaComponent(0.5).setStroke()
        path.stroke()
        NSColor.white.withAlphaComponent(0.75).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// The frame corners of the app icon on the selection: the selection reads as Pawshot's.
    /// Same double trick as the border — a dark stroke under the white one. Red when the region
    /// is for a recording.
    private func drawCornerBrackets(around rect: CGRect) {
        let path = NSBezierPath()
        for bracket in SelectionGeometry.cornerBrackets(for: rect, armLength: 16) {
            guard let first = bracket.first else { continue }
            path.move(to: first)
            for point in bracket.dropFirst() {
                path.line(to: point)
            }
        }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        NSColor.black.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 5.5
        path.stroke()

        (purpose == .recording ? NSColor.systemRed : NSColor.white).setStroke()
        path.lineWidth = 3.5
        path.stroke()
    }

    /// 15 × 15 pixels of the frozen frame around the cursor, eight times bigger, with a grid, the
    /// middle pixel framed and its colour underneath.
    private func drawLoupe() {
        guard showsLoupe, let cursorPoint, let frameImage else { return }

        let imageSize = CGSize(width: frameImage.width, height: frameImage.height)
        let pixel = SelectionGeometry.pixel(under: cursorPoint, scale: scale, imagePixelSize: imageSize)
        let sample = SelectionGeometry.loupeSampleRect(
            around: pixel,
            radius: Self.loupeRadiusInPixels,
            imagePixelSize: imageSize
        )
        guard let patch = frameImage.cropping(to: sample), let context = NSGraphicsContext.current?.cgContext
        else { return }

        let cell = Self.loupeZoom
        let diameter = CGFloat(Self.loupeRadiusInPixels * 2 + 1) * cell
        let labelHeight: CGFloat = 22
        let origin = SelectionGeometry.loupeOrigin(
            cursor: cursorPoint,
            loupeSize: CGSize(width: diameter, height: diameter + labelHeight),
            bounds: bounds
        )
        let circle = CGRect(origin: origin, size: CGSize(width: diameter, height: diameter))

        context.saveGState()
        NSBezierPath(ovalIn: circle).addClip()
        context.interpolationQuality = .none
        // The view is flipped and the image isn't: draw it upside down, into an upside-down box.
        context.translateBy(x: 0, y: circle.maxY + circle.minY)
        context.scaleBy(x: 1, y: -1)
        context.draw(patch, in: CGRect(
            x: circle.minX,
            y: circle.minY,
            width: CGFloat(patch.width) * cell,
            height: CGFloat(patch.height) * cell
        ))
        context.restoreGState()

        drawLoupeGrid(in: circle, cell: cell)

        // The pixel under the cursor, wherever the sample slid to at the edge of the frame.
        let marked = CGRect(
            x: circle.minX + (pixel.x - sample.minX) * cell,
            y: circle.minY + (pixel.y - sample.minY) * cell,
            width: cell,
            height: cell
        )
        Tokens.pawNSColor.setStroke()
        let mark = NSBezierPath(rect: marked)
        mark.lineWidth = 1.5
        mark.stroke()

        NSColor.white.setStroke()
        let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 1, dy: 1))
        ring.lineWidth = 2
        ring.stroke()

        drawHexLabel(Self.hex(of: patch, at: CGPoint(x: pixel.x - sample.minX, y: pixel.y - sample.minY)),
                     below: circle, height: labelHeight)
    }

    private func drawLoupeGrid(in circle: CGRect, cell: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: circle).addClip()
        NSColor.black.withAlphaComponent(0.25).setFill()
        var offset = cell
        while offset < circle.width {
            CGRect(x: circle.minX + offset, y: circle.minY, width: 0.5, height: circle.height).fill()
            CGRect(x: circle.minX, y: circle.minY + offset, width: circle.width, height: 0.5).fill()
            offset += cell
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawHexLabel(_ text: String, below circle: CGRect, height: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let plate = CGRect(
            x: circle.midX - size.width / 2 - 8,
            y: circle.maxY + 4,
            width: size.width + 16,
            height: height - 4
        )
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: plate, xRadius: plate.height / 2, yRadius: plate.height / 2).fill()
        (text as NSString).draw(
            at: CGPoint(x: plate.midX - size.width / 2, y: plate.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    /// The colour of one pixel of an image, as `#RRGGBB`, read by drawing that pixel into a 1×1
    /// sRGB bitmap.
    private static func hex(of image: CGImage, at pixel: CGPoint) -> String {
        guard
            let single = image.cropping(to: CGRect(origin: pixel, size: CGSize(width: 1, height: 1))),
            let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return "" }

        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(single, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return "" }

        return String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2])
    }

    // MARK: - Badge and hints

    /// Moves the shared glass badge and hints into this view and places them. Only the view under
    /// the cursor hosts them; the others give them up.
    private func layOutHUD() {
        guard let cursorPoint else { return }

        let badge = OverlayHUD.badgeHost
        let (primary, secondary) = badgeText(for: cursorPoint)
        OverlayHUD.badge.primary = primary
        OverlayHUD.badge.secondary = secondary
        if badge.superview !== self {
            addSubview(badge)
        }
        let badgeSize = badge.fittingSize
        badge.frame = CGRect(
            origin: SelectionGeometry.badgeOrigin(cursor: cursorPoint, badgeSize: badgeSize, bounds: bounds),
            size: badgeSize
        )

        layOutRecordingBar()

        let hints = OverlayHUD.hintsHost
        guard showsHints else {
            if hints.superview === self {
                hints.removeFromSuperview()
            }
            return
        }
        if hints.superview !== self {
            addSubview(hints)
        }
        let hintsSize = hints.fittingSize
        hints.frame = CGRect(
            x: (bounds.width - hintsSize.width) / 2,
            y: bounds.height - hintsSize.height - 48,
            width: hintsSize.width,
            height: hintsSize.height
        )
    }

    /// The sound bar sits under the recording region, on the screen that has one. It is not
    /// shown while a region is being drawn: the hand is busy and the bar would jump around.
    private func layOutRecordingBar() {
        let bar = OverlayHUD.recordingBarHost
        guard
            purpose == .recording, mode == .region,
            dragStart == nil, grabbedHandle == nil,
            let region = recordingRegion
        else {
            if bar.superview === self {
                bar.removeFromSuperview()
            }
            return
        }

        if bar.superview !== self {
            addSubview(bar)
        }
        let size = bar.fittingSize
        bar.frame = CGRect(
            origin: SelectionGeometry.barOrigin(under: region, barSize: size, bounds: bounds),
            size: size
        )
    }

    /// What the badge says: the pixels the file will have, big — the number people actually care
    /// about — and where the cursor is, in points, small.
    private func badgeText(for cursor: CGPoint) -> (String, String) {
        let globalX = Int((screenOrigin.x + cursor.x).rounded())
        let globalY = Int((screenOrigin.y + cursor.y).rounded())
        let position = "\(globalX), \(globalY)"

        if purpose == .recording {
            return recordingBadgeText(position: position)
        }

        if mode == .window {
            guard let highlightedWindow else { return ("Click a window", "") }
            return (pixelSize(of: highlightedWindow), "")
        }

        guard let selection, !selection.isEmpty else { return (position, "") }
        return (pixelSize(of: selection), position)
    }

    /// `1920 × 1080 · 16:9 · 2x` — the file's pixels, the proportions when they are held, and the
    /// scale; or the size being typed.
    private func recordingBadgeText(position: String) -> (String, String) {
        if !sizeInput.isEmpty {
            return ("\(sizeInput.text)▏", sizeInput.size == nil ? "width × height" : "↩ apply")
        }

        let region: CGRect? = mode == .window ? highlightedWindow : recordingRegion
        guard let region else {
            return (mode == .window ? "Click a window" : position, "")
        }

        let size = SelectionGeometry.recordingPixelSize(of: region, scale: outputScale)
        let scaleLabel = nativeResolution && scale > 1 ? "\(Int(scale))x" : "1x"
        let parts = ["\(size.width) × \(size.height)", aspect.label, scaleLabel].compactMap(\.self)
        return (parts.joined(separator: " · "), mode == .window ? "" : position)
    }

    private func pixelSize(of rect: CGRect) -> String {
        let size = SelectionGeometry.pixelSize(of: rect, scale: scale)
        return "\(size.width) × \(size.height) px"
    }

    // MARK: - Window mode

    /// Finds the window under the cursor and remembers it in view coordinates.
    ///
    /// Windows come in global coordinates, the view works in its own — hence the shift by
    /// `screenOrigin`, the same one the badge uses for its readout.
    private func updateHighlight() {
        guard mode == .window, let cursorPoint else {
            highlightedWindow = nil
            highlightedWindowID = nil
            return
        }

        let global = CGPoint(
            x: screenOrigin.x + cursorPoint.x,
            y: screenOrigin.y + cursorPoint.y
        )
        let picked = WindowPicker.window(at: global, in: windows)
        highlightedWindow = picked.map { $0.frame.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y) }
        highlightedWindowID = picked?.windowID
    }
}
