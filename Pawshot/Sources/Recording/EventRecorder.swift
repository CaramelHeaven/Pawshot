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
    private static let logger = Logger(subsystem: "com.caramelheaven.pawshot", category: "recording")

    /// The recorded area in AppKit screen coordinates, where `NSEvent.mouseLocation` lives.
    private let area: CGRect
    private let clock: () -> Double?
    private(set) var timeline = EventTimeline()

    private var cursorTimer: Timer?
    private var clickMonitor: Any?
    private var keyTap: CFMachPort?
    private var keySource: CFRunLoopSource?

    init(area: CGRect, clock: @escaping () -> Double?) {
        self.area = area
        self.clock = clock
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

        if recordingKeys, CGPreflightListenEventAccess() {
            startKeyTap()
        }
    }

    func stop() -> EventTimeline {
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
    fileprivate func reenableKeyTap() {
        if let keyTap {
            CGEvent.tapEnable(tap: keyTap, enable: true)
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
        MainActor.assumeIsolated { recorder.reenableKeyTap() }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}
