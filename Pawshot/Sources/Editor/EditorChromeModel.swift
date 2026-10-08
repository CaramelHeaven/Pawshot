import AppKit
import Observation

/// What the editor's SwiftUI chrome shows and what it can ask for.
///
/// `EditorWindowController` stays the owner of the truth — the document, the canvas, the window —
/// and pushes the few values the toolbar draws into this model. The toolbar never touches the
/// document directly: every button goes back through a closure the controller set, the same
/// entry points the keys use, so a click and a key press can't drift apart.
@MainActor
@Observable
final class EditorChromeModel {
    var tool: AnnotationTool = .select
    /// The selected object's style when there is one, the current style otherwise.
    var style: AnnotationStyle = .default
    /// What the selected object is, as the tool that draws it; `nil` with nothing selected.
    var selectedKind: AnnotationTool?
    /// The shape R draws now — the current style's, never a selected line's leftover.
    var drawingShapeKind: AnnotationStyle.ShapeKind = .rectangle
    /// The shot's size in pixels, in the middle of the toolbar.
    var pixelSize: CGSize = .zero
    /// ⌘D has been reading for a while: Copy Text shows a spinner. The very first reading of a
    /// freshly installed build compiles Vision's model and takes about half a minute.
    var isReadingText = false
    /// The weights of the labels' family, one button each.
    var textWeights: [NSFont.Weight] = LabelFont.systemWeights
    var customColor: NSColor = .systemPurple
    var recentColors: [NSColor] = []

    /// Shown next to the edge being dragged while the window resizes the shot; `nil` otherwise.
    var resizeChip: ResizeChip?
    /// The view scale while a trackpad magnify gesture is active; hidden as soon as it ends.
    var zoomPercent: Int?

    /// Bumped each time a resize runs into the edge of the captured display. The chip flashes red
    /// and the trackpad clicks — the pixels simply end there.
    private(set) var displayEdgeHits = 0

    func noteDisplayEdgeHit() {
        displayEdgeHits += 1
    }

    @ObservationIgnored var selectTool: (AnnotationTool) -> Void = { _ in }
    @ObservationIgnored var pickColor: (Int) -> Void = { _ in }
    @ObservationIgnored var pickLineWidth: (CGFloat) -> Void = { _ in }
    @ObservationIgnored var pickCustomColor: (NSColor) -> Void = { _ in }
    @ObservationIgnored var cycleFill: () -> Void = {}
    @ObservationIgnored var setFillOpacity: (CGFloat) -> Void = { _ in }
    /// The slider mid-drag: the fill follows it at once, and letting go (`setFillOpacity`) is the
    /// one step of ⌘Z.
    @ObservationIgnored var previewFillOpacity: (CGFloat) -> Void = { _ in }
    @ObservationIgnored var pickLineEnds: (AnnotationStyle.LineEnds) -> Void = { _ in }
    @ObservationIgnored var pickShapeKind: (AnnotationStyle.ShapeKind) -> Void = { _ in }
    @ObservationIgnored var pickTextWeight: (NSFont.Weight) -> Void = { _ in }
    @ObservationIgnored var rotate: (_ clockwise: Bool) -> Void = { _ in }
    /// Where the floating tools are, in the SwiftUI content's coordinates; `nil` when they are not
    /// floating.
    @ObservationIgnored var reportToolsFrame: (CGRect?) -> Void = { _ in }
    /// Where the shot is in the same coordinates: the reference that maps them onto the window.
    @ObservationIgnored var reportShotFrame: (CGRect) -> Void = { _ in }
    @ObservationIgnored var cycleTextStyle: () -> Void = {}
    @ObservationIgnored var undo: () -> Void = {}
    @ObservationIgnored var redo: () -> Void = {}
    @ObservationIgnored var clearAll: () -> Void = {}
    @ObservationIgnored var copy: () -> Void = {}
    @ObservationIgnored var save: () -> Void = {}
    @ObservationIgnored var copyText: () -> Void = {}

    /// Which palette slot is the current colour. Anything that isn't one of the four fixed colours
    /// is the colour of one's own.
    var colorIndex: Int {
        AnnotationStyle.Palette.colors.firstIndex(of: style.color) ?? AnnotationStyle.Palette.customIndex
    }

    /// The selected object's kind, or the tool when nothing is selected: the style capsule shows
    /// only what that kind has. A label selected under V used to get the shapes' fill, which it
    /// doesn't draw.
    var activeKind: AnnotationTool {
        selectedKind ?? tool
    }

    var showsTextControls: Bool {
        activeKind == .text
    }

    var showsLineEnds: Bool {
        activeKind == .arrow
    }

    var showsFill: Bool {
        activeKind == .rectangle
    }
}

/// The growth of the shot during one resize gesture, in pixels of the file, and which edges moved.
struct ResizeChip: Equatable {
    var widthDelta: Int
    var heightDelta: Int
    var edges: Edges
    var isAtDisplayEdge: Bool

    struct Edges: Equatable {
        var left = false
        var right = false
        var top = false
        var bottom = false
    }

    /// `+48 px`, `−12 px`, or both axes for a corner: `+48 × +20 px`.
    var text: String {
        let horizontal = edges.left || edges.right
        let vertical = edges.top || edges.bottom

        switch (horizontal, vertical) {
        case (true, true): return "\(Self.signed(widthDelta)) × \(Self.signed(heightDelta)) px"
        case (false, true): return "\(Self.signed(heightDelta)) px"
        default: return "\(Self.signed(widthDelta)) px"
        }
    }

    private static func signed(_ value: Int) -> String {
        value > 0 ? "+\(value)" : value < 0 ? "−\(-value)" : "0"
    }
}
