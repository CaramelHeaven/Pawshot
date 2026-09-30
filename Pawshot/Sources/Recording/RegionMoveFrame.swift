import AppKit
import os

/// The frame a paused region recording is grabbed by, the way the system's ⇧⌘5 lets its region be
/// moved: four thin bars just outside the region. Dragging any of them moves the region, same
/// size; the region itself is not covered, so a click inside it goes to the app being recorded
/// exactly as before the pause.
///
/// Four small panels rather than one ring: whether the window server lets a click through the
/// transparent middle of a ring-shaped window was not something to bet the recorded app's clicks
/// on. Like every Pawshot window they stay out of the video.
@MainActor
final class RegionMoveFrameController {
    private static var logger: Logger {
        .pawshot("recording")
    }

    /// How far out from the region the bars reach.
    static let thickness: CGFloat = 12

    private var panels: [NSPanel] = []
    /// The region, in AppKit screen coordinates.
    private(set) var area: CGRect = .zero
    /// Where the region may go: the display it is on.
    private var limit: CGRect = .zero
    private var gestureStart: (mouse: CGPoint, area: CGRect)?
    /// The last move is still being handed to the stream: a new drag waits for it.
    var isHandingOver = false

    /// Told at every step of a drag, with the region's new place.
    var onMove: ((CGRect) -> Void)?
    /// Told once when the mouse is let go, with where the region was and where it is.
    var onDrop: ((_ from: CGRect, _ to: CGRect) -> Void)?

    var isShown: Bool {
        !panels.isEmpty
    }

    func show(area: CGRect, within limit: CGRect) {
        close()
        self.area = area
        self.limit = limit
        for bar in SelectionGeometry.grabBars(around: area, thickness: Self.thickness) {
            let panel = NSPanel(
                contentRect: bar,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.configureAsOverlay()
            panel.animationBehavior = .none
            let view = GrabBarView(frame: CGRect(origin: .zero, size: bar.size))
            view.onDown = { [weak self] in self?.begin() }
            view.onDrag = { [weak self] in self?.drag() }
            view.onUp = { [weak self] in self?.end() }
            panel.contentView = view
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        Self.logger.notice("region grab frame up: 4 bars round \(Int(area.width), privacy: .public)×\(Int(area.height), privacy: .public) pt")
    }

    func close() {
        guard !panels.isEmpty else { return }
        for panel in panels {
            panel.orderOut(nil)
            panel.close()
        }
        panels = []
        gestureStart = nil
        Self.logger.notice("region grab frame down")
    }

    // MARK: - Dragging

    private func begin() {
        guard !isHandingOver else {
            Self.logger.notice("region grab ignored: the last move is still being handed to the stream")
            return
        }
        gestureStart = (NSEvent.mouseLocation, area)
        NSCursor.closedHand.set()
    }

    private func drag() {
        guard let start = gestureStart else { return }
        let mouse = NSEvent.mouseLocation
        // Whole points: a trackpad's fractions would shift the recorded part off the pixel grid
        // for the rest of the take.
        let moved = SelectionGeometry.moved(
            start.area,
            by: CGSize(width: (mouse.x - start.mouse.x).rounded(), height: (mouse.y - start.mouse.y).rounded()),
            within: limit
        )
        guard moved != area else { return }
        place(moved)
        onMove?(moved)
    }

    private func end() {
        guard let start = gestureStart else { return }
        gestureStart = nil
        NSCursor.openHand.set()
        if area == start.area {
            Self.logger.notice("region grab: let go without moving")
            return
        }
        onDrop?(start.area, area)
    }

    /// Puts the bars round `newArea` — after a drag step, or when the caller puts the region back.
    func place(_ newArea: CGRect) {
        area = newArea
        for (panel, bar) in zip(panels, SelectionGeometry.grabBars(around: newArea, thickness: Self.thickness)) {
            panel.setFrame(bar, display: true)
        }
    }
}

/// One bar: a faint rounded stripe along the region's edge, an open hand over it, and the mouse
/// events that move the region.
final class GrabBarView: NSView {
    var onDown: (() -> Void)?
    var onDrag: (() -> Void)?
    var onUp: (() -> Void)?

    override var isOpaque: Bool {
        false
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func cursorUpdate(with _: NSEvent) {
        NSCursor.openHand.set()
    }

    override func mouseEntered(with _: NSEvent) {
        NSCursor.openHand.set()
    }

    override func mouseDown(with _: NSEvent) {
        onDown?()
    }

    override func mouseDragged(with _: NSEvent) {
        onDrag?()
    }

    override func mouseUp(with _: NSEvent) {
        onUp?()
    }

    override func draw(_: CGRect) {
        // The stripe hugs the region's side of the bar, so it reads as the region's edge and not
        // as a window floating beside it.
        let stripe = bounds.insetBy(dx: bounds.width > bounds.height ? 0 : 3, dy: bounds.height > bounds.width ? 0 : 3)
        NSColor.white.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: stripe, xRadius: 3, yRadius: 3).fill()
    }
}
