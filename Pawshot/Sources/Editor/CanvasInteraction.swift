import Foundation

/// What a mouse press in the canvas means. Pulled out of the view so the "move or draw" rule can
/// be covered by a test — the mouse and trackpad gestures are unavailable in tests.
enum CanvasInteraction {
    enum Kind: Equatable {
        /// Dragging an already selected object.
        case moveSelection
        /// Drawing a new object with the active tool.
        case draw
        /// The selection tool: pick whatever is under the cursor.
        case selectUnderCursor
    }

    /// A drawing tool always draws: draw, release, draw again — on top of the last stroke too.
    /// Moving is V, or a held ⌘, which turns any drawing tool into a temporary move tool.
    ///
    /// It used to be that a selected object moved under any tool, and every new object came out
    /// selected — so a second pencil stroke started inside the first one's frame moved the first
    /// instead of drawing. No app surveyed combines "the tool stays" with "the new object is
    /// selected and a drag moves it"; the ones that keep the tool don't select what was drawn.
    ///
    /// The line, the rectangle and the label don't keep the tool: once drawn they come out
    /// selected with the editor in V (`AnnotationTool.selectsWhatItDraws`), so the question of a
    /// drag inside a fresh frame never comes up for them.
    static func decide(tool: AnnotationTool, isOverSelection: Bool, commandHeld: Bool) -> Kind {
        guard tool == .select || commandHeld else { return .draw }
        return isOverSelection ? .moveSelection : .selectUnderCursor
    }
}
