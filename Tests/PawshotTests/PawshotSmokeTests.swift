import AppKit
@testable import Pawshot
import XCTest

final class PawshotSmokeTests: XCTestCase {
    /// If the asset never reaches the bundle, the menu bar button stays an empty clickable spot.
    /// Template mode is checked too: without it the icon won't tint for a dark menu bar.
    func testStatusItemIconLoads() {
        let icon = NSImage(resource: .menuBarIcon)

        XCTAssertTrue(icon.isTemplate)
        XCTAssertEqual(icon.size, NSSize(width: 18, height: 18))
    }

    /// SwiftUI builds the main menu, and replacing its Save group took Close along with it: ⌘W
    /// stopped closing the editor. The test host is the app itself, so its menu is the real one.
    @MainActor
    func testMainMenuKeepsTheEditorShortcuts() throws {
        let menu = try XCTUnwrap(NSApp.mainMenu)
        func item(_ submenu: String, keyEquivalent: String) -> NSMenuItem? {
            menu.item(withTitle: submenu)?.submenu?.items.first {
                $0.keyEquivalent == keyEquivalent && $0.keyEquivalentModifierMask == [.command]
            }
        }

        XCTAssertEqual(item("File", keyEquivalent: "w")?.title, "Close Window")
        XCTAssertEqual(item("File", keyEquivalent: "s")?.title, "Save to Desktop")
        XCTAssertEqual(item("Edit", keyEquivalent: "z")?.title, "Undo")
        XCTAssertEqual(item("Edit", keyEquivalent: "c")?.title, "Copy")
        XCTAssertEqual(item("Edit", keyEquivalent: "d")?.title, "Copy Text")
    }

    /// The capturing and text-copied variants are drawn in code from the same asset. A variant that
    /// loses template mode turns into a black blob on a dark menu bar.
    @MainActor
    func testMenuBarIconVariantsStayTemplates() {
        for icon in [MenuBarIcon.capturing, MenuBarIcon.textCopied] {
            XCTAssertTrue(icon.isTemplate)
            XCTAssertEqual(icon.size, MenuBarIcon.normal.size)
            XCTAssertFalse(icon.representations.isEmpty, "the variant was never drawn")
        }
    }
}
