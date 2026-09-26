@testable import Pawshot
import XCTest

/// The whole of the text-recognition logic lives in `TextLayout`, so the whole of its testing
/// lives here. Vision itself is not exercised: it needs the Neural Engine and gives a different
/// answer on a different machine.
///
/// The fixtures are **measured**, not invented — they are the bounding boxes Vision returned for
/// rendered screenshots during the spike, so a change in the heuristics shows up here as the
/// screenshot assembling back into something other than its source.
final class TextLayoutTests: XCTestCase {
    /// Vision reports a box in normalized coordinates with the origin at the bottom left, as
    /// `minX…maxX` horizontally and `minY` plus a height vertically. `TextLayout` works in pixels,
    /// because normalized X and Y are scaled differently on a non-square shot and must never meet
    /// in the same formula.
    private func line(
        _ text: String,
        x: CGFloat,
        maxX: CGFloat,
        y: CGFloat,
        height: CGFloat,
        in size: CGSize
    ) -> TextLayout.Line {
        TextLayout.Line(
            text: text,
            box: CGRect(
                x: x * size.width,
                y: y * size.height,
                width: (maxX - x) * size.width,
                height: height * size.height
            )
        )
    }

    // MARK: - Nothing to assemble

    func testEmptyInputGivesEmptyString() {
        XCTAssertEqual(TextLayout.assemble([]), "")
    }

    // MARK: - Indentation

    func testIndentationIsRestoredFromTheLeftmostLine() {
        let size = CGSize(width: 1000, height: 100)
        let lines = [
            line("alpha beta gamma", x: 0.1, maxX: 0.26, y: 0.80, height: 0.1, in: size),
            line("delta epsilon zed", x: 0.14, maxX: 0.31, y: 0.60, height: 0.1, in: size),
            line("eta theta iotaaa", x: 0.1, maxX: 0.26, y: 0.40, height: 0.1, in: size),
        ]

        XCTAssertEqual(
            TextLayout.assemble(lines),
            """
            alpha beta gamma
                delta epsilon zed
            eta theta iotaaa
            """
        )
    }

    // MARK: - Blank lines

    func testABiggerVerticalGapBecomesABlankLine() {
        let size = CGSize(width: 1000, height: 400)
        let lines = [
            line("first line here", x: 0.1, maxX: 0.25, y: 0.80, height: 0.05, in: size),
            line("second line here", x: 0.1, maxX: 0.26, y: 0.75, height: 0.05, in: size),
            line("third line here", x: 0.1, maxX: 0.25, y: 0.70, height: 0.05, in: size),
            line("after the break!", x: 0.1, maxX: 0.26, y: 0.60, height: 0.05, in: size),
        ]

        XCTAssertEqual(
            TextLayout.assemble(lines),
            """
            first line here
            second line here
            third line here

            after the break!
            """
        )
    }

    func testEvenlySpacedLinesGetNoBlankLine() {
        let size = CGSize(width: 1000, height: 400)
        let lines = [
            line("first line here", x: 0.1, maxX: 0.25, y: 0.80, height: 0.05, in: size),
            line("second line here", x: 0.1, maxX: 0.26, y: 0.75, height: 0.05, in: size),
            line("third line here", x: 0.1, maxX: 0.25, y: 0.70, height: 0.05, in: size),
            line("fourth line here", x: 0.1, maxX: 0.26, y: 0.65, height: 0.05, in: size),
        ]

        XCTAssertEqual(
            TextLayout.assemble(lines),
            """
            first line here
            second line here
            third line here
            fourth line here
            """
        )
    }

    // MARK: - Substitutions

    /// Vision reads `<=` as `‹=` — a single left-pointing angle quotation mark. It is the one OCR
    /// defect worth undoing blindly: U+2039 does not occur in a screenshot of anything real.
    func testGuillemetBecomesLessThan() {
        let size = CGSize(width: 1000, height: 100)
        let lines = [
            line("if a ‹= b { return }", x: 0.1, maxX: 0.3, y: 0.5, height: 0.1, in: size),
        ]

        XCTAssertEqual(TextLayout.assemble(lines), "if a <= b { return }")
    }

    // MARK: - Measured: a code screenshot

