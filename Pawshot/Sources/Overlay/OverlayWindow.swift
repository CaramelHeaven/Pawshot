import AppKit

/// A transparent full-screen window that sits above everything else.
final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Otherwise the shot of the region under the cursor would catch the overlay's own shadow
        // and its appearance animation.
        animationBehavior = .none
        setFrame(screen.frame, display: false)
    }

    /// Without this a borderless window never becomes key and receives neither Esc nor any other
    /// key.
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}
