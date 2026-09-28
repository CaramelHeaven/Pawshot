import AppKit

/// A transparent full-screen panel that sits above everything else.
///
/// A **non-activating** panel: it takes the keyboard — Esc, Space, M, ↩ — without making Pawshot
/// the active app, the way Spotlight does. Activating from a background utility is cooperative on
/// macOS 14+ and was where a capture stalled: a log from a MacBook Air shows the overlay drawn
/// 215 ms after the hotkey, then `NSApp.activate()`, then four seconds in which the main thread
/// neither ran its queue nor got a mouse event, until the user clicked. Nothing about the overlay
/// needs the app active; the editor it opens activates as any window does.
///
/// The window is built once per screen and kept (`SelectionOverlayController.prepareWindows`), so
/// the hotkey never pays for creating it.
final class OverlayWindow: NSPanel {
    /// The frozen frame, in a layer of its own under the selection: it is drawn once when it
    /// arrives, and never again while the mouse moves — redrawing a 20-megapixel image on every
    /// mouse move cost ~28 ms a frame on a 5K screen.
    let frameView = FrameView()
    private let container = NSView()

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        // A panel hides when its app deactivates by default — and this app is never active.
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Otherwise the shot of the region under the cursor would catch the overlay's own shadow
        // and its appearance animation.
        animationBehavior = .none
        setFrame(screen.frame, display: false)

        container.frame = CGRect(origin: .zero, size: screen.frame.size)
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        frameView.frame = container.bounds
        frameView.autoresizingMask = [.width, .height]
        container.addSubview(frameView)
        contentView = container
    }

    /// Without this a borderless window never becomes key and receives neither Esc nor any other
    /// key.
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    /// The selection layer of the capture now on screen, above the frame.
    var selectionView: SelectionView? {
        container.subviews.compactMap { $0 as? SelectionView }.first
    }

    /// A fresh selection layer for a new capture: its state never outlives the capture it served.
    func install(_ view: SelectionView) {
        selectionView?.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
    }

    /// Back to empty between captures: no frame held (tens of megabytes), no selection layer.
    func clear() {
        frameView.image = nil
        selectionView?.removeFromSuperview()
    }
}

/// Draws the frozen frame and nothing else — in a layer of its own, so it is drawn once.
final class FrameView: NSView {
    /// `nil` until the frame arrives: the overlay is already up over the live screen by then.
    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool {
        true
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unused — the UI is built in code")
    }

    /// Clicks go to the selection layer above.
    override func hitTest(_: CGPoint) -> NSView? {
        nil
    }

    override func draw(_: CGRect) {
        // `draw(in:)` only: the variant with operation and fraction ignores the axis flip and puts
        // the frame upside down in this flipped view.
        image?.draw(in: bounds)
    }
}