    /// The boxes Vision returned for a 1240×520 shot of a Swift snippet.
    ///
    /// Two things are pinned here on purpose. The indentation comes back as exactly four spaces,
    /// and there is **no** blank line between `let corrected` and `return corrected` — an earlier
    /// version measured the gap against the box height and invented one, because Vision's boxes
    /// hug the glyphs and a line without descenders is shorter than its neighbours.
    ///
    /// The closing `}` is absent from the expectation because Vision does not see it: a lone brace
    /// on its own line is not recognised as text, and lowering `minimumTextHeightFraction` does not
    /// bring it back.
    func testMeasuredCodeScreenshotAssemblesBackIntoItsSource() {
        let size = CGSize(width: 1240, height: 520)
        let lines = [
            line(
                "func dropTarget(from source: Int, to index: Int) > Int? {",
                x: 0.039, maxX: 0.790, y: 0.847, height: 0.071, in: size
            ),
            line(
                "guard source != index else { return nil }",
                x: 0.087, maxX: 0.625, y: 0.782, height: 0.069, in: size
            ),
            line(
                "// Chrome inserts first and removes afterwards.",
                x: 0.090, maxX: 0.700, y: 0.638, height: 0.060, in: size
            ),
            line(
                "let corrected = source ‹ index ? index - 1 : index",
                x: 0.090, maxX: 0.739, y: 0.573, height: 0.050, in: size
            ),
            line(
                "return corrected",
                x: 0.090, maxX: 0.297, y: 0.504, height: 0.042, in: size
            ),
            line(
                "let url = \"https://example.com/a/b?c=1&d=2\"",
                x: 0.037, maxX: 0.600, y: 0.287, height: 0.060, in: size
            ),
            line(
                "let total = items.reduce(0) { $0 + $1.count }",
                x: 0.038, maxX: 0.629, y: 0.208, height: 0.070, in: size
            ),
            line(
                "print(\"done: \\(total) items, \\(url)\")",
                x: 0.039, maxX: 0.516, y: 0.123, height: 0.065, in: size
            ),
        ]

        XCTAssertEqual(
            TextLayout.assemble(lines),
            """
            func dropTarget(from source: Int, to index: Int) > Int? {
                guard source != index else { return nil }

                // Chrome inserts first and removes afterwards.
                let corrected = source < index ? index - 1 : index
                return corrected

            let url = "https://example.com/a/b?c=1&d=2"
            let total = items.reduce(0) { $0 + $1.count }
            print("done: \\(total) items, \\(url)")
            """
        )
    }

    // MARK: - Measured: two columns

    /// The boxes Vision returned for a 1280×280 shot of two columns of text.
    ///
    /// Vision hands the columns over one after another rather than scanning across the shot, so
    /// the order needs no work — this pins that the order is left untouched, and that the columns
    /// are told apart by a blank line.
    ///
    /// The second column also pins why column zero is measured **per column**: against the
    /// leftmost line of the whole shot the right-hand column would be indented by some forty
    /// spaces, which is the layout, not the text.
    func testColumnsAreSeparatedAndNeverInterleaved() {
        let size = CGSize(width: 1280, height: 280)
        let lines = [
            line("Left column one", x: 0.037, maxX: 0.191, y: 0.721, height: 0.079, in: size),
            line("Left column two", x: 0.037, maxX: 0.189, y: 0.586, height: 0.079, in: size),
            line("Left column three", x: 0.037, maxX: 0.205, y: 0.450, height: 0.079, in: size),
            line("Left column four", x: 0.037, maxX: 0.194, y: 0.314, height: 0.079, in: size),
            line("Right column one", x: 0.531, maxX: 0.697, y: 0.707, height: 0.093, in: size),
            line("Right column two", x: 0.533, maxX: 0.695, y: 0.579, height: 0.086, in: size),
            line("Right column three", x: 0.531, maxX: 0.711, y: 0.443, height: 0.086, in: size),
            line("Right column four", x: 0.531, maxX: 0.702, y: 0.307, height: 0.086, in: size),
        ]

        XCTAssertEqual(
            TextLayout.assemble(lines),
            """
            Left column one
            Left column two
            Left column three
            Left column four

            Right column one
            Right column two
            Right column three
            Right column four
            """
        )
    }
}
