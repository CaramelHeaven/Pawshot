import AppKit
import os

/// Collects the `EventTimeline` while a recording runs.
///
/// - the cursor, sixty times a second, only when it moved;
/// - clicks through a global monitor — mouse events need no permission;
/// - shortcuts through a listen-only `CGEventTap`, and only when "Show keystrokes" is on and Input
///   Monitoring is granted: nothing is ever read from the keyboard otherwise.
///
/// Everything is stamped with the file's own time (`clock`), which is `nil` during a pause: what
/// happens then isn't in the video, so it isn't in the timeline either.
@MainActor
final class EventRecorder {
    private static var logger: Logger {
        .pawshot("recording")
    }

    /// The recorded area in AppKit screen coordinates, where `NSEvent.mouseLocation` lives. Moves
    /// only while the take is paused; what is recorded after is counted from the new place.
    private(set) var area: CGRect
    private let clock: () -> Double?
    private(set) var timeline = EventTimeline()

    private var cursorTimer: Timer?
    private var clickMonitor: Any?
    private var keyTap: CFMachPort?
    private var keySource: CFRunLoopSource?
    private var tapReenabled = 0

    /// The cursor's clock: how often it was asked and the longest wait, for the take's summary.
    private var clockAsks = 0
    private var slowestClock: Duration = .zero
    private var cursorOutside = 0
    private var cursorPaused = 0

    init(area: CGRect, clock: @escaping () -> Double?) {
        self.area = area
        self.clock = clock
    }

    /// The take's frame rate, for the export to render the effects at.
    func setFramesPerSecond(_ fps: Int) {
        timeline.framesPerSecond = fps
    }

    /// Zones hidden throughout, as fractions of the area (0…1, origin top left).
    func setMasks(_ zones: [CGRect]) {
        timeline.masks = zones.map {
            EventTimeline.Mask(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height)
        }
        if !zones.isEmpty {
            Self.logger.notice("\(zones.count, privacy: .public) zone(s) to hide marked before the take")
        }
    }

