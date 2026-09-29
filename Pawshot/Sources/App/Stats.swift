import AppKit
import Foundation
import Observation
import os

/// The numbers on Settings → Statistics: counted on this Mac, never sent anywhere. The owner picked
/// the set and the tiles (L-B) on 2026-09-28; everything starts at zero with the build that brought
/// it, and "Reset Statistics…" starts it again.
///
/// Apart from `Settings` on purpose: a count bumps `revision`, and every view reading the settings
/// would redraw on each arrow drawn. `captureCount` stays there — the hints and About rely on it,
/// and a reset here must not bring the hints back.
@MainActor
@Observable
final class Stats {
    /// The test host is the app itself, with the owner's defaults: tests that draw or capture would
    /// otherwise count into the owner's own numbers.
    static let shared = Stats(
        defaults: AppDelegate.isTestHost
            ? UserDefaults(suiteName: "com.caramelheaven.pawshot.tests") ?? .standard
            : .standard
    )

    enum Counter: String, CaseIterable {
        case shots, windowShots, fullScreenShots, cancels, recognizedCharacters, edgeFits
        case arrows, rectangles, strokes, labels, blurs, steps, undos
        case red, green, white, black, ownColour
        case recordings, recordedSeconds, restarts, pauses, quitsCalledOff
    }

    enum Mode {
        case region, window, fullScreen
    }

    /// The five colours in the order of the palette's keys 1…5.
    static let colours: [Counter] = [.red, .green, .white, .black, .ownColour]
    static let drawn: [(tool: AnnotationTool, counter: Counter)] = [
        (.arrow, .arrows), (.rectangle, .rectangles), (.pencil, .strokes),
        (.text, .labels), (.blur, .blurs), (.counter, .steps),
    ]
    /// A page of a novel, for the ⌘D tile.
    static let charactersPerPage = 1800
    /// An episode of The Simpsons without the ads, for the recording tile.
    static let episodeSeconds = 22 * 60

    @ObservationIgnored private let defaults: UserDefaults
    private var revision = 0

    private static var logger: Logger {
        .pawshot("settings")
    }

