import Foundation

/// Turns the lines Vision recognised back into text.
///
/// Vision gives one observation per line of the shot, already grouped by column and ordered top to
/// bottom inside a column — so the order is taken as given here, and the only work left is the
/// shape: where a blank line was, where a column ended, and how far a line was indented. All of it
/// comes out of the boxes, which is why this is a pure function and carries the tests.
enum TextLayout {
    struct Line {
        let text: String
        /// The line's frame in **pixels of the shot**, origin at the bottom left — the way Vision
        /// reports it, scaled up by the caller.
        ///
        /// Pixels and not Vision's normalized coordinates on purpose: there X and Y are scaled by
        /// different numbers on a non-square shot, and a formula that puts a width next to a
        /// height would be quietly wrong on every screenshot that isn't square.
        let box: CGRect
    }

    /// A gap taller than this many line steps means there was an empty line.
    private static let blankLineThreshold: CGFloat = 1.6

    /// Vision reads `<=` as `‹=`. This is the one OCR defect worth undoing blindly: U+2039 does
    /// not occur in a screenshot of anything real, while `<=` occurs in every other line of code.
    /// `->` losing its dash is left alone — restoring that would be guessing.
    private static let substitutions: [(Character, Character)] = [("‹", "<")]

    static func assemble(_ lines: [Line]) -> String {
        guard !lines.isEmpty else { return "" }

        let pitch = linePitch(of: lines)
        let charWidth = characterWidth(of: lines)
        let columnBreaks = columnBreaks(in: lines, pitch: pitch)
        let origins = columnOrigins(of: lines, breaks: columnBreaks)

        var out: [String] = []

        for (index, line) in lines.enumerated() {
            if index > 0 {
                if columnBreaks.contains(index) {
                    out.append("")
                } else if pitch > 0 {
                    let gap = lines[index - 1].box.midY - line.box.midY
                    if gap > pitch * blankLineThreshold {
                        out.append("")
                    }
                }
            }

            out.append(indent(line, originX: origins[index], charWidth: charWidth))
        }

        return out.joined(separator: "\n")
    }

    // MARK: - Measurements

    /// The distance between neighbouring lines. Only downward steps count: a step back up the shot
    /// is a new column, not a line of text, and letting it into the median would drag the whole
    /// threshold off.
    private static func linePitch(of lines: [Line]) -> CGFloat {
        let steps = zip(lines, lines.dropFirst())
            .map { $0.box.midY - $1.box.midY }
            .filter { $0 > 0 }

        return median(of: steps)
    }

    /// How wide one character is, taken as a line's width over its length. The median keeps a
    /// short line from skewing it, and lines under nine characters are left out for the same
    /// reason.
    private static func characterWidth(of lines: [Line]) -> CGFloat {
        let widths = lines
            .filter { $0.text.count > 8 }
            .map { $0.box.width / CGFloat($0.text.count) }

        return median(of: widths)
    }

    private static func median(of values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[values.count / 2]
    }

    // MARK: - Columns

    /// The indexes where a new column starts — the places where the next line sits *higher* on the
    /// shot than the one before it, which no continuation of the same column ever does. Half a
    /// line step of tolerance absorbs the jitter of a box that hugs its glyphs: a line without
    /// descenders sits a couple of pixels above its neighbours.
    private static func columnBreaks(in lines: [Line], pitch: CGFloat) -> Set<Int> {
        guard pitch > 0 else { return [] }

        var breaks: Set<Int> = []
        for index in 1 ..< lines.count {
            let step = lines[index - 1].box.midY - lines[index].box.midY
            if step < -pitch / 2 {
                breaks.insert(index)
            }
        }

        return breaks
    }

    /// Column zero for every line, measured **per column** rather than across the whole shot.
    /// Against the leftmost line of the shot, the second column of a two-column screenshot would
    /// come out indented by some forty spaces — that is the layout, not the text.
    private static func columnOrigins(of lines: [Line], breaks: Set<Int>) -> [CGFloat] {
        var origins = [CGFloat](repeating: 0, count: lines.count)
        var start = 0

        for end in 1 ... lines.count where end == lines.count || breaks.contains(end) {
            let origin = lines[start ..< end].map(\.box.minX).min() ?? 0
            for index in start ..< end {
                origins[index] = origin
            }
            start = end
        }

        return origins
    }

    // MARK: - Text

    private static func indent(_ line: Line, originX: CGFloat, charWidth: CGFloat) -> String {
        var text = line.text
        for (from, to) in substitutions {
            text = text.replacingOccurrences(of: String(from), with: String(to))
        }

        guard charWidth > 0 else { return text }

        let spaces = Int(((line.box.minX - originX) / charWidth).rounded())
        guard spaces > 0 else { return text }

        return String(repeating: " ", count: spaces) + text
    }
}
