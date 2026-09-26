import AppKit
import Carbon.HIToolbox
@testable import Pawshot
import XCTest

/// The editor's keys are single letters — `V` for select, `B` for blur — and they used to be read
/// off the character the layout produced. On ЙЦУКЕН that character is `м`, `и`, `ф`, and not one
/// tool ever switched.
///
/// These tests translate a key code through the machine's **ASCII-capable** layout, so they assume
/// a Latin layout is installed alongside whatever else. Every Mac has one; a machine carrying
/// Dvorak as its only Latin layout would answer `j` where these expect `c`.
final class KeyboardLayoutTests: XCTestCase {
    private func keyEvent(keyCode: Int, characters: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: UInt16(keyCode)
        ))
    }

    func testCyrillicEmIsTheSelectToolKey() throws {
        let event = try keyEvent(keyCode: kVK_ANSI_V, characters: "м")

        XCTAssertEqual(KeyboardLayout.latinCharacter(for: event), "v")
    }

    func testCyrillicEsIsTheClearAllKey() throws {
        let event = try keyEvent(keyCode: kVK_ANSI_C, characters: "с")

        XCTAssertEqual(KeyboardLayout.latinCharacter(for: event), "c")
    }

    /// `[` and `]` step the line width, and in ЙЦУКЕН they print `х` and `ъ`.
    func testCyrillicKhaIsTheLeftBracket() throws {
        let event = try keyEvent(keyCode: kVK_ANSI_LeftBracket, characters: "х")

        XCTAssertEqual(KeyboardLayout.latinCharacter(for: event), "[")
    }

    /// A Latin layout is handed back untouched. Translating the key code there too would break
    /// Dvorak, where the letter on the key is the whole point and is not the one ANSI names.
    func testALatinCharacterIsLeftAlone() throws {
        let event = try keyEvent(keyCode: kVK_ANSI_V, characters: "v")

        XCTAssertEqual(KeyboardLayout.latinCharacter(for: event), "v")
    }

    /// The number row prints digits in both layouts, so the palette keys were never broken — this
    /// pins that fixing the letters did not break them either.
    func testDigitsSurviveUnchanged() throws {
        let event = try keyEvent(keyCode: kVK_ANSI_3, characters: "3")

        XCTAssertEqual(KeyboardLayout.latinCharacter(for: event), "3")
    }

    // MARK: - Rewriting a whole event

    /// ⌘-combinations are matched by the menu, not by the canvas, so the fallback rewrites the
    /// event rather than looking the shortcut up in a table of its own. Everything but the
    /// characters has to survive, or the menu matches the wrong item — or none.
    func testACyrillicCommandEventIsRewrittenToLatin() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 7,
            context: nil,
            characters: "я",
            charactersIgnoringModifiers: "я",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_Z)
        ))

        let rewritten = try XCTUnwrap(KeyboardLayout.latinEquivalent(of: event))

        XCTAssertEqual(rewritten.charactersIgnoringModifiers, "z")
        XCTAssertEqual(rewritten.keyCode, UInt16(kVK_ANSI_Z))
        XCTAssertEqual(rewritten.modifierFlags.intersection([.command, .shift]), [.command, .shift])
    }

    /// Nothing to rewrite means nothing is returned, so the caller knows to stand aside and let
    /// the usual machinery have the event.
    func testALatinEventIsNotRewritten() throws {
        let event = try keyEvent(keyCode: kVK_ANSI_C, characters: "c")

        XCTAssertNil(KeyboardLayout.latinEquivalent(of: event))
    }
}