    private static let hoursKey = "stats.hours"
    private static let sinceKey = "stats.since"
    private static let lastDayKey = "stats.lastDay"
    private static let streakKey = "stats.streak"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.sinceKey) == nil {
            defaults.set(Date(), forKey: Self.sinceKey)
        }
    }

    // MARK: - Counting

    func add(_ counter: Counter, _ amount: Int = 1) {
        defaults.set(defaults.integer(forKey: key(counter)) + amount, forKey: key(counter))
        revision += 1
    }

    func noteShot(_ mode: Mode, at date: Date = Date()) {
        add(.shots)
        switch mode {
        case .region: break
        case .window: add(.windowShots)
        case .fullScreen: add(.fullScreenShots)
        }
        var hours = hours
        hours[Calendar.current.component(.hour, from: date)] += 1
        defaults.set(hours, forKey: Self.hoursKey)
        noteActiveDay(date)
    }

    /// The tool and, for everything but a blur, which of the five colours it was drawn in.
    func noteDrawn(_ annotation: Annotation) {
        let tool = AnnotationTool.drawing(annotation)
        guard let counter = Self.drawn.first(where: { $0.tool == tool })?.counter else { return }
        add(counter)
        guard tool != .blur else { return }
        let index = AnnotationStyle.Palette.colors.firstIndex(of: annotation.style.color)
        add(index.map { Self.colours[$0] } ?? .ownColour)
    }

    func noteRecording(seconds: TimeInterval, at date: Date = Date()) {
        add(.recordings)
        add(.recordedSeconds, Int(seconds.rounded()))
        noteActiveDay(date)
    }

    /// A day with a shot or a recording in it: the next calendar day grows the streak, a gap
    /// starts it again.
    func noteActiveDay(_ date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        let last = defaults.object(forKey: Self.lastDayKey) as? Date
        switch last.flatMap({ Calendar.current.dateComponents([.day], from: $0, to: day).day }) {
        case 0?: return
        case 1?: defaults.set(defaults.integer(forKey: Self.streakKey) + 1, forKey: Self.streakKey)
        default: defaults.set(1, forKey: Self.streakKey)
        }
        defaults.set(day, forKey: Self.lastDayKey)
        revision += 1
    }

    /// Everything back to zero, counting from now. Other `stats.` keys — the capture count behind
    /// the hints — are not ours to clear.
    func reset() {
        Self.logger.notice("statistics reset")
        for counter in Counter.allCases {
            defaults.removeObject(forKey: key(counter))
        }
        for key in [Self.hoursKey, Self.lastDayKey, Self.streakKey] {
            defaults.removeObject(forKey: key)
        }
        defaults.set(Date(), forKey: Self.sinceKey)
        revision += 1
    }

    // MARK: - Reading

    func value(_ counter: Counter) -> Int {
        _ = revision
        return defaults.integer(forKey: key(counter))
    }

    var hours: [Int] {
        _ = revision
        let stored = defaults.array(forKey: Self.hoursKey) as? [Int] ?? []
        return stored.count == 24 ? stored : Array(repeating: 0, count: 24)
    }

    var since: Date {
        _ = revision
        return defaults.object(forKey: Self.sinceKey) as? Date ?? Date()
    }

    /// Calendar days since counting started, today included: one on the first day.
    func daysTogether(now: Date = Date()) -> Int {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: since), to: calendar.startOfDay(for: now)).day ?? 0
        return max(days, 0) + 1
    }

    /// The streak as it stands today: gone once a whole day passed with nothing.
    func streak(now: Date = Date()) -> Int {
        _ = revision
        guard let last = defaults.object(forKey: Self.lastDayKey) as? Date else { return 0 }
        let gap = Calendar.current.dateComponents([.day], from: last, to: Calendar.current.startOfDay(for: now)).day ?? 0
        return gap <= 1 ? defaults.integer(forKey: Self.streakKey) : 0
    }

    /// Region, window and full screen as whole percents of all shots; `nil` before the first.
    var modeShares: (favourite: Mode, region: Int, window: Int, fullScreen: Int)? {
        let shots = value(.shots)
        guard shots > 0 else { return nil }
        let window = value(.windowShots)
        let fullScreen = value(.fullScreenShots)
        let region = max(shots - window - fullScreen, 0)
        let favourite: Mode = region >= max(window, fullScreen) ? .region : (window >= fullScreen ? .window : .fullScreen)
        return (favourite, Self.percent(region, of: shots), Self.percent(window, of: shots), Self.percent(fullScreen, of: shots))
    }

    /// The colour drawn most, as its place in `colours`, and its share; `nil` before the first.
    var favouriteColour: (index: Int, percent: Int)? {
        let counts = Self.colours.map(value)
        let total = counts.reduce(0, +)
        guard total > 0, let top = counts.indices.max(by: { counts[$0] < counts[$1] })
        else { return nil }
        return (top, Self.percent(counts[top], of: total))
    }

    /// The tool that drew the most; a tie goes to the one earlier in the toolbar.
    var favouriteTool: AnnotationTool? {
        let counts = Self.drawn.map { value($0.counter) }
        guard let top = counts.indices.max(by: { counts[$0] < counts[$1] }),
              counts[top] > 0
        else { return nil }
        return Self.drawn[top].tool
    }

    /// The hour of the day with the most shots; `nil` before the first.
    var peakHour: Int? {
        let hours = hours
        guard let top = hours.indices.max(by: { hours[$0] < hours[$1] }),
              hours[top] > 0
        else { return nil }
        return top
    }

    static func percent(_ part: Int, of total: Int) -> Int {
        total > 0 ? Int((Double(part) / Double(total) * 100).rounded()) : 0
    }

    private func key(_ counter: Counter) -> String {
        "stats.\(counter.rawValue)"
    }
}
