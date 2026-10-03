import AppKit

/// What shows on the screen while a key is held during a take — the spotlight or the blur. The
/// effect itself is added to the video when it is exported; the screen can't be dimmed or blurred
/// live for the recording without the viewer of the recording seeing the same thing twice. So
/// this is the only sign the key took, and for the spotlight it is a preview of exactly what the
/// export will draw: the same hole, the same darkness, around the same cursor.
///
/// A click-through Pawshot window over the recorded area, so the recording filter keeps it out of
/// the video.
@MainActor
final class HeldEffectIndicator {
    private var panel: NSPanel?
    private var view: HeldEffectView?
    private var timer: Timer?

    /// `area` in AppKit screen coordinates.
    func show(_ effect: EventRecorder.HeldEffect, over area: CGRect) {
        let panel = panel ?? Self.makePanel()
        self.panel = panel
        let view = view ?? HeldEffectView()
        self.view = view
        panel.contentView = view
        panel.setFrame(area, display: false)
        view.effect = effect
        view.needsDisplay = true
        panel.orderFrontRegardless()

        timer?.invalidate()
        timer = nil
        guard effect == .spotlight else { return }
        // The hole goes where the cursor goes; the mouse sends this window nothing, so it looks.
        // Redrawn only when the mouse has moved: the sheet covers the whole area, and a still
        // mouse used to repaint it sixty times a second all the same.
        var last = NSEvent.mouseLocation
        let follow = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak view] _ in
            MainActor.assumeIsolated {
                let mouse = NSEvent.mouseLocation
                guard mouse != last else { return }
                last = mouse
                view?.needsDisplay = true
            }
        }
        RunLoop.main.add(follow, forMode: .common)
        timer = follow
    }

    func hide() {
        timer?.invalidate()
        timer = nil
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
        return panel
    }
}

/// Unflipped: the mouse comes in AppKit screen coordinates.
private final class HeldEffectView: NSView {
    var effect = EventRecorder.HeldEffect.spotlight

    override func draw(_: CGRect) {
        switch effect {
        case .spotlight: drawSpotlight()
        case .blur: drawHiddenFrame()
        }
    }

    /// The export's sheet and hole, with the export's own numbers.
    private func drawSpotlight() {
        guard let window else { return }
        let mouse = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let radius = min(bounds.width, bounds.height) * EffectsPlanner.spotlightRadius
        let sheet = NSBezierPath(rect: bounds)
        sheet.appendOval(in: CGRect(x: mouse.x - radius, y: mouse.y - radius, width: radius * 2, height: radius * 2))
        sheet.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(EffectsPlanner.spotlightDim).setFill()
        sheet.fill()
    }

    /// The screen stays readable — whoever holds the key still has to see what they type — so a
    /// hidden stretch is only framed in the paw colour, with a word at the top saying what the
    /// video will show instead.
    private func drawHiddenFrame() {
        let frame = NSBezierPath(rect: bounds.insetBy(dx: 3, dy: 3))
        frame.lineWidth = 6
        Tokens.pawNSColor.setStroke()
        frame.stroke()

        let text = String(localized: "Hidden in the video") as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.black.withAlphaComponent(0.85),
        ]
        let size = text.size(withAttributes: attributes)
        let plate = CGRect(
            x: bounds.midX - size.width / 2 - 12,
            y: bounds.maxY - size.height - 22,
            width: size.width + 24,
            height: size.height + 10
        )
        Tokens.pawNSColor.setFill()
        NSBezierPath(roundedRect: plate, xRadius: plate.height / 2, yRadius: plate.height / 2).fill()
        text.draw(at: CGPoint(x: plate.minX + 12, y: plate.minY + 5), withAttributes: attributes)
    }
}
