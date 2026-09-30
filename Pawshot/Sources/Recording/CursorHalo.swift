import AppKit
import os

/// How many clicks the halo round the cursor has left. Pure, so the rule is a test.
struct CursorHaloCounter: Equatable {
    /// `nil`: the halo never goes by itself, only when switched off.
    let limit: Int?
    private(set) var clicks = 0

    /// `setting` is `Settings.zoomClicks`: 0 keeps the halo until it is switched off.
    init(clicksBeforeItGoes setting: Int) {
        limit = setting > 0 ? setting : nil
    }

    /// Counts a click. `false` once that was the last one the halo stays for.
    mutating func click() -> Bool {
        clicks += 1
        return limit.map { clicks < $0 } ?? true
    }
}

/// The zoom's halo round the cursor during a take — the owner's К-A of 2026-09-30: a soft ring in
/// the paw colour that follows the mouse, and three rings spreading from every click that zoomed,
/// like rings on water. ⇧⌘6 or the pill's magnifier put it up; `onClick` is the zoom.
/// For the person recording only: it is a Pawshot window, and the recording filter leaves every
/// Pawshot window out of the video but the pen's. No sound.
///
/// One click-through panel over the screen the cursor is on, moved to another screen when the
/// cursor goes there. The ring is a layer whose position follows the mouse sixty times a second —
/// nothing is redrawn. Clicks come from a global monitor, which needs no permission (as the click
/// rings of the video do, `EventRecorder`); a click on a Pawshot window, the pill's own buttons
/// included, is not seen and not counted.
@MainActor
final class CursorHaloController {
    private static var logger: Logger {
        .pawshot("recording")
    }

    static let diameter: CGFloat = 46
    /// A click's rings: how long each spreads, and when the second and third start after it.
    static let rippleDuration: CFTimeInterval = 0.9
    static let rippleDelays: [CFTimeInterval] = [0, 0.14, 0.28]

    /// Told when the halo went by itself after its last click, with how many it showed.
    var onGone: ((_ clicks: Int) -> Void)?
    /// A click while the halo is up: `true` when it did what the halo is for (a zoom there). Only
    /// then does it ripple and count — a click during a pause zooms nothing.
    var onClick: (() -> Bool)?

    private(set) var isShown = false
    private var counter = CursorHaloCounter(clicksBeforeItGoes: 0)
    private var panel: NSPanel?
    private var halo: CALayer?
    private var timer: Timer?
    private var clickMonitor: Any?
    private var fadeOut: DispatchWorkItem?

    func show(clicksBeforeItGoes setting: Int) {
        fadeOut?.cancel()
        fadeOut = nil
        counter = CursorHaloCounter(clicksBeforeItGoes: setting)
        let panel = panel ?? Self.makePanel()
        self.panel = panel
        let halo = halo ?? Self.makeHalo(in: panel)
        self.halo = halo
        halo.opacity = 1
        isShown = true
        follow()
        panel.orderFrontRegardless()

        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.clicked() }
            }
            if clickMonitor == nil {
                Self.logger.error("cursor halo: no click monitor, clicks won't ripple or count")
            }
        }
    }

    /// Takes the halo away at once. Returns how many clicks it showed.
    @discardableResult
    func hide() -> Int {
        fadeOut?.cancel()
        fadeOut = nil
        timer?.invalidate()
        timer = nil
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        clickMonitor = nil
        panel?.orderOut(nil)
        panel?.contentView?.layer?.sublayers?.filter { $0 !== halo }.forEach { $0.removeFromSuperlayer() }
        isShown = false
        return counter.clicks
    }

    // MARK: - Following and clicks

    private func follow() {
        guard let panel, let halo else { return }
        let mouse = NSEvent.mouseLocation
        // The screen the cursor is on now; the panel goes with it.
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }), panel.frame != screen.frame {
            panel.setFrame(screen.frame, display: false)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        halo.position = CGPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY)
        CATransaction.commit()
    }

    private func clicked() {
        guard isShown, let panel, let layer = panel.contentView?.layer else { return }
        guard onClick?() ?? true else { return }
        follow()
        let mouse = NSEvent.mouseLocation
        ripple(at: CGPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY), in: layer)
        guard !counter.click() else { return }

        // The last click: its rings still spread, the halo fades, and the panel goes once they
        // are done.
        let clicks = counter.clicks
        isShown = false
        timer?.invalidate()
        timer = nil
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        clickMonitor = nil
        halo?.opacity = 0
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.panel?.orderOut(nil)
                self?.panel?.contentView?.layer?.sublayers?.filter { $0 !== self?.halo }.forEach { $0.removeFromSuperlayer() }
            }
        }
        fadeOut = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rippleDuration + 0.4, execute: work)
        onGone?(clicks)
    }

    private func ripple(at point: CGPoint, in layer: CALayer) {
        let start = CACurrentMediaTime()
        for delay in Self.rippleDelays {
            let ring = CALayer()
            ring.bounds = CGRect(x: 0, y: 0, width: 20, height: 20)
            ring.position = point
            ring.cornerRadius = 10
            ring.borderWidth = 2
            ring.borderColor = Tokens.pawNSColor.withAlphaComponent(0.9).cgColor
            ring.opacity = 0

            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.4
            grow.toValue = 5
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [grow, fade]
            group.duration = Self.rippleDuration
            group.beginTime = start + delay
            group.fillMode = .backwards
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.3, 1)
            ring.add(group, forKey: "ripple")
            layer.addSublayer(ring)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + Self.rippleDuration + 0.1) { [weak ring] in
                ring?.removeFromSuperlayer()
            }
        }
    }

    // MARK: - Building

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSScreen.main?.frame ?? .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Above the pill, the frame and the dimming: it has to be seen over everything.
        panel.configureAsOverlay(level: .screenSaver)
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        let view = NSView(frame: CGRect(origin: .zero, size: panel.frame.size))
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        return panel
    }

    private static func makeHalo(in panel: NSPanel) -> CALayer {
        let halo = CALayer()
        halo.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        halo.cornerRadius = diameter / 2
        halo.backgroundColor = Tokens.pawNSColor.withAlphaComponent(0.16).cgColor
        halo.borderWidth = 2
        halo.borderColor = Tokens.pawNSColor.withAlphaComponent(0.95).cgColor
        halo.shadowColor = Tokens.pawNSColor.cgColor
        halo.shadowOpacity = 0.45
        halo.shadowRadius = 9
        halo.shadowOffset = .zero
        panel.contentView?.layer?.addSublayer(halo)
        return halo
    }
}
