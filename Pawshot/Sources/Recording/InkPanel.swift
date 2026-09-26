import AppKit

/// How a pen stroke fades: whole for 3.5 seconds, gone at 4. Pure, so the timing is a test.
enum InkFade {
    static let hold: TimeInterval = 3.5
    static let lifetime: TimeInterval = 4

    static func opacity(age: TimeInterval) -> CGFloat {
        if age < hold {
            return 1
        }
        return max(0, CGFloat((lifetime - age) / (lifetime - hold)))
    }

    static func isAlive(age: TimeInterval) -> Bool {
        age < lifetime
    }
}

/// The pen: a clear panel over the recorded area that takes the mouse while the pen is on.
///
/// Unlike every other Pawshot window it **is** in the video — that is the point of it. The filter
/// leaves the whole app out and names this one window as the exception, which is why the panel
/// exists, invisible and letting clicks through, from the start of the take: the exception is
/// fixed when the stream starts.
@MainActor
final class InkPanelController {
    private let panel: InkPanel
    private let canvas: InkView
    private(set) var isDrawing = false

    /// Esc while drawing: the pen goes off, the same as its shortcut again.
    var onExit: (() -> Void)?

    var windowID: CGWindowID {
        CGWindowID(panel.windowNumber)
    }

    /// `area` in AppKit screen coordinates.
    init(area: CGRect) {
        panel = InkPanel(
            contentRect: area,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        canvas = InkView(frame: CGRect(origin: .zero, size: area.size))
        panel.configureAsOverlay()
        panel.ignoresMouseEvents = true
        panel.contentView = canvas
        panel.onCancel = { [weak self] in self?.onExit?() }
    }

    func show() {
        panel.orderFrontRegardless()
    }

    /// Waits until the window server has actually put the panel on screen.
    ///
    /// Measured: straight after `orderFrontRegardless` ScreenCaptureKit lists the window with a
    /// zero frame and `isOnScreen == false`, and a filter built then would not let it through.
    /// The wait yields the run loop, which is what lets the window go out. Gives up after a
    /// second — a recording without the pen beats no recording.
    func waitUntilOnScreen() async {
        let id = windowID
        for _ in 0 ..< 100 {
            let listed = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]]
            if let entry = listed?.first, entry[kCGWindowIsOnscreen as String] as? Bool == true {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func setDrawing(_ drawing: Bool) {
        isDrawing = drawing
        panel.ignoresMouseEvents = !drawing
        if drawing {
            // Key so Esc reaches it; nonactivating, so the recorded app stays the active one.
            panel.makeKey()
            NSCursor.crosshair.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
    }
}

private final class InkPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool {
        true
    }

    override func cancelOperation(_: Any?) {
        onCancel?()
    }
}

/// The strokes, each fading on its own clock. The colour and width are the editor's default
/// style — there is no editor open during a recording to take them from.
private final class InkView: NSView {
    private struct Stroke {
        var points: [CGPoint]
        let started: Date
    }

    private var strokes: [Stroke] = []
    private var fadeTimer: Timer?
    private let style = AnnotationStyle.default

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        strokes.append(Stroke(points: [convert(event.locationInWindow, from: nil)], started: Date()))
        startFading()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !strokes.isEmpty else { return }
        strokes[strokes.count - 1].points.append(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    /// Redraws thirty times a second while anything is still fading, and stops once nothing is.
    private func startFading() {
        guard fadeTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fadeTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    private func fadeTick() {
        let now = Date()
        strokes.removeAll { !InkFade.isAlive(age: now.timeIntervalSince($0.started)) }
        needsDisplay = true
        if strokes.isEmpty {
            fadeTimer?.invalidate()
            fadeTimer = nil
        }
    }

    override func draw(_: CGRect) {
        let now = Date()
        for stroke in strokes {
            guard let first = stroke.points.first else { continue }
            let path = NSBezierPath()
            path.move(to: first)
            if stroke.points.count == 1 {
                path.line(to: first)
            }
            for point in stroke.points.dropFirst() {
                path.line(to: point)
            }
            path.lineWidth = style.lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            style.color.withAlphaComponent(InkFade.opacity(age: now.timeIntervalSince(stroke.started))).setStroke()
            path.stroke()
        }
    }
}
