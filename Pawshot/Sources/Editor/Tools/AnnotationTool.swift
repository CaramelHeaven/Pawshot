import AppKit

/// A toolbar tool. `select` creates nothing — it moves what is already drawn.
enum AnnotationTool: String, CaseIterable {
    case select
    case arrow
    case rectangle
    case pencil
    case text
    case blur
    case counter

    /// A single-letter hotkey. The layout is taken from CleanShot X; `D` for the pencil is the
    /// owner's request.
    var hotKey: String {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .rectangle: "r"
        case .pencil: "d"
        case .text: "t"
        case .blur: "b"
        case .counter: "n"
        }
    }

    var title: String {
        switch self {
        case .select: String(localized: "Select")
        case .arrow: String(localized: "Line")
        case .rectangle: String(localized: "Shape")
        case .pencil: String(localized: "Pencil")
        case .text: String(localized: "Text")
        case .blur: String(localized: "Blur")
        case .counter: String(localized: "Counter")
        }
    }

    /// Whether what was just drawn comes out selected, with the editor in V: a line, a rectangle or
    /// a label is usually nudged, recoloured or given other ends right after — the owner's call.
    /// The pencil, the blur and the step numbers keep their tool: strokes and numbers come in
    /// runs, and a selected stroke used to swallow the next one.
    var selectsWhatItDraws: Bool {
        switch self {
        case .arrow, .rectangle, .text: true
        case .select, .pencil, .blur, .counter: false
        }
    }

    var symbolName: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .pencil: "pencil"
        case .text: "textformat"
        case .blur: "mosaic"
        case .counter: "1.circle"
        }
    }

    var colorGroup: AnnotationColorGroup? {
        switch self {
        case .arrow, .rectangle: .shapes
        case .pencil: .pencil
        case .text: .text
        case .select, .blur, .counter: nil
        }
    }

    var cursor: NSCursor {
        switch self {
        case .select: .arrow
        case .text: .iBeam
        default: .crosshair
        }
    }

    static func tool(forHotKey key: String) -> AnnotationTool? {
        allCases.first { $0.hotKey == key.lowercased() }
    }

    /// The tool that draws objects of this kind; `select` for none.
    static func drawing(_ annotation: Annotation) -> AnnotationTool {
        switch annotation {
        case is TextAnnotation: .text
        case is ArrowAnnotation: .arrow
        case is RectangleAnnotation: .rectangle
        case is PathAnnotation: .pencil
        case is BlurAnnotation: .blur
        case is CounterAnnotation: .counter
        default: .select
        }
    }

    /// Creates an object under the cursor. `nil` means the tool doesn't draw (selection).
    @MainActor
    func makeAnnotation(at point: CGPoint, document: EditorDocument) -> Annotation? {
        switch self {
        case .select:
            nil
        case .arrow:
            ArrowAnnotation(start: point, style: document.style)
        case .rectangle:
            RectangleAnnotation(start: point, style: document.style)
        case .pencil:
            PathAnnotation(start: point, style: document.style)
        case .text:
            TextAnnotation(origin: point, style: document.style)
        case .blur:
            BlurAnnotation(
                start: point,
                style: document.style,
                mode: .blur,
                source: document.blurSource
            )
        case .counter:
            CounterAnnotation(
                center: point,
                number: document.nextCounterNumber(),
                style: document.style
            )
        }
    }

    /// Objects that are placed with a single click rather than a drag.
    var isSingleClick: Bool {
        self == .counter || self == .text
    }
}
