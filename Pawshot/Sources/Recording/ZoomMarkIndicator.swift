import AppKit

/// The outline shown for a zoom mark while recording: the part of the screen the zoom will show,
/// for as long as it will last. The zoom itself happens at export — the screen can't be zoomed
/// live — so this is the only sign the mark took.
///
/// A click-through Pawshot window, so the recording filter keeps it out of the video.
@MainActor
final class ZoomMarkIndicator {
    private var panel: NSPanel?
    /// Bumped on every mark, so the fade of an earlier one doesn't hide a newer outline.
    private var generation = 0

    /// `cursor` and `area` in AppKit screen coordinates.
    func show(around cursor: CGPoint, in area: CGRect, scale: CGFloat, for duration: TimeInterval) {
        let rect = SelectionGeometry.zoomPreviewRect(cursor: cursor, area: area, scale: scale)
        let panel = panel ?? Self.makePanel()
        self.panel = panel
        panel.setFrame(rect, display: true)
        // Through the animator: a plain assignment would leave an earlier mark's fade running.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()

        generation += 1
        let current = generation
        let fade: TimeInterval = 0.3
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, duration - fade)))
            guard let self, generation == current else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = fade
                panel.animator().alphaValue = 0
            } completionHandler: {
                // A short-lived strong hold: the indicator lives as long as its controller anyway.
                Task { @MainActor in
                    guard self.generation == current else { return }
                    panel.orderOut(nil)
                }
            }
        }
    }

    func close() {
        generation += 1
        panel?.orderOut(nil)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.configureAsOverlay()
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.contentView = ZoomOutlineView()
        return panel
    }
}

/// An orange rounded outline hugging the edge of its window, dark underneath so it reads on white.
private final class ZoomOutlineView: NSView {
    override func draw(_: CGRect) {
        let rect = bounds.insetBy(dx: 3, dy: 3)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        path.lineWidth = 5
        NSColor.black.withAlphaComponent(0.3).setStroke()
        path.stroke()
        path.lineWidth = 3
        Tokens.pawNSColor.setStroke()
        path.stroke()
    }
}
