import AppKit
import os

/// Collects the `EventTimeline` while a recording runs.
///
/// - the cursor, sixty times a second, only when it moved;
/// - clicks through a global monitor — mouse events need no permission;
/// - shortcuts through a listen-only `CGEventTap`, and only when "Show keystrokes" is on and Input
///   Monitoring is granted: nothing is ever read from the keyboard otherwise;
/// - zoom marks, from ⇧⌘6 or the pill.
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

    init(area: CGRect, clock: @escaping () -> Double?) {
        self.area = area
        self.clock = clock
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

    func stop() -> EventTimeline {
        if cursorTimer != nil {
            let recorded = timeline
            let reenabled = tapReenabled
            Self.logger.notice(
                "events: \(recorded.cursor.count, privacy: .public) cursor, \(recorded.clicks.count, privacy: .public) clicks, \(recorded.keys.count, privacy: .public) keys, \(recorded.zoomMarks.count, privacy: .public) zoom marks, \(recorded.zoomHolds.count, privacy: .public) zooms held, \(recorded.badTakes.count, privacy: .public) bad takes, \(recorded.spotlights.count, privacy: .public) spotlights, \(recorded.blurs.count, privacy: .public) hidden stretches, \(recorded.masks.count, privacy: .public) hidden zones, tap re-enabled \(reenabled, privacy: .public)×"
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

    /// The mark's time, or `nil` while paused, when nothing is recorded.
    @discardableResult
    func markZoom() -> TimeInterval? {
        guard let time = clock() else { return nil }
        timeline.zoomMarks.append(time)
        return time
    }

    /// The zoom key turned out to be held, not tapped: the mark its press left at `start`
    /// becomes a zoom that lasts until `end`.
    func holdZoom(from start: TimeInterval, to end: TimeInterval) {
        if let index = timeline.zoomMarks.lastIndex(of: start) {
            timeline.zoomMarks.remove(at: index)
        }
        timeline.zoomHolds.append(.init(start: start, end: max(start, end)))
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

    private func normalizedMouse() -> CGPoint? {
        SelectionGeometry.normalized(mouse: NSEvent.mouseLocation, in: area)
    }

    private func sampleCursor() {
        guard let time = clock(), let point = normalizedMouse() else { return }
        if let last = timeline.cursor.last, last.x == point.x, last.y == point.y {
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
