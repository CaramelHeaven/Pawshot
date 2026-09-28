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
    /// The longest one draw of the selection layer took, in ms — on a 20-megapixel screen the
    /// question is whether a mouse move still fits in a frame.
    private(set) var slowestDraw = 0.0

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

    mutating func drawFinished(took seconds: TimeInterval) {
        slowestDraw = max(slowestDraw, seconds * 1000)
    }

    func summary(at date: Date) -> String {
        "overlay closed +\(milliseconds(date)) ms after the hotkey, \(draws) draw(s), slowest \(Int(slowestDraw.rounded())) ms"
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

    /// `" (+N ms since the hotkey)"` during a capture, nothing outside one — where the log used to
    /// say `+-1 ms`.
    static func sincePressNote(_ date: Date = Date()) -> String {
        timeline.map { " (+\($0.milliseconds(date)) ms since the hotkey)" } ?? ""
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

    static func drawFinished(took seconds: TimeInterval) {
        timeline?.drawFinished(took: seconds)
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
        watchdog?.stop()
        watchdog = nil
        guard let timeline else { return }
        let summary = timeline.summary(at: Date())
        logger.notice("\(summary, privacy: .public)")
        self.timeline = nil
    }

    private static var watchdog: MainThreadWatchdog?

    /// Watches the main thread from another one for the first seconds of the overlay: a log from
    /// a MacBook Air showed it silent for four seconds right after the overlay went up — no queued
    /// work run, no mouse event delivered — until a click. A stall is logged with the run loop mode
    /// the main thread sits in, and what the window server says about the overlay windows.
    static func watch(windows: [NSWindow]) {
        watchdog?.stop()
        let watchdog = MainThreadWatchdog(
            pressed: timeline?.pressed ?? Date(),
            windowNumbers: windows.map { CGWindowID($0.windowNumber) }
        )
        watchdog.start()
        self.watchdog = watchdog
    }
}

/// Pings the main queue every 50 ms from a background queue, for three seconds.
final class MainThreadWatchdog: Sendable {
    private struct State {
        var lastPong = Date()
        var stalledSince: Date?
        var stopped = false
        var sampled = false
    }

    private let pressed: Date
    private let windowNumbers: [CGWindowID]
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "com.caramelheaven.pawshot.watchdog", qos: .userInitiated)
    private static let logger = Logger(subsystem: "com.caramelheaven.pawshot", category: "overlay")
    /// A main thread this late is stalled, not busy.
    static let threshold: TimeInterval = 0.25

    init(pressed: Date, windowNumbers: [CGWindowID]) {
        self.pressed = pressed
        self.windowNumbers = windowNumbers
    }

    func start() {
        let started = Date()
        queue.async { [self] in
            while Date().timeIntervalSince(started) < 3 {
                if state.withLock({ $0.stopped }) {
                    return
                }
                DispatchQueue.main.async { [self] in
                    let back = state.withLock { state -> TimeInterval? in
                        let now = Date()
                        defer {
                            state.lastPong = now
                            state.stalledSince = nil
                        }
                        return state.stalledSince.map { now.timeIntervalSince($0) + Self.threshold }
                    }
                    if let back {
                        let at = milliseconds(Date())
                        Self.logger.notice("main thread back after \(Int(back * 1000), privacy: .public) ms, at +\(at, privacy: .public) ms")
                    }
                }
                let now = Date()
                let stalled = state.withLock { state -> Bool in
                    guard state.stalledSince == nil, now.timeIntervalSince(state.lastPong) > Self.threshold else { return false }
                    state.stalledSince = now
                    return true
                }
                if stalled {
                    report(at: now)
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    func stop() {
        state.withLock { $0.stopped = true }
    }

    private func milliseconds(_ date: Date) -> Int {
        Int((date.timeIntervalSince(pressed) * 1000).rounded())
    }

    private func report(at date: Date) {
        let mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain()).map { $0.rawValue as String } ?? "none"
        let windows = Self.windowServerState(of: windowNumbers)
        let message = Self.stallMessage(at: milliseconds(date), mode: mode, windows: windows, memory: SystemState.memoryPressure)
        Self.logger.error("\(message, privacy: .public)")
        // One stack per overlay: a sample takes 1.4 s, and the first stall is the one reported.
        let first = state.withLock { state in
            defer { state.sampled = true }
            return !state.sampled
        }
        if first {
            StallSamples.record()
        }
    }

    static func stallMessage(at milliseconds: Int, mode: String, windows: String, memory: String) -> String {
        "main thread stalled over \(Int(threshold * 1000)) ms at +\(milliseconds) ms, run loop mode \(mode); "
            + "window server: \(windows); memory pressure \(memory)"
    }

    /// What the window server says about the overlay windows: on screen or not, and their alpha.
    static func windowServerState(of numbers: [CGWindowID]) -> String {
        numbers.map { number in
            guard
                let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], number) as? [[String: Any]])?.first
            else { return "\(number) gone" }
            let onscreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
            let alpha = (info[kCGWindowAlpha as String] as? Double) ?? -1
            return "\(number) onscreen \(onscreen) alpha \(alpha)"
        }.joined(separator: ", ")
    }
}

