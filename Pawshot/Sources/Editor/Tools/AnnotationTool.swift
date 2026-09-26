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
        case .select: "Select"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .pencil: "Pencil"
        case .text: "Text"
        case .blur: "Blur"
        case .counter: "Counter"
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
