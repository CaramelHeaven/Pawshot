import AppKit

/// What a region recording looks like while it runs, the way macOS shows it: everything outside
/// the region dimmed, the region itself clear, framed by the red corners of the recording overlay.
///
/// A click-through window over the whole screen of the region. It never reaches the video: the
/// recording filter leaves every Pawshot window out except the pen's, and inside the region the
/// window draws nothing anyway.
///
/// Only for a region. A full-screen take has nothing around it to dim, and a window take follows a
/// window that may move while the hole would stay put.
@MainActor
final class RecordingFrameController {
    private(set) var window: NSPanel?

    /// `area` in AppKit screen coordinates. A frame already up on that screen is only moved to the
    /// new area — a restart keeps the dimming without a flash of the bare screen.
    func show(area: CGRect, on screen: NSScreen) {
        if let window, window.frame == screen.frame, let view = window.contentView as? RecordingFrameView {
            view.area = SelectionGeometry.localRect(of: area, in: screen.frame)
            window.orderFrontRegardless()
            return
        }
        close()
        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.configureAsOverlay()
        panel.animationBehavior = .none
        // The dimmed part is still the user's screen: clicks go straight to the apps under it.
        panel.ignoresMouseEvents = true

        let view = RecordingFrameView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.area = SelectionGeometry.localRect(of: area, in: screen.frame)
        panel.contentView = view
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
        window = panel
    }

    func close() {
        window?.orderOut(nil)
        window?.close()
        window = nil
    }
}

extension NSPanel {
    /// What every panel Pawshot lays over the screen while recording shares: borderless glass
    /// that stays on every space and in full screen, and outlives the app losing focus.
    func configureAsOverlay(level: NSWindow.Level = .floating) {
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }
}

/// The dimming with a hole, and the frame around the hole. Unflipped: `area` comes straight from
/// AppKit coordinates.
final class RecordingFrameView: NSView {
    /// The recorded region, in this view's coordinates.
    var area: CGRect = .zero {
        didSet { needsDisplay = true }
    }

    /// The same dimming as the capture overlay, so the overlay turns into this without a jump.
    private let dimColor = NSColor.black.withAlphaComponent(0.35)

    override func draw(_: CGRect) {
        guard !area.isEmpty else { return }

        dimColor.setFill()
        let dimming = NSBezierPath(rect: bounds)
        dimming.appendRect(area)
        dimming.windingRule = .evenOdd
        dimming.fill()

        // Everything below sits outside the region: whatever is drawn inside would cover part of
        // what the user is recording, even if the video never sees it.
        NSColor.black.withAlphaComponent(0.6).setStroke()
        let outer = NSBezierPath(rect: area.insetBy(dx: -1.5, dy: -1.5))
        outer.lineWidth = 1
        outer.stroke()

        NSColor.white.setStroke()
        let inner = NSBezierPath(rect: area.insetBy(dx: -0.5, dy: -0.5))
        inner.lineWidth = 1
        inner.stroke()

        drawCornerBrackets(around: area.insetBy(dx: -4, dy: -4))
    }

    /// The recording overlay's red corners, pushed out so their stroke clears the region.
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

        NSColor.systemRed.setStroke()
        path.lineWidth = 3.5
        path.stroke()
    }
}
