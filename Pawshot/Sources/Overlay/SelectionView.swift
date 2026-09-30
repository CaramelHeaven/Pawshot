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
    /// Space toggles between the first two, the way ⌘⇧4 does in the system screenshot tool: drag
    /// a region, or point at a window and take it whole. The whole screen is the recording
    /// toolbar's third choice — what ⇧⌘4 records without any overlay.
    enum Mode {
        case region
        case window
        case screen
    }

    weak var delegate: SelectionViewDelegate?

    private(set) var mode: Mode = .region

    /// Windows as they were when the screen was frozen, front to back, in global coordinates.
    var windows: [CapturedWindow] = []

    /// The screen origin in global CoreGraphics coordinates — so the user sees the familiar screen
    /// coordinates rather than the ones local to the view.
    var screenOrigin: CGPoint = .zero

    /// The frozen frame in pixels, for the loupe. The picture itself is drawn under this view by
    /// `OverlayWindow.frameView`, once — this view draws only the dimming and what is on it, and
    /// is up before the frame arrives, over the live screen.
    var frameImage: CGImage? {
        didSet {
            if showsLoupe {
                needsDisplay = true
            }
        }
    }

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

    /// Zones to hide for the whole take, as fractions of the recording region (0…1, origin top
    /// left), so they follow the region when it moves. Drawn with H; the recording blurs them.
    private(set) var maskZones: [CGRect] = []
    /// H is on: a press inside the region draws a zone instead of moving the region.
    private(set) var isMarkingZones = false
    private var zoneStart: CGPoint?
    private var zoneDraft: CGRect?
    /// The mode the mouse went down in. A release in another one — Space pressed mid-drag — is
    /// not the end of that gesture, nor a click of the new mode.
    private var pressMode: Mode?
    /// Whether the badge was last laid out shown, for one log line per change.
    private var badgeShown: Bool?

    private var dragStart: CGPoint?
    /// A press beside a recording region is a new region only once the mouse has moved; until
    /// then, and after a plain click, the region that was there stays.
    private var isDrawing = false
    private var regionBeforeDrag: CGRect?
    private var selection: CGRect?
    /// The part of the recording region under the cursor, and whether the cursor is close enough
    /// for the grip pills to show. The view is redrawn only when one of them changes.
    private var hoveredHandle: SelectionGeometry.Handle?
    private var showsGrips = false
    /// The lines the dragged region is stuck to, drawn for as long as the drag lasts.
    private var snapGuides = SelectionGeometry.SnapGuides()
    /// The window the dragged region would take the size of if dropped now, in view coordinates.
    private var fitOffer: (frame: CGRect, windowID: CGWindowID)?
    /// The size the region had before it was dropped onto a window. Moving it again brings that
    /// size back; resizing it, or drawing another, forgets it.
    private var unfittedSize: CGSize?
    /// What stuck during the current drag, for the one log line of the gesture.
    private var stuckDuringDrag = false
    private var cursorPoint: CGPoint?
    private var trackingArea: NSTrackingArea?
    /// The window under the cursor, in view coordinates.
    private var highlightedWindow: CGRect?

    private let dimColor = NSColor.black.withAlphaComponent(0.35)
    private static var logger: Logger {
        .pawshot("overlay")
    }

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
        isDrawing = false
        regionBeforeDrag = nil
        hoveredHandle = nil
        showsGrips = false
        snapGuides = SelectionGeometry.SnapGuides()
        fitOffer = nil
        unfittedSize = nil
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

    /// The recording region as it stands.
    var recordingRegion: CGRect? {
        guard let selection, !SelectionGeometry.isTooSmall(selection) else { return nil }
        return selection
    }

    /// The region last recorded on this display comes back as the region itself: it can be moved,
    /// resized and recorded with ↩ as it stands. It used to be a dashed ghost that only ↩ took —
    /// a press inside it drew a new region instead of moving it.
    func restore(lastRegion: CGRect) {
        selection = lastRegion
        needsDisplay = true
    }

    /// Starts the recording with what is on screen: the window under the cursor in window mode,
    /// the whole screen in screen mode, otherwise the region. ↩, R and the Record button all end
    /// here.
    func commitRecording() {
        if mode == .screen {
            delegate?.selectionView(self, didSelect: bounds, windowID: nil)
            return
        }
        if mode == .window {
            guard let highlightedWindow else {
                Self.logger.notice("record asked with no window under the cursor")
                return
            }
            delegate?.selectionView(self, didSelect: highlightedWindow, windowID: highlightedWindowID)
            return
        }
        guard let region = recordingRegion else {
            Self.logger.notice("record asked with no region")
            return
        }
        delegate?.selectionView(self, didSelect: region, windowID: nil)
    }

    /// Follows a mode switch made on another screen — the overlays are separate windows, but the
    /// mode is one for the whole capture.
    func apply(mode: Mode) {
        guard mode != self.mode else { return }

        self.mode = mode
        // The region is kept: the toolbar switches modes back and forth, and coming back to
        // "region" with the region gone would cost the user their selection. Whatever gesture
        // was under way is dropped whole — half of it would carry into the new mode.
        cancelGesture()
        hoveredHandle = nil
        showsGrips = false
        if isMarkingZones, mode != .region {
            isMarkingZones = false
            Self.logger.notice("zones: marking off, the mode is no longer region")
            delegate?.selectionView(self, didToggle: .hideZone)
        }
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

    /// The cursor for where the mouse is — over a restored region that is the hand or an arrow,
    /// not the crosshair.
    func applyCursor() {
        Self.cursor(for: cursorKind(at: cursorPoint)).set()
    }

    /// Everything a press started — a region being drawn, a handle pulled, a zone — dropped
    /// without finishing it. The region stays as it was.
    private func cancelGesture() {
        if let grabbedSelection {
            selection = grabbedSelection
        } else if isDrawing {
            selection = regionBeforeDrag
        }
        dragStart = nil
        isDrawing = false
        regionBeforeDrag = nil
        grabbedHandle = nil
        grabbedSelection = nil
        grabPoint = nil
        zoneStart = nil
        zoneDraft = nil
        fitOffer = nil
        stuckDuringDrag = false
        snapGuides = SelectionGeometry.SnapGuides()
    }

    // MARK: - Cursor and tracking

    /// The whole view is one cursor rect — but with the cursor for where the mouse is now, not
    /// always the crosshair. The HUD's subviews move on every redraw and AppKit rebuilds the rects
    /// each time; a crosshair rect put the crosshair back over the resize arrow, which is why an
    /// edge was so hard to catch. Every path asks `cursorKind` now, so they can't disagree.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: Self.cursor(for: cursorKind(at: currentMousePoint)))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    /// What the cursor says about a press here.
    enum CursorKind: Equatable {
        case crosshair
        case camera
        case arrow
        case resize(SelectionGeometry.Handle)
        case openHand
        case closedHand
    }

    /// Over a recording region: a resize arrow on an edge or a corner, an open hand inside; while
    /// something is grabbed, that grab's cursor wherever the drag goes; the arrow over the sound
    /// bar; the crosshair — or the camera in window mode — everywhere else.
    nonisolated static func cursorKind(
        at point: CGPoint,
        selection: CGRect?,
        purpose: OverlayPurpose,
        mode: Mode,
        overBar: Bool,
        grabbed: SelectionGeometry.Handle?,
        markingZones: Bool = false
    ) -> CursorKind {
        if let grabbed {
            return grabbed == .inside ? .closedHand : .resize(grabbed)
        }
        if overBar {
            return .arrow
        }
        guard mode == .region else { return .camera }
        guard purpose == .recording, let selection, !selection.isEmpty,
              let handle = SelectionGeometry.handle(at: point, of: selection)
        else { return .crosshair }
        // Drawing zones: the middle draws, the rim still resizes.
        if handle == .inside, markingZones {
            return .crosshair
        }
        return handle == .inside ? .openHand : .resize(handle)
    }

    /// The glass badge by the cursor: on a screenshot, the size and where the cursor is. On the
    /// recording overlay the owner found it in the way (2026-09-30) — the size is written on a
    /// dragged edge anyway — so it shows only while a size is being typed, to show the digits.
    nonisolated static func showsBadge(purpose: OverlayPurpose, typingSize: Bool) -> Bool {
        purpose == .screenshot || typingSize
    }

    private func cursorKind(at point: CGPoint?) -> CursorKind {
        guard let point else { return mode == .region ? .crosshair : .camera }
        return Self.cursorKind(
            at: point,
            selection: selection,
            purpose: purpose,
            mode: mode,
            overBar: OverlayHUD.barContains(point, in: self),
            grabbed: grabbedHandle,
            markingZones: isMarkingZones
        )
    }

    private var currentMousePoint: CGPoint? {
        guard let window else { return nil }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(point) ? point : nil
    }

    private func updateCursor(at point: CGPoint) {
        Self.cursor(for: cursorKind(at: point)).set()
    }

    private static func cursor(for kind: CursorKind) -> NSCursor {
        switch kind {
        case .crosshair: crosshairCursor
        case .camera: cameraCursor
        case .arrow: .arrow
        case .openHand: .openHand
        case .closedHand: .closedHand
        case let .resize(handle):
            NSCursor.frameResize(position: resizePosition(handle), directions: .all)
        }
    }

    private static func resizePosition(_ handle: SelectionGeometry.Handle) -> NSCursor.FrameResizePosition {
        switch handle {
        case .topLeft: .topLeft
        case .top: .top
        case .topRight: .topRight
        case .right: .right
        case .bottomRight: .bottomRight
        case .bottom: .bottom
        case .bottomLeft: .bottomLeft
        case .left, .inside: .left
        }
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
        let image = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: String(localized: "Capture window"))?
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
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        OverlayDiagnostics.received("mouseMoved")
        let point = convert(event.locationInWindow, from: nil)
        OverlayHUD.noteMouse(at: point, in: self)
        // The key overlay hears the mouse on other screens too; the cursor there is not its call.
        guard bounds.contains(point) else { return }
        cursorPoint = point
        let highlighted = highlightedWindow
        updateHighlight()
        updateCursor(at: point)
        let hoverChanged = updateHover(at: point)
        // Only what the mouse changes is redrawn. With nothing drawn yet in region mode, a move
        // changes nothing under the dimming — only the glass badge, which is its own view — and
        // redrawing the whole screen for it was most of what made the crosshair lag. The grips
        // and the highlight of a recording region follow the same rule: they are redrawn when
        // the zone under the cursor changes, not on every move.
        if showsLoupe || highlightedWindow != highlighted || hoverChanged {
            needsDisplay = true
        } else {
            layOutHUD()
        }
    }

    /// The cursor left for another screen: nothing here is under it any more.
    override func mouseExited(with _: NSEvent) {
        // A point on a screen the cursor has left would pull the toolbar and the badge back here
        // on this screen's next redraw.
        cursorPoint = nil
        guard hoveredHandle != nil || showsGrips else { return }
        hoveredHandle = nil
        showsGrips = false
        needsDisplay = true
    }

    /// Which part of the recording region the cursor is over and whether the grips show. Returns
    /// whether either changed.
    private func updateHover(at point: CGPoint) -> Bool {
        var handle: SelectionGeometry.Handle?
        var near = false
        if purpose == .recording, mode == .region, let region = recordingRegion, !OverlayHUD.barContains(point, in: self) {
            handle = SelectionGeometry.handle(at: point, of: region)
            near = SelectionGeometry.isNear(point, to: region)
        }
        guard handle != hoveredHandle || near != showsGrips else { return false }
        hoveredHandle = handle
        showsGrips = near
        return true
    }

    /// The windows of this screen in view coordinates, front to back, cut to the screen: what
    /// the dragged region sticks to and what it can be dropped onto.
    private var windowFrames: [(frame: CGRect, windowID: CGWindowID)] {
        windows.compactMap { window in
            let frame = window.frame.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y).intersection(bounds)
            return frame.isEmpty ? nil : (frame, window.windowID)
        }
    }

    override func mouseDown(with event: NSEvent) {
        OverlayDiagnostics.received("mouseDown")
        let point = convert(event.locationInWindow, from: nil)
        // A click on the sound bar belongs to its buttons. If one ever falls through to here it
        // must not start a new region and wipe the one drawn — and it is worth a log line, since
        // it means the bar lost a click.
        if OverlayHUD.barContains(point, in: self) {
            Self.logger.error("a click on the toolbar reached the overlay at \(Int(point.x), privacy: .public), \(Int(point.y), privacy: .public)")
            ignoresBarClick = true
            return
        }
        // With the Options panel open, a click anywhere else only closes it — as a click beside
        // an open menu does.
        if OverlayHUD.recordingBar.optionsShown {
            Self.logger.notice("options closed by a click beside them")
            OverlayHUD.recordingBar.toggleOptions()
            ignoresBarClick = true
            return
        }
        cursorPoint = point
        pressMode = mode
        // The keys go where the hand is: ↩, H, the arrows and A act on the screen last pressed,
        // not on the one the cursor was on when the overlay came up. A non-activating panel takes
        // the keyboard without Pawshot becoming active.
        if purpose == .recording, let window, !window.isKeyWindow {
            window.makeKey()
            window.makeFirstResponder(self)
            let number = window.windowNumber
            Self.logger.notice("overlay window \(number, privacy: .public) takes the keyboard: pressed there")
        }

        guard mode == .region else {
            // In window mode a press picks what is under the cursor; there is nothing to drag.
            updateHighlight()
            needsDisplay = true
            return
        }

        // H is on: a press in the middle of the region starts a zone — the same middle the cursor
        // shows as the crosshair. The rim stays the region's, its edges and corners there to pull.
        if purpose == .recording, isMarkingZones, let region = recordingRegion,
           SelectionGeometry.handle(at: point, of: region) == .inside
        {
            zoneStart = point
            zoneDraft = nil
            return
        }

        // A recording region that is already there: a press on it moves it or pulls a handle, a
        // press elsewhere starts a new one — once the mouse moves.
        if purpose == .recording, let selection, !selection.isEmpty,
           let handle = SelectionGeometry.handle(at: point, of: selection)
        {
            grabbedHandle = handle
            grabbedSelection = selection
            grabPoint = point
            stuckDuringDrag = false
            updateCursor(at: point)
            needsDisplay = true
            return
        }

        dragStart = point
        if purpose == .recording {
            // The region stays until this press turns into a drag: a click beside it used to
            // wipe it on the spot.
            regionBeforeDrag = selection
            isDrawing = false
        } else {
            selection = .zero
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .region, !ignoresBarClick else { return }
        let point = convert(event.locationInWindow, from: nil)
        cursorPoint = point

        if let zoneStart, let region = recordingRegion {
            zoneDraft = SelectionGeometry.rect(from: zoneStart, to: point).intersection(region)
            needsDisplay = true
            return
        }

        if let grabbedHandle, let grabPoint {
            if grabbedHandle == .inside {
                move(to: point, grabbedAt: grabPoint, magnet: !event.modifierFlags.contains(.command))
            } else {
                resize(grabbedHandle, to: point, grabbedAt: grabPoint, modifiers: event.modifierFlags)
            }
            updateCursor(at: point)
            needsDisplay = true
            return
        }

        guard let dragStart else { return }
        if purpose == .recording {
            guard isDrawing || SelectionGeometry.isDrag(from: dragStart, to: point) else { return }
            isDrawing = true
            unfittedSize = nil
            selection = SelectionGeometry.rect(from: dragStart, to: point, aspect: aspect.ratio, within: bounds)
        } else {
            // The drag can run past the screen edge — clip it to our own bounds.
            selection = SelectionGeometry.rect(from: dragStart, to: point).intersection(bounds)
        }
        needsDisplay = true
    }

    /// The region dragged by its middle. It sticks to the visible edges of windows, to the edges
    /// of the screen and to its middle; and when its middle comes to the middle of a window, that
    /// window is offered: dropped there, the region takes the window's frame. ⌘ switches both off.
    ///
    /// A region that was fitted to a window goes back to the size it had as soon as it is really
    /// moved — past the drag threshold, so a click on it changes nothing.
    private func move(to point: CGPoint, grabbedAt grab: CGPoint, magnet: Bool) {
        guard var start = grabbedSelection else { return }
        if let size = unfittedSize {
            guard SelectionGeometry.isDrag(from: grab, to: point) else { return }
            start = SelectionGeometry.restored(size: size, grabbedAt: grab, in: start, within: bounds)
            grabbedSelection = start
            unfittedSize = nil
            Self.logger.notice("region unfitted: back to \(Int(size.width), privacy: .public)×\(Int(size.height), privacy: .public) pt")
        }

        var moved = SelectionGeometry.moved(
            start,
            by: CGSize(width: point.x - grab.x, height: point.y - grab.y),
            within: bounds
        )
        let offered = fitOffer?.windowID
        fitOffer = nil
        snapGuides = SelectionGeometry.SnapGuides()
        if magnet {
            let frames = windowFrames
            let rects = frames.map(\.frame)
            if let index = SelectionGeometry.fitCandidate(center: CGPoint(x: moved.midX, y: moved.midY), windows: rects) {
                fitOffer = frames[index]
            } else {
                let lines = SelectionGeometry.snapLines(windows: rects, bounds: bounds, around: moved)
                (moved, snapGuides) = SelectionGeometry.snapped(moving: moved, to: lines, within: bounds)
            }
        }
        if let fitOffer, fitOffer.windowID != offered {
            let id = fitOffer.windowID
            Self.logger.notice("fit offered: window \(id, privacy: .public)")
        }
        stuckDuringDrag = stuckDuringDrag || snapGuides != SelectionGeometry.SnapGuides()
        selection = moved
    }

    /// An edge or a corner dragged. ⇧ holds a corner to the proportions the region had, ⌥ grows
    /// it from its middle, ⌘ switches the magnet off. With proportions held — by ⇧ or by the A
    /// key — nothing sticks: the side that follows would leave the line anyway.
    private func resize(_ handle: SelectionGeometry.Handle, to point: CGPoint, grabbedAt grab: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard let start = grabbedSelection else { return }
        var target = SelectionGeometry.handleTarget(handle, of: start, grabbedAt: grab, mouse: point)
        let isCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight].contains(handle)
        var ratio = aspect.ratio
        if ratio == nil, isCorner, modifiers.contains(.shift), start.height > 0 {
            ratio = start.width / start.height
        }
        let fromCenter = modifiers.contains(.option)

        snapGuides = SelectionGeometry.SnapGuides()
        if !modifiers.contains(.command), ratio == nil, !fromCenter {
            let lines = SelectionGeometry.snapLines(windows: windowFrames.map(\.frame), bounds: bounds, around: start)
            (target, snapGuides) = SelectionGeometry.snapped(target, dragging: handle, to: lines)
        }
        stuckDuringDrag = stuckDuringDrag || snapGuides != SelectionGeometry.SnapGuides()
        unfittedSize = nil
        selection = SelectionGeometry.resized(
            start,
            dragging: handle,
            to: target,
            aspect: ratio,
            within: bounds,
            fromCenter: fromCenter
        )
    }

    override func mouseUp(with _: NSEvent) {
        if ignoresBarClick {
            ignoresBarClick = false
            return
        }
        let pressedIn = pressMode
        pressMode = nil
        if zoneStart != nil {
            finishZone()
            return
        }
        if purpose == .recording, pressedIn != mode {
            // Space or the toolbar switched the mode mid-press: the release ends nothing.
            Self.logger.notice("mouse up in another mode than the press: nothing done")
            cancelGesture()
            needsDisplay = true
            return
        }
        if purpose == .recording, mode == .region {
            // A press whose gesture was taken back meanwhile — Esc or H while a zone was being
            // drawn — has nothing to finish, and must not wipe the region either.
            guard grabbedHandle != nil || dragStart != nil else {
                Self.logger.notice("mouse up with no gesture left to finish: region kept")
                needsDisplay = true
                return
            }
            finishAdjusting()
            return
        }

        defer { reset() }

        if mode == .screen {
            // A click anywhere records the screen, the way it does in the system tool.
            commitRecording()
            return
        }
        if mode == .window {
            guard let highlightedWindow else {
                Self.logger.notice("cancel: no window under the click")
                delegate?.selectionViewDidCancel(self)
                return
            }
            delegate?.selectionView(self, didSelect: highlightedWindow, windowID: highlightedWindowID)
            return
        }

        guard let selection, !SelectionGeometry.isTooSmall(selection) else {
            Self.logger.notice("cancel: region too small")
            delegate?.selectionViewDidCancel(self)
            return
        }
        delegate?.selectionView(self, didSelect: selection, windowID: nil)
    }

    // MARK: - Zones to hide

    /// H, or the Options row: the next drags inside the region draw zones that are blurred in the
    /// video from the first frame to the last.
    func setMarkingZones(_ on: Bool, by source: String) {
        guard purpose == .recording else {
            Self.logger.error("zones: marking asked on a screenshot overlay (\(source, privacy: .public))")
            return
        }
        if on, mode != .region {
            let current = String(describing: mode)
            Self.logger.notice("zones: marking refused, zones are for a region and the mode is \(current, privacy: .public) (\(source, privacy: .public))")
            return
        }
        if on, recordingRegion == nil {
            Self.logger.notice("zones: marking refused, no region to hide a zone in (\(source, privacy: .public))")
            return
        }
        isMarkingZones = on
        zoneStart = nil
        zoneDraft = nil
        let count = maskZones.count
        Self.logger.notice("zones: marking \(on ? "on" : "off", privacy: .public) by \(source, privacy: .public), \(count, privacy: .public) zone(s)")
        needsDisplay = true
        delegate?.selectionView(self, didToggle: .hideZone)
    }

    func clearZones(because reason: String) {
        let count = maskZones.count
        maskZones = []
        zoneDraft = nil
        Self.logger.notice("zones: \(count, privacy: .public) cleared (\(reason, privacy: .public))")
        needsDisplay = true
        delegate?.selectionView(self, didToggle: .hideZone)
    }

    private func removeLastZone() {
        guard !maskZones.isEmpty else { return }
        maskZones.removeLast()
        let left = maskZones.count
        Self.logger.notice("zones: last one removed, \(left, privacy: .public) left")
        needsDisplay = true
        delegate?.selectionView(self, didToggle: .hideZone)
    }

    private func finishZone() {
        defer {
            zoneStart = nil
            zoneDraft = nil
            needsDisplay = true
        }
        guard let draft = zoneDraft, let region = recordingRegion else {
            Self.logger.notice("zones: a click with no drag drew nothing")
            return
        }
        guard let fractions = SelectionGeometry.zoneFractions(of: draft, in: region) else {
            Self.logger.notice("zones: too small to hide (\(Int(draft.width), privacy: .public)×\(Int(draft.height), privacy: .public) pt)")
            return
        }
        maskZones.append(fractions)
        let now = maskZones.count
        Self.logger.notice("zones: one added, \(now, privacy: .public) now (\(Int(draft.width), privacy: .public)×\(Int(draft.height), privacy: .public) pt)")
        delegate?.selectionView(self, didToggle: .hideZone)
    }

    /// Hatched paw colour over each zone, and the one being drawn.
    private func drawZones(in region: CGRect) {
        let zones = maskZones.map { SelectionGeometry.zone(fromFractions: $0, in: region) } + [zoneDraft].compactMap(\.self)
        for zone in zones {
            Tokens.pawNSColor.withAlphaComponent(0.28).setFill()
            zone.fill()
            let outline = NSBezierPath(rect: zone.insetBy(dx: 0.75, dy: 0.75))
            outline.lineWidth = 1.5
            outline.setLineDash([5, 3], count: 2, phase: 0)
            Tokens.pawNSColor.setStroke()
            outline.stroke()
        }
    }

    /// Mouse up on the recording overlay leaves the region alive. A click that drew nothing
    /// leaves the region that was there.
    ///
    /// An edge dragged onto its opposite leaves a region too small to grab again; it goes back to
    /// what it was before that drag. A region dropped while a window was offered takes that
    /// window's frame and remembers the size it had.
    private func finishAdjusting() {
        let handle = grabbedHandle
        var gesture: String
        switch handle {
        case .inside?:
            if let fitOffer, let dragged = selection {
                unfittedSize = dragged.size
                selection = fitOffer.frame
                gesture = "fitted to window \(fitOffer.windowID)"
            } else {
                gesture = "moved"
            }
        case let handle?:
            if let selection, SelectionGeometry.isTooSmall(selection) {
                self.selection = grabbedSelection
                gesture = "resize by \(handle) came to nothing (put back)"
            } else {
                gesture = "resized by \(handle)"
            }
        case nil:
            if isDrawing, let selection, !SelectionGeometry.isTooSmall(selection) {
                gesture = "drawn"
                // The zones were fractions of the region that is gone.
                if !maskZones.isEmpty {
                    clearZones(because: "a new region was drawn")
                }
            } else {
                selection = regionBeforeDrag
                gesture = regionBeforeDrag == nil ? "click (no region)" : "click beside (region kept)"
            }
        }
        if stuckDuringDrag {
            gesture += ", stuck to a line"
        }
        dragStart = nil
        isDrawing = false
        regionBeforeDrag = nil
        grabbedHandle = nil
        grabbedSelection = nil
        grabPoint = nil
        fitOffer = nil
        stuckDuringDrag = false
        snapGuides = SelectionGeometry.SnapGuides()
        if let cursorPoint {
            updateCursor(at: cursorPoint)
            _ = updateHover(at: cursorPoint)
        }
        needsDisplay = true
        let size = selection.map { "\(Int($0.width))×\(Int($0.height)) pt" } ?? "none"
        Self.logger.notice("region \(gesture, privacy: .public): \(size, privacy: .public)")
    }

    override func rightMouseDown(with _: NSEvent) {
        OverlayDiagnostics.received("rightMouseDown")
        Self.logger.notice("cancel: right click")
        reset()
        delegate?.selectionViewDidCancel(self)
    }

    // MARK: - Keyboard

    /// Space toggles region ↔ window, the way it does in the system screenshot tool. Every other
    /// key is passed on, so Esc keeps reaching `cancelOperation`.
    override func keyDown(with event: NSEvent) {
        OverlayDiagnostics.received("keyDown")
        if purpose == .recording, handleRecordingKey(event) {
            return
        }

        // M is read off the physical key, like every letter in the app: on ЙЦУКЕН it prints "ь".
        if purpose == .screenshot, mode == .region, KeyboardLayout.latinCharacter(for: event)?.lowercased() == "m" {
            showsLoupe.toggle()
            let loupe = showsLoupe ? "on" : "off"
            Self.logger.notice("loupe \(loupe, privacy: .public)")
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
        if event.keyCode == UInt16(kVK_Delete), !maskZones.isEmpty {
            removeLastZone()
            return true
        }
        // An arrow moves the region by a point, ten with ⇧; with ⌥ it moves the right and the
        // bottom edges instead.
        if mode == .region, let step = RecordingOverlayKey.arrow(for: event), let region = recordingRegion {
            let distance: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let resizing = event.modifierFlags.contains(.option)
            let nudged = SelectionGeometry.nudged(
                region,
                by: CGSize(width: step.width * distance, height: step.height * distance),
                resizing: resizing,
                within: bounds
            )
            selection = nudged
            unfittedSize = nil
            // One line per press, not per repeat of a held key.
            if !event.isARepeat {
                let what = resizing ? "resized" : "moved"
                Self.logger.notice(
                    "region \(what, privacy: .public) by an arrow: \(Int(nudged.width), privacy: .public)×\(Int(nudged.height), privacy: .public) pt at \(Int(nudged.minX), privacy: .public), \(Int(nudged.minY), privacy: .public)"
                )
            }
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

        let action = RecordingOverlayKey.action(for: event)
        // A held key repeats: H, P, M, S, X and A would flip back and forth at the repeat rate.
        if event.isARepeat, action != nil {
            return true
        }
        switch action {
        case .start:
            if !sizeInput.isEmpty {
                applyTypedSize()
            } else {
                commitRecording()
            }
        case .aspect:
            guard mode == .region else { return true }
            aspect = aspect.next
            let label = aspect.label ?? "free"
            Self.logger.notice("aspect → \(label, privacy: .public)")
            if let ratio = aspect.ratio, let selection, !selection.isEmpty {
                self.selection = SelectionGeometry.applying(aspect: ratio, to: selection, within: bounds)
                unfittedSize = nil
            }
            needsDisplay = true
        case .hideZone:
            setMarkingZones(!isMarkingZones, by: "H")
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
        let typed = sizeInput.text
        guard let size = sizeInput.size else {
            Self.logger.notice("typed size dropped: unreadable (\(typed, privacy: .public))")
            return
        }

        let center = selection.flatMap { $0.isEmpty ? nil : CGPoint(x: $0.midX, y: $0.midY) }
            ?? cursorPoint
            ?? CGPoint(x: bounds.midX, y: bounds.midY)
        guard let exact = SelectionGeometry.exactRect(
            pixelWidth: size.width,
            pixelHeight: size.height,
            outputScale: outputScale,
            around: center,
            within: bounds
        ) else {
            Self.logger.notice(
                "typed size dropped: \(size.width, privacy: .public)×\(size.height, privacy: .public) px is bigger than the display"
            )
            return
        }

        aspect = .free
        unfittedSize = nil
        selection = exact
        Self.logger.notice("typed size \(size.width, privacy: .public)×\(size.height, privacy: .public) px applied")
    }

    override func cancelOperation(_: Any?) {
        // A size half typed goes first: one Esc must not throw the whole region away.
        if !sizeInput.isEmpty {
            sizeInput.clear()
            needsDisplay = true
            return
        }
        // Then marking zones: one Esc ends it, the region stays.
        if purpose == .recording, isMarkingZones {
            setMarkingZones(false, by: "Esc")
            return
        }
        // Then the Options panel, the way Esc closes a menu before anything else.
        if purpose == .recording, OverlayHUD.recordingBar.optionsShown {
            Self.logger.notice("options closed by Esc")
            OverlayHUD.recordingBar.toggleOptions()
            return
        }
        Self.logger.notice("cancel: Esc")
        reset()
        delegate?.selectionViewDidCancel(self)
    }

    // MARK: - Drawing

    override func draw(_: CGRect) {
        OverlayDiagnostics.drew()
        let started = CACurrentMediaTime()
        defer { OverlayDiagnostics.drawFinished(took: CACurrentMediaTime() - started) }
        dimColor.setFill()

        if mode == .window {
            drawWindowHighlight()
        } else if mode == .screen {
            // The whole screen is what gets recorded: nothing is dimmed, and the red corners sit
            // on the screen's own.
            drawCornerBrackets(around: bounds.insetBy(dx: 4, dy: 4), hot: nil)
        } else if let selection, !selection.isEmpty {
            let path = NSBezierPath(rect: bounds)
            path.appendRect(selection)
            path.windingRule = .evenOdd
            path.fill()

            if let fitOffer {
                drawWindowOutline(fitOffer.frame)
            }
            let live = purpose == .recording
            let hot = live ? (grabbedHandle ?? hoveredHandle) : nil
            if hot == .inside, grabbedHandle == nil {
                // The middle under the cursor: a light veil says "this moves".
                NSColor.white.withAlphaComponent(0.07).setFill()
                selection.fill()
            }
            drawBorder(around: selection, hot: hot)
            if live {
                drawZones(in: selection)
                drawGrips(on: selection, hot: hot)
                drawSnapGuides()
                drawSizeOnTheDraggedEdge(of: selection)
            }
        } else {
            bounds.fill()
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

        drawWindowOutline(highlightedWindow)
    }

    /// "This window": the paw tint and the paw outline, rounded like the window. The window mode
    /// draws it under the cursor; a dragged recording region draws it on the window it would fit.
    private func drawWindowOutline(_ window: CGRect) {
        let radius = Self.windowCornerRadius
        Tokens.pawNSColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: window, xRadius: radius, yRadius: radius).fill()

        Tokens.pawNSColor.setStroke()
        let outline = NSBezierPath(
            roundedRect: window.insetBy(dx: 1, dy: 1),
            xRadius: radius - 1,
            yRadius: radius - 1
        )
        outline.lineWidth = 2
        outline.stroke()
    }

    /// The pills on the middles of the edges, shown while the cursor is near or something is
    /// grabbed: white, and red and bigger for the edge under the cursor.
    private func drawGrips(on rect: CGRect, hot: SelectionGeometry.Handle?) {
        guard showsGrips || grabbedHandle != nil else { return }
        for pill in SelectionGeometry.gripPills(for: rect, hot: hot) {
            let radius = min(pill.frame.width, pill.frame.height) / 2
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: pill.frame.insetBy(dx: -1, dy: -1), xRadius: radius + 1, yRadius: radius + 1).fill()
            (pill.handle == hot ? NSColor.systemRed : NSColor.white).setFill()
            NSBezierPath(roundedRect: pill.frame, xRadius: radius, yRadius: radius).fill()
        }
    }

    /// The lines the dragged region is stuck to, across the whole screen — only while it is
    /// dragged, so nothing of them is left on a region at rest.
    private func drawSnapGuides() {
        Tokens.pawNSColor.setFill()
        if let x = snapGuides.x {
            CGRect(x: x - 0.5, y: bounds.minY, width: 1, height: bounds.height).fill()
        }
        if let y = snapGuides.y {
            CGRect(x: bounds.minX, y: y - 0.5, width: bounds.width, height: 1).fill()
        }
    }

    /// While an edge or a corner is dragged: the pixels of the file along it, on a paw plate
    /// right beside it.
    private func drawSizeOnTheDraggedEdge(of rect: CGRect) {
        guard let handle = grabbedHandle, handle != .inside else { return }
        let size = SelectionGeometry.recordingPixelSize(of: rect, scale: outputScale)
        let text = switch handle {
        case .left, .right: "\(size.width) px"
        case .top, .bottom: "\(size.height) px"
        default: "\(size.width) × \(size.height)"
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.black.withAlphaComponent(0.85),
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let plateSize = CGSize(width: textSize.width + 12, height: textSize.height + 6)
        let plate = CGRect(
            origin: SelectionGeometry.edgeLabelOrigin(for: handle, of: rect, labelSize: plateSize, bounds: bounds),
            size: plateSize
        )
        Tokens.pawNSColor.setFill()
        NSBezierPath(roundedRect: plate, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: CGPoint(x: plate.minX + 6, y: plate.minY + 3), withAttributes: attributes)
    }

    private func drawBorder(around rect: CGRect, hot: SelectionGeometry.Handle?) {
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

        drawCornerBrackets(around: rect.insetBy(dx: -1.5, dy: -1.5), hot: hot)
    }

    /// The frame corners of the app icon on the selection: the selection reads as Pawshot's.
    /// Same double trick as the border — a dark stroke under the white one. Red when the region
    /// is for a recording, and the corner under the cursor grows: longer arms, a thicker line.
    private func drawCornerBrackets(around rect: CGRect, hot: SelectionGeometry.Handle?) {
        // In the order `cornerBrackets` returns them.
        let corners: [SelectionGeometry.Handle] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        let plain = SelectionGeometry.cornerBrackets(for: rect, armLength: 16)
        let grown = SelectionGeometry.cornerBrackets(for: rect, armLength: 26)

        for (index, corner) in corners.enumerated() {
            let isHot = corner == hot
            let bracket = isHot ? grown[index] : plain[index]
            guard let first = bracket.first else { continue }
            let path = NSBezierPath()
            path.move(to: first)
            for point in bracket.dropFirst() {
                path.line(to: point)
            }
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            NSColor.black.withAlphaComponent(0.35).setStroke()
            path.lineWidth = isHot ? 7 : 5.5
            path.stroke()

            (purpose == .recording ? NSColor.systemRed : NSColor.white).setStroke()
            path.lineWidth = isHot ? 5 : 3.5
            path.stroke()
        }
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
        let showsBadge = Self.showsBadge(purpose: purpose, typingSize: !sizeInput.isEmpty)
        if badgeShown != showsBadge {
            badgeShown = showsBadge
            let reason = purpose == .screenshot ? "screenshot" : (showsBadge ? "a size is being typed" : "recording, nothing typed")
            Self.logger.notice("badge \(showsBadge ? "shown" : "hidden", privacy: .public): \(reason, privacy: .public)")
        }
        if showsBadge {
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
        } else if badge.superview === self {
            badge.removeFromSuperview()
        }

        let toolbarTop = layOutToolbar()

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
            // Above the recording toolbar when there is one; otherwise where they always were.
            y: toolbarTop.map { $0 - hintsSize.height - 12 } ?? bounds.height - hintsSize.height - 48,
            width: hintsSize.width,
            height: hintsSize.height
        )
    }

    /// The recording toolbar sits at the bottom of the screen the cursor is on, whatever the
    /// region does and in every mode — it is where the mode is picked. Returns its top edge.
    ///
    /// It used to be a bar under the region that hid during every drag; this one never moves.
    func layOutToolbar() -> CGFloat? {
        let toolbar = OverlayHUD.recordingBarHost
        guard purpose == .recording else {
            if toolbar.superview === self {
                toolbar.removeFromSuperview()
            }
            return nil
        }
        // One toolbar for every screen: the screen under the cursor takes it, the others leave
        // it where it is.
        guard toolbar.superview === self || cursorPoint.map(bounds.contains) == true else { return nil }

        if toolbar.superview !== self {
            addSubview(toolbar)
        }
        let size = toolbar.fittingSize
        toolbar.frame = CGRect(
            origin: SelectionGeometry.toolbarOrigin(toolbarSize: size, bounds: bounds),
            size: size
        )
        return toolbar.frame.minY
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
            guard let highlightedWindow else { return (String(localized: "Click a window"), "") }
            return (pixelSize(of: highlightedWindow), "")
        }

        guard let selection, !selection.isEmpty else { return (position, "") }
        return (pixelSize(of: selection), position)
    }

    /// `1920 × 1080 · 16:9 · 2x` — the file's pixels, the proportions when they are held, and the
    /// scale; or the size being typed.
    private func recordingBadgeText(position: String) -> (String, String) {
        if !sizeInput.isEmpty {
            return ("\(sizeInput.text)▏", sizeInput.size == nil ? String(localized: "width × height") : String(localized: "↩ apply"))
        }

        let region: CGRect? = switch mode {
        case .window: highlightedWindow
        case .screen: bounds
        case .region: recordingRegion
        }
        guard let region else {
            return (mode == .window ? String(localized: "Click a window") : position, "")
        }

        let size = SelectionGeometry.recordingPixelSize(of: region, scale: outputScale)
        let scaleLabel = nativeResolution && scale > 1 ? "\(Int(scale))x" : "1x"
        let parts = ["\(size.width) × \(size.height)", aspect.label, scaleLabel].compactMap(\.self)
        return (parts.joined(separator: " · "), mode == .region ? position : "")
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
