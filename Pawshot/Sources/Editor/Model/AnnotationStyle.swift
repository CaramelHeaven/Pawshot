import AppKit

/// How an annotation looks: colour, width, whether the inside is filled.
struct AnnotationStyle: Equatable {
    var color: NSColor
    var lineWidth: CGFloat
    var isFilled: Bool

    /// How text looks. Shapes ignore it, just as text ignores `isFilled`.
    var textStyle: TextStyle = .plain

    static let `default` = AnnotationStyle(color: Palette.colors[0], lineWidth: 3, isFilled: false)

    /// The three looks of a text label, cycled with F. Screenshot tools sell label styles rather
    /// than typography: plain letters with a soft shadow, letters with a contrasting outline that
    /// read on any background, and letters on a pill of their colour.
    enum TextStyle: CaseIterable, Equatable {
        case plain
        case outline
        case plate

        var next: TextStyle {
            let all = Self.allCases
            let index = all.firstIndex(of: self) ?? 0
            return all[(index + 1) % all.count]
        }
    }

    /// Black or white, whichever reads on `color`: white letters on a red plate, black on a
    /// yellow or white one. Decided by relative luminance, not by a list of colours, so a colour
    /// added to the palette later gets it right too.
    static func contrastingTextColor(on color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return .white }

        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(rgb.redComponent)
            + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)

        return luminance > 0.4 ? .black : .white
    }

    /// The palette on keys 1…6. Red comes first and is also the default — that's how every
    /// screenshot tool does it.
    enum Palette {
        static let colors: [NSColor] = [
            .systemRed,
            .systemOrange,
            .systemYellow,
            .systemGreen,
            .systemBlue,
            .black,
        ]

        /// The sixth key toggles black and white: a black stroke is invisible on a dark background.
        static func color(forKeyIndex index: Int, current: NSColor) -> NSColor {
            guard colors.indices.contains(index) else { return current }

            if index == colors.count - 1 {
                return current == NSColor.black ? .white : .black
            }
            return colors[index]
        }
    }

    /// Width moves in fixed steps: `[` and `]` have to produce a noticeable jump instead of
    /// creeping one point at a time.
    enum LineWidth {
        static let steps: [CGFloat] = [1, 2, 3, 5, 8, 12]

        static func next(after width: CGFloat) -> CGFloat {
            steps.first(where: { $0 > width }) ?? steps[steps.count - 1]
        }

        static func previous(before width: CGFloat) -> CGFloat {
            steps.last(where: { $0 < width }) ?? steps[0]
        }
    }
}
