import AppKit
import os

/// When one capture's steps happened, counted from the hotkey. Pure, so its messages are tested.
///
/// Written for one report: the first ⇧⌘2 after launch showed nothing until a click, and then the
/// screen went dark. A frame that was captured but never drawn, a draw nobody saw, and a task that
/// never ran all look the same from outside; "first draw" against "first event" tells them apart.
struct OverlayTimeline {
    let pressed: Date
    private(set) var begun: Date?
    private(set) var firstDraw: Date?
    private(set) var firstEvent: Date?
    private(set) var draws = 0

    init(pressed: Date) {
        self.pressed = pressed
    }

    func milliseconds(_ date: Date) -> Int {
        Int((date.timeIntervalSince(pressed) * 1000).rounded())
    }

    mutating func begin(at date: Date) {
        begun = date
    }

    /// The message for the first draw, `nil` for the ones after it.
    mutating func drew(at date: Date) -> String? {
        draws += 1
        guard firstDraw == nil else { return nil }
        firstDraw = date
        return "overlay first draw +\(milliseconds(date)) ms"
    }

    /// The message for the first mouse or key event the overlay gets — and whether it had been
    /// drawn by then. "Not drawn before the first event" is the report: dark only after a click.
    mutating func received(_ event: String, at date: Date) -> (message: String, drawnBefore: Bool)? {
        guard firstEvent == nil else { return nil }
        firstEvent = date
        let drawn = firstDraw.map { $0 <= date } ?? false
        return ("overlay first event \(event) +\(milliseconds(date)) ms, drawn before it: \(drawn)", drawn)
    }

    /// A look a while after the overlay went up. An error when it still hasn't been drawn.
    func check(at date: Date, visibleWindows: Int, windows: Int, appActive: Bool, keyWindow: Bool) -> (message: String, isError: Bool) {
        let drawn = draws > 0
        let message = "overlay check +\(milliseconds(date)) ms: drawn \(draws)×, visible \(visibleWindows)/\(windows), "
            + "app active \(appActive), key window \(keyWindow)"
        return (drawn ? message : message + " — NOT DRAWN YET", !drawn)
    }

    func summary(at date: Date) -> String {
        "overlay closed +\(milliseconds(date)) ms after the hotkey, \(draws) draw(s)"
    }
}

/// The one timeline of the capture in progress, and the log it writes to.
@MainActor
enum OverlayDiagnostics {
    static let logger = Logger(subsystem: "com.caramelheaven.pawshot", category: "overlay")
    private(set) static var timeline: OverlayTimeline?

    /// The hotkey — or the menu — asked for a capture.
    static func pressed(at date: Date = Date()) {
        timeline = OverlayTimeline(pressed: date)
    }

    /// `+N ms` since the press, for the lines logged elsewhere; `-1` when there is no capture.
    static func sincePress(_ date: Date = Date()) -> Int {
        timeline?.milliseconds(date) ?? -1
    }

    static func began() {
        timeline?.begin(at: Date())
        let elapsed = sincePress()
        logger.notice("overlay begin +\(elapsed, privacy: .public) ms")
    }

    static func drew() {
        guard let message = timeline?.drew(at: Date()) else { return }
        logger.notice("\(message, privacy: .public)")
    }

    static func received(_ event: String) {
        guard let result = timeline?.received(event, at: Date()) else { return }
        if result.drawnBefore {
            logger.notice("\(result.message, privacy: .public)")
        } else {
            logger.error("\(result.message, privacy: .public)")
        }
    }

    static func check(windows: [NSWindow]) {
        guard let timeline else { return }
        let visible = windows.count(where: { $0.isVisible && $0.occlusionState.contains(.visible) })
        let result = timeline.check(
            at: Date(),
            visibleWindows: visible,
            windows: windows.count,
            appActive: NSApp.isActive,
            keyWindow: windows.contains(where: \.isKeyWindow)
        )
        if result.isError {
            logger.error("\(result.message, privacy: .public)")
        } else {
            logger.notice("\(result.message, privacy: .public)")
        }
    }

    static func ended() {
        guard let timeline else { return }
        let summary = timeline.summary(at: Date())
        logger.notice("\(summary, privacy: .public)")
        self.timeline = nil
    }
}
