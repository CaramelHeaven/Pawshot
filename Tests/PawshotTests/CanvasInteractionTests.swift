@testable import Pawshot
import XCTest

final class CanvasInteractionTests: XCTestCase {
    /// A drawing tool always draws, even over a selected object: draw, release, draw again on top
    /// of what was just drawn. Moving takes V or a held ⌘ — the same drag must never mean "draw" one
    /// moment and "move" the next depending on a selection the user can't see coming.
    func testDrawingToolAlwaysDrawsWithoutCommand() {
        for tool in [AnnotationTool.pencil, .rectangle, .arrow, .blur, .counter] {
            XCTAssertEqual(CanvasInteraction.decide(tool: tool, isOverSelection: true, commandHeld: false), .draw)
            XCTAssertEqual(CanvasInteraction.decide(tool: tool, isOverSelection: false, commandHeld: false), .draw)
        }
    }

    /// Holding ⌘ turns any drawing tool into a temporary move tool, the way Photoshop springs to
    /// Move: grab what is under the cursor, or keep dragging the selection.
    func testHeldCommandMovesUnderADrawingTool() {
        XCTAssertEqual(
            CanvasInteraction.decide(tool: .pencil, isOverSelection: false, commandHeld: true),
            .selectUnderCursor
        )
        XCTAssertEqual(
            CanvasInteraction.decide(tool: .rectangle, isOverSelection: true, commandHeld: true),
            .moveSelection
        )
    }

    func testSelectToolPicksWhatIsUnderCursor() {
        XCTAssertEqual(
            CanvasInteraction.decide(tool: .select, isOverSelection: false, commandHeld: false),
            .selectUnderCursor
        )
        XCTAssertEqual(
            CanvasInteraction.decide(tool: .select, isOverSelection: true, commandHeld: false),
            .moveSelection
        )
    }

    /// A regression guard for the future: add a tool bound to "c" and this test fails before
    /// "clear all" silently stops working.
    func testClearAllHotKeyDoesNotClashWithTools() {
        XCTAssertNil(AnnotationTool.tool(forHotKey: "c"))
    }

    /// In the middle of an unfilled rectangle `hitTest` is false, yet dragging the selected shape
    /// there with V still has to work — the grab area comes from the selection frame.
    @MainActor
    func testSelectionFrameCatchesCenterWhereHitTestDoesNot() {
        let rectangle = RectangleAnnotation(start: CGPoint(x: 0, y: 0), style: .default)
        rectangle.update(to: CGPoint(x: 100, y: 100))
        let center = CGPoint(x: 50, y: 50)

        XCTAssertFalse(rectangle.hitTest(center, tolerance: 4), "nothing on the outline there")
        XCTAssertTrue(rectangle.selectionFrame.contains(center), "but the selection frame catches it")

        XCTAssertEqual(
            CanvasInteraction.decide(
                tool: .select,
                isOverSelection: rectangle.selectionFrame.contains(center),
                commandHeld: false
            ),
            .moveSelection
        )
    }
}