/// The main thread's stack, taken while it is stalled. The watchdog says *that* it stalled and in
/// which run loop mode; only a stack says *what* it was doing — a tester's first ⇧⌘2 after a
/// relaunch stood 910 ms in the default mode with nothing in the log to tell why.
///
/// `/usr/bin/sample` reads a process of the same user without root as long as it has no hardened
/// runtime, and Pawshot has none. Measured on a running copy: a one-second sample takes 1.4 s and
/// 0.37 s of CPU, and writes some 230 KB, of which Save Logs keeps the main thread's part.
enum StallSamples {
    private static let logger = Logger(subsystem: "com.caramelheaven.pawshot", category: "overlay")
    static let prefix = "stall-"
    /// Samples kept on disk; the oldest goes when a new one is taken.
    static let kept = 5

    static var folder: URL? {
        try? FileManager.default
            .url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("com.caramelheaven.pawshot/Stalls", isDirectory: true)
    }

    /// Samples this process for one second, in the background; the report lands in `folder`.
    static func record() {
        guard let folder else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            logger.error("main thread stack: no folder for it: \(String(describing: error), privacy: .public)")
            return
        }
        for old in LogExport.newestFirst(in: folder, prefix: prefix).dropFirst(kept - 1) {
            try? FileManager.default.removeItem(at: old)
        }
        let path = folder.appendingPathComponent("\(prefix)\(Int(Date().timeIntervalSince1970)).txt").path
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        logger.notice("main thread stack: sampling into \(path, privacy: .public)")
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/sample")
            process.arguments = [pid, "1", "10", "-mayDie", "-file", path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                logger.error("main thread stack: sample could not start: \(String(describing: error), privacy: .public)")
                return
            }
            process.waitUntilExit()
            let status = process.terminationStatus
            if status == 0 {
                logger.notice("main thread stack: written")
            } else {
                logger.error("main thread stack: sample exited with status \(status, privacy: .public)")
            }
        }
    }

    /// The report's header — the process and its memory footprint — and the main thread's branch
    /// of the call graph. The other threads are the same idle stacks in every sample.
    static func mainThreadPart(of report: String) -> String {
        let lines = report.components(separatedBy: "\n")
        guard let graph = lines.firstIndex(where: { $0.hasPrefix("Call graph:") }) else { return report }
        var kept = Array(lines[...graph])
        var inThread = false
        for line in lines[(graph + 1)...] {
            // A thread starts at four spaces and its sample count; its frames carry a "+".
            let startsThread = line.hasPrefix("    ") && line.dropFirst(4).first?.isNumber == true
            if line.isEmpty || (startsThread && inThread) {
                break
            }
            inThread = inThread || startsThread
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }
}
