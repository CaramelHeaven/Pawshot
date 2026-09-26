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
    var style: AnnotationStyle = .default

    /// Shown next to the edge being dragged while the window resizes the shot; `nil` otherwise.
    var resizeChip: ResizeChip?

    /// Bumped each time a resize runs into the edge of the captured display. The chip flashes red
    /// and the trackpad clicks — the pixels simply end there.
    private(set) var displayEdgeHits = 0

    func noteDisplayEdgeHit() {
        displayEdgeHits += 1
    }

    @ObservationIgnored var selectTool: (AnnotationTool) -> Void = { _ in }
    @ObservationIgnored var pickColor: (Int) -> Void = { _ in }
    @ObservationIgnored var pickLineWidth: (CGFloat) -> Void = { _ in }
    @ObservationIgnored var toggleFill: () -> Void = {}
    @ObservationIgnored var cycleTextStyle: () -> Void = {}
    @ObservationIgnored var undo: () -> Void = {}
    @ObservationIgnored var redo: () -> Void = {}
    @ObservationIgnored var clearAll: () -> Void = {}
    @ObservationIgnored var copy: () -> Void = {}
    @ObservationIgnored var save: () -> Void = {}
    @ObservationIgnored var copyText: () -> Void = {}

    /// Which palette slot is the current colour. The sixth slot is "black or white", whichever of
    /// the two is on.
    var colorIndex: Int? {
        if style.color == .black || style.color == .white {
            return AnnotationStyle.Palette.colors.count - 1
        }
        return AnnotationStyle.Palette.colors.firstIndex(of: style.color)
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
