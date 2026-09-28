import AppKit

/// How an annotation looks: colour, width, how opaque the inside is.
struct AnnotationStyle: Equatable {
    var color: NSColor
    var lineWidth: CGFloat
    /// 0 is no fill at all, 1 is a solid one that hides what is under it. A text plate takes it
    /// too.
    var fillOpacity: CGFloat

    /// How text looks. Shapes ignore it.
    var textStyle: TextStyle = .plain

    /// Which ends of a line carry a head. Everything but the line ignores it.
    var lineEnds: LineEnds = .end

    /// What R draws: a rectangle, a circle, a triangle or a diamond. Everything but the shape
    /// ignores it.
    var shapeKind: ShapeKind = .rectangle

    /// A label's size in points, apart from the line width since the widths gave way to weights
    /// for text. 18 is what width 3 used to give.
    var textSize: CGFloat = 18

    /// A label's weight; the family is one for all labels (`LabelFont.family`).
    var textWeight: NSFont.Weight = .semibold

    var isFilled: Bool {
        fillOpacity > 0
    }

    static let `default` = AnnotationStyle(color: Palette.colors[0], lineWidth: 3, fillOpacity: 0)

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

    /// F on text: the next label style. A plate arrives solid when there was no fill to take its
    /// opacity from — an invisible plate is never what was meant.
    static func nextTextStyle(_ style: inout AnnotationStyle) {
        style.textStyle = style.textStyle.next
        if style.textStyle == .plate, style.fillOpacity == 0 {
            style.fillOpacity = 1
        }
    }

    /// The opacity slider. On a label only a plate has anything to fill, so moving the slider on a
    /// plain or outlined label makes it a plate — otherwise the slider would do nothing at all.
    static func setFillOpacity(_ opacity: CGFloat, onText: Bool, of style: inout AnnotationStyle) {
        style.fillOpacity = opacity
        if onText, style.textStyle != .plate {
            style.textStyle = .plate
        }
    }

    /// One line tool, three looks: a plain stroke, an arrow, and an arrow with a head at each end.
    /// Ordered the way A walks them once the line tool is already on.
    enum LineEnds: CaseIterable, Equatable {
        case end
        case both
        case none

        var next: LineEnds {
            let all = Self.allCases
            let index = all.firstIndex(of: self) ?? 0
            return all[(index + 1) % all.count]
        }
    }

    /// R's four shapes, the owner's pick of 2026-09-28 (Ф-A: chosen in the style capsule like the
    /// line's looks). Ordered the way R walks them once the shape tool is already on.
    enum ShapeKind: CaseIterable, Equatable {
        case rectangle
        case circle
        case triangle
        case diamond

        var next: ShapeKind {
            let all = Self.allCases
            let index = all.firstIndex(of: self) ?? 0
            return all[(index + 1) % all.count]
        }

        /// Width over height when drawn even: with ⇧, and a circle always. A triangle is
        /// equilateral.
        var evenAspect: CGFloat {
            self == .triangle ? 2 / sqrt(3) : 1
        }

        /// Always even, no sides to drag and no turning — any of them would make it an oval or
        /// change nothing. Every rule the circle has apart from the others goes by this.
        var isRound: Bool {
            self == .circle
        }
    }

    /// `[` and `]` on a label.
    enum TextSize {
        static let steps: [CGFloat] = [12, 14, 18, 24, 32, 48, 72]

        static func next(after size: CGFloat) -> CGFloat {
            steps.first(where: { $0 > size + 0.5 }) ?? max(size, steps[steps.count - 1])
        }

        static func previous(before size: CGFloat) -> CGFloat {
            steps.last(where: { $0 < size - 0.5 }) ?? min(size, steps[0])
        }
    }

    /// F walks these; the slider in the toolbar sets anything in between.
    enum FillOpacity {
        static let steps: [CGFloat] = [0, 0.3, 0.6, 1]

        /// The next step up from wherever the slider left it, and back to none after solid.
        static func next(after opacity: CGFloat) -> CGFloat {
            steps.first(where: { $0 > opacity + 0.001 }) ?? steps[0]
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

    /// The palette on keys 1…4, the owner's choice: red for "wrong", green for "right", white and
    /// black for anything on a dark or a light background. Key 5 is a colour of one's own, picked
    /// in the toolbar. Red comes first and is also the default — that's how every screenshot tool
    /// does it.
    enum Palette {
        static let colors: [NSColor] = [
            .systemRed,
            .systemGreen,
            .white,
            .black,
        ]

        /// The slot after the fixed colours: the key and the swatch of the custom colour.
        static var customIndex: Int {
            colors.count
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