    func start(recordingKeys: Bool) {
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleCursor() }
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorTimer = timer

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordClick() }
        }
        if clickMonitor == nil {
            Self.logger.error("click monitor not installed: no click rings in this take")
        }

        if recordingKeys, CGPreflightListenEventAccess() {
            startKeyTap()
        } else if recordingKeys {
            Self.logger.notice("shortcut captions skipped: no Input Monitoring access")
        }
    }

    /// The region moved while paused. Positions already recorded stay as they are: each is a
    /// fraction of the area it was seen in, and that is what the export wants.
    func move(to newArea: CGRect) {
        area = newArea
    }

    /// The region moved on a pause at `time` (seconds of the file), from `old` to `new` — global
    /// points, origin top left. The zones stay over the same part of the screen
    /// (`EventTimeline.masks(_:afterMovingFrom:to:at:)`). Returns the zones open from now on, as
    /// fractions of the new region, and how many the new region no longer holds.
    func moveZones(from old: CGRect, to new: CGRect, at time: Double) -> (open: [CGRect], dropped: Int) {
        let (masks, dropped) = EventTimeline.masks(timeline.masks, afterMovingFrom: old, to: new, at: time)
        timeline.masks = masks
        return (masks.filter { $0.end == nil }.map(\.fractions), dropped)
    }

    func stop() -> EventTimeline {
        if cursorTimer != nil {
            let recorded = timeline
            let reenabled = tapReenabled
            let asks = clockAsks
            let slowest = Double(slowestClock.components.attoseconds) / 1e15 + Double(slowestClock.components.seconds) * 1000
            let outside = cursorOutside
            let paused = cursorPaused
            Self.logger.notice(
                "events: cursor asked the clock \(asks, privacy: .public)×, slowest \(String(format: "%.2f", slowest), privacy: .public) ms; \(outside, privacy: .public) samples outside the area, \(paused, privacy: .public) while paused"
            )
            Self.logger.notice(
                "events: \(recorded.cursor.count, privacy: .public) cursor, \(recorded.clicks.count, privacy: .public) clicks, \(recorded.keys.count, privacy: .public) keys, \(recorded.badTakes.count, privacy: .public) bad takes, \(recorded.spotlights.count, privacy: .public) spotlights, \(recorded.blurs.count, privacy: .public) hidden stretches, \(recorded.masks.count, privacy: .public) hidden zones, tap re-enabled \(reenabled, privacy: .public)×"
            )
        }
        cursorTimer?.invalidate()
        cursorTimer = nil
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        clickMonitor = nil
        if let keyTap {
            CGEvent.tapEnable(tap: keyTap, enable: false)
        }
        if let keySource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), keySource, .commonModes)
        }
        keyTap = nil
        keySource = nil
        return timeline
    }

    /// What a key held during a take does to the video.
    enum HeldEffect: String {
        case spotlight
        case blur
    }

    /// The file's time now, or `nil` while paused.
    var now: TimeInterval? {
        clock()
    }

    /// A key was held from `start` to `end` of the file. Anything shorter than a tenth of a second
    /// is a slip of the finger and leaves nothing.
    @discardableResult
    func hold(_ effect: HeldEffect, from start: TimeInterval, to end: TimeInterval) -> EventTimeline.Span? {
        guard end - start >= 0.1 else { return nil }
        let span = EventTimeline.Span(start: start, end: end)
        switch effect {
        case .spotlight: timeline.spotlights.append(span)
        case .blur: timeline.blurs.append(span)
        }
        return span
    }

    /// Marks the last seconds as a bad take. `nil` while paused, or with nothing left to cut.
    @discardableResult
    func markBadTake() -> EventTimeline.Span? {
        guard let time = clock(), let span = EventTimeline.badTake(endingAt: time, after: timeline.badTakes)
        else { return nil }
        timeline.badTakes.append(span)
        return span
    }

    // MARK: - Samples

    /// Where the mouse is; a test sets its own.
    var mouseLocation: () -> CGPoint = { NSEvent.mouseLocation }

    private func normalizedMouse() -> CGPoint? {
        SelectionGeometry.normalized(mouse: mouseLocation(), in: area)
    }

    /// 60 times a second. The clock is a hop onto the recording's sample queue, behind the
    /// encoder, so it is asked only once the mouse has moved: a still mouse costs nothing.
    func sampleCursor() {
        guard let point = normalizedMouse() else {
            cursorOutside += 1
            return
        }
        if let last = timeline.cursor.last, last.x == point.x, last.y == point.y {
            return
        }
        let asked = ContinuousClock.now
        let time = clock()
        let waited = asked.duration(to: .now)
        clockAsks += 1
        slowestClock = max(slowestClock, waited)
        guard let time else {
            cursorPaused += 1
            return
        }
        timeline.cursor.append(.init(time: time, x: point.x, y: point.y))
    }

    private func recordClick() {
        guard let time = clock(), let point = normalizedMouse() else { return }
        timeline.clicks.append(.init(time: time, x: point.x, y: point.y))
    }

    fileprivate func recordKey(label: String) {
        guard let time = clock() else { return }
        timeline.keys.append(.init(time: time, label: label))
    }

    // MARK: - Keys

    /// The system switches a tap off when a callback is slow or on some user input; it has to be
    /// switched back on, or the keys silently stop being recorded mid-take.
    fileprivate func reenableKeyTap(reason: String) {
        if let keyTap {
            CGEvent.tapEnable(tap: keyTap, enable: true)
            tapReenabled += 1
            let count = tapReenabled
            Self.logger.notice("key tap switched off by the system (\(reason, privacy: .public)), back on (\(count, privacy: .public)×)")
        }
    }

    /// Listen-only: the tap never changes or swallows a key, it only reads the ones with ⌘, ⌥ or ⌃.
    private func startKeyTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: keyTapCallback,
            userInfo: context
        ) else {
            Self.logger.error("key tap not created — Input Monitoring is probably off")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        keyTap = tap
        keySource = source
    }
}

/// The tap's C callback. It runs on the main run loop — that is where the source was added — so
/// hopping onto the main actor is a formality, not a thread change.
private func keyTapCallback(
    _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    context: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let context else { return Unmanaged.passUnretained(event) }
    let recorder = Unmanaged<EventRecorder>.fromOpaque(context).takeUnretainedValue()
    switch type {
    case .keyDown:
        // The label is worked out here, so only a string crosses to the main actor.
        guard
            let nsEvent = NSEvent(cgEvent: event),
            let label = KeystrokeLabel.label(
                keyCode: nsEvent.keyCode,
                flags: nsEvent.modifierFlags,
                latin: KeyboardLayout.latinCharacter(for: nsEvent)
            )
        else { break }
        MainActor.assumeIsolated { recorder.recordKey(label: label) }
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        let reason = type == .tapDisabledByTimeout ? "timeout" : "user input"
        MainActor.assumeIsolated { recorder.reenableKeyTap(reason: reason) }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}
