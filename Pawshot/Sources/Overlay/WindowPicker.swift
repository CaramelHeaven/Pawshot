import Foundation

/// Which window the cursor is over. Kept out of the view so the rule can be tested — the mouse is
/// unavailable in tests, and "the window under the cursor" is otherwise unverifiable.
enum WindowPicker {
    /// The frontmost window containing the point.
    ///
    /// - Parameters:
    ///   - point: a point in global CoreGraphics coordinates.
    ///   - windows: the frozen list, **front to back** — the order
    ///     `ScreenCaptureService.onScreenWindows()` returns. The first match wins, which is what
    ///     makes overlapping windows behave: you get the one you can actually see.
    static func window(at point: CGPoint, in windows: [CapturedWindow]) -> CapturedWindow? {
        windows.first { $0.frame.contains(point) }
    }
}
