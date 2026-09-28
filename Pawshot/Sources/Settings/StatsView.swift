import AppKit
import SwiftUI

/// Settings → Statistics, the owner's L-B: the number of shots big on a paw-coloured card, then
/// tiles in sections of three. A tile at zero says how to get it going instead of its joke — the
/// numbers double as a list of what Pawshot can do.
struct StatsView: View {
    private let stats = Stats.shared
    private let settings = Settings.shared
    @State private var isConfirmingReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                section("Screenshots", rows: [[modeTile], [cancelsTile, textTile, edgeTile]])
                section("Drawing", rows: drawingTiles.chunked(by: 3))
                section("Video", rows: [[recordedTile, restartsTile, pausesTile]])
                section("Other", rows: [[quitTile, peakTile, streakTile]])
                footer
            }
            .padding(20)
        }
        .frame(height: 720)
        .confirmationDialog("Reset the statistics?", isPresented: $isConfirmingReset) {
            Button("Reset", role: .destructive) {
                stats.reset()
            }
        } message: {
            Text("Every number goes back to zero, and the count starts today.")
        }
    }

    // MARK: - Layout

    private var hero: some View {
        let shots = stats.value(.shots)
        return HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(shots, format: .number)
                    .font(.system(size: 40, weight: .heavy))
                    .monospacedDigit()
                Group {
                    if shots == 0 {
                        Text("Press \(settings.regionHotKey.displayString) and pick a region.")
                    } else {
                        Text("Screenshots · since \(stats.since.formatted(.dateTime.day().month(.wide))) · \(Self.days(stats.daysTogether()))")
                    }
                }
                .font(.callout.weight(.semibold))
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .foregroundStyle(.black.opacity(0.85))
        .background(Tokens.paw.gradient, in: .rect(cornerRadius: Tokens.Radius.panel))
    }

    private func section(_ title: LocalizedStringKey, rows: [[Tile]]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            ForEach(rows.indices, id: \.self) { index in
                // Fixed vertically, so every tile in a row is as tall as the tallest one.
                HStack(alignment: .top, spacing: 10) {
                    ForEach(rows[index]) { tile in
                        StatTile(tile: tile)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Counted on this Mac only.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Reset Statistics…") {
                isConfirmingReset = true
            }
        }
    }

    // MARK: - Screenshots

    private var modeTile: Tile {
        guard let shares = stats.modeShares else {
            return .zero("rectangle.dashed", "Favourite mode", String(localized: "\(settings.regionHotKey.displayString) for a region, Space for a window, \(settings.fullScreenHotKey.displayString) for the whole screen."))
        }
        let name = switch shares.favourite {
        case .region: String(localized: "Region")
        case .window: String(localized: "Window")
        case .fullScreen: String(localized: "Full screen")
        }
        return Tile(
            symbol: "rectangle.dashed",
            value: name,
            caption: "Favourite mode",
            line: String(localized: "Region \(shares.region)% · window \(shares.window)% · full screen \(shares.fullScreen)%")
        )
    }

    private var cancelsTile: Tile {
        count(.cancels, "xmark.circle", "Cancelled", joke: String(localized: "Got off the hook."), hint: String(localized: "Esc or a right click cancels a shot."))
    }

    private var textTile: Tile {
        let characters = stats.value(.recognizedCharacters)
        guard characters > 0 else {
            return .zero("text.viewfinder", "Text read with ⌘D", String(localized: "⌘D in the editor copies the text off the shot."))
        }
        let pages = Int((Double(characters) / Double(Stats.charactersPerPage)).rounded())
        let value = characters < Stats.charactersPerPage ? String(localized: "\(characters) chars") : String(localized: "≈ \(pages) pp.")
        return Tile(symbol: "text.viewfinder", value: value, caption: "Text read with ⌘D", line: String(localized: "A novel you didn't write."))
    }

    private var edgeTile: Tile {
        count(.edgeFits, "arrow.up.left.and.arrow.down.right", "Fixed by the window edge", joke: String(localized: "Missed by a few pixels, pulled the edge."), hint: String(localized: "Missed? Drag the editor window's edge."))
    }

    // MARK: - Drawing

    private var drawingTiles: [Tile] {
        [
            count(.arrows, AnnotationTool.arrow.symbolName, "Arrows", joke: String(localized: "Robin Hood is getting nervous."), hint: String(localized: "A in the editor draws an arrow.")),
            count(.rectangles, AnnotationTool.rectangle.symbolName, "Boxes", joke: String(localized: "Circled everything that wasn't nailed down."), hint: String(localized: "R draws a box.")),
            count(.strokes, AnnotationTool.pencil.symbolName, "Scribbles", joke: String(localized: "A doctor's handwriting, surely."), hint: String(localized: "D is the pencil.")),
            count(.labels, AnnotationTool.text.symbolName, "Labels", joke: String(localized: "Not a single typo. Probably."), hint: String(localized: "T writes a label.")),
            count(.blurs, AnnotationTool.blur.symbolName, "Blurred secrets", joke: String(localized: "Passwords, emails and strangers' faces."), hint: String(localized: "B hides passwords and emails.")),
            count(.steps, AnnotationTool.counter.symbolName, "Step numbers", joke: String(localized: "Enough for an IKEA wardrobe."), hint: String(localized: "N numbers the steps.")),
            count(.undos, "arrow.uturn.backward", "⌘Z presses", joke: String(localized: "Changing your mind is fine."), hint: String(localized: "⌘Z takes a step back. Don't be shy.")),
            colourTile,
            toolTile,
        ]
    }

    private var colourTile: Tile {
        guard let favourite = stats.favouriteColour else {
            return .zero("paintpalette", "Favourite colour", String(localized: "1–5 in the editor switch colours."), value: "—")
        }
        let names = [
            String(localized: "Red"), String(localized: "Green"), String(localized: "White"),
            String(localized: "Black"), String(localized: "Your own"),
        ]
        return Tile(symbol: "paintpalette", value: names[favourite.index], caption: "Favourite colour", line: String(localized: "\(favourite.percent)% of everything drawn"))
    }

    private var toolTile: Tile {
        guard let tool = stats.favouriteTool else {
            return .zero("star", "Favourite tool", String(localized: "Draw something and we'll see."), value: "—")
        }
        let rank = switch tool {
        case .arrow: String(localized: "Chief archer.")
        case .rectangle: String(localized: "Master of boxes.")
        case .pencil: String(localized: "An artist.")
        case .text: String(localized: "A writer.")
        case .blur: String(localized: "Keeper of secrets.")
        case .counter, .select: String(localized: "Author of manuals.")
        }
        return Tile(symbol: "star", value: tool.title, caption: "Favourite tool", line: rank)
    }

    // MARK: - Video

    private var recordedTile: Tile {
        let seconds = stats.value(.recordedSeconds)
        let recordings = stats.value(.recordings)
        guard recordings > 0 else {
            return .zero("video", "Recorded", String(localized: "\(settings.recordRegionHotKey.displayString) records a region."), value: Self.duration(0))
        }
        let episodes = seconds / Stats.episodeSeconds
        let line = episodes > 0
            ? String(localized: "Videos: \(recordings) · ≈ The Simpsons × \(episodes)")
            : String(localized: "Videos: \(recordings) · shorter than an episode of The Simpsons so far")
        return Tile(symbol: "video", value: Self.duration(seconds), caption: "Recorded", line: line)
    }

    private var restartsTile: Tile {
        count(.restarts, "arrow.counterclockwise", "Restarts", joke: String(localized: "Take two. And three."), hint: String(localized: "\(settings.restartHotKey.displayString) starts the take over."))
    }

    private var pausesTile: Tile {
        count(.pauses, "pause.circle", "Pauses", joke: String(localized: "Breaks off camera."), hint: String(localized: "The pause button on the pill stops the clock."))
    }

    // MARK: - Other

    private var quitTile: Tile {
        count(.quitsCalledOff, "hand.raised", "⌘Q rescues", joke: String(localized: "Almost quit, let go just in time."), hint: String(localized: "Hold ⌘Q to quit; let go early to stay."))
    }

    private var peakTile: Tile {
        guard let hour = stats.peakHour,
              let time = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())
        else {
            return .zero("clock", "Peak hour", String(localized: "We'll know after a few shots."), value: "—")
        }
        let value = time.formatted(date: .omitted, time: .shortened)
        return switch hour {
        case 5 ..< 11: Tile(symbol: "sunrise", value: value, caption: "Peak hour", line: String(localized: "Early bird: shots before breakfast."))
        case 11 ..< 22: Tile(symbol: "sun.max", value: value, caption: "Peak hour", line: String(localized: "Pigeon: shots at the height of the day."))
        default: Tile(symbol: "moon.stars", value: value, caption: "Peak hour", line: String(localized: "Night owl: the best shots come at night."))
        }
    }

    private var streakTile: Tile {
        let streak = stats.streak()
        guard streak > 0 else {
            return .zero("flame", "Days in a row", String(localized: "Take a shot every day and we'll count the streak."), value: Self.days(0))
        }
        return Tile(symbol: "flame", value: Self.days(streak), caption: "Days in a row", line: String(localized: "The streak holds."))
    }

    // MARK: - Helpers

    /// A plain count: the number and its joke, or a muted zero and the way to get it.
    private func count(_ counter: Stats.Counter, _ symbol: String, _ caption: LocalizedStringKey, joke: String, hint: String) -> Tile {
        let value = stats.value(counter)
        return Tile(symbol: symbol, value: value.formatted(), caption: caption, line: value > 0 ? joke : hint, isZero: value == 0)
    }

    /// "41 days", declined by the locale — no hand-made plurals.
    private static func days(_ days: Int) -> String {
        Duration.seconds(Double(days) * 86400).formatted(.units(allowed: [.days], width: .wide))
    }

    /// "2 hr 14 min".
    private static func duration(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }
}

private struct Tile: Identifiable {
    let symbol: String
    let value: String
    let caption: LocalizedStringKey
    let line: String
    var isZero = false

    var id: String {
        symbol + line
    }

    static func zero(_ symbol: String, _ caption: LocalizedStringKey, _ hint: String, value: String = 0.formatted()) -> Tile {
        Tile(symbol: symbol, value: value, caption: caption, line: hint, isZero: true)
    }
}

private struct StatTile: View {
    let tile: Tile

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: tile.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.paw)
                .frame(width: 26, height: 26)
                .background(Tokens.paw.opacity(0.16), in: .rect(cornerRadius: 7))
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            Text(tile.value)
                .font(.title2.bold())
                .monospacedDigit()
                .foregroundStyle(tile.isZero ? .secondary : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(tile.caption)
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(tile.line)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.fill.quinary, in: .rect(cornerRadius: Tokens.Radius.row))
        .accessibilityElement(children: .combine)
    }
}

private extension Array {
    func chunked(by size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
    }
}
