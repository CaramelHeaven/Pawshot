import AppKit
import SwiftUI

extension HotKeyBinding {
    /// The same combination as a SwiftUI shortcut, so the menu can print it in its right-hand
    /// column. Only for display: the global hotkey itself stays with Carbon.
    ///
    /// `nil` for a key SwiftUI can't name (a recorded "Key 105"): an item with no shortcut is
    /// better than one printing a wrong key.
    var keyboardShortcut: KeyboardShortcut? {
        guard let key = keyEquivalent else { return nil }
        return KeyboardShortcut(key, modifiers: eventModifiers)
    }

    var eventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        let flags = modifierFlags
        if flags.contains(.command) {
            modifiers.insert(.command)
        }
        if flags.contains(.shift) {
            modifiers.insert(.shift)
        }
        if flags.contains(.option) {
            modifiers.insert(.option)
        }
        if flags.contains(.control) {
            modifiers.insert(.control)
        }

        return modifiers
    }

    private var keyEquivalent: KeyEquivalent? {
        if let named = Self.namedEquivalents[label] {
            return named
        }
        if label.count > 1, label.hasPrefix("F"), let number = Int(label.dropFirst()), (1 ... 12).contains(number),
           let scalar = UnicodeScalar(NSF1FunctionKey + number - 1)
        {
            return KeyEquivalent(Character(scalar))
        }
        guard label.count == 1, let character = label.lowercased().first else { return nil }

        return KeyEquivalent(character)
    }

    private static let namedEquivalents: [String: KeyEquivalent] = [
        "Space": .space,
        "↩": .return,
        "⇥": .tab,
        "⌫": .delete,
        "⌦": .deleteForward,
        "⎋": .escape,
        "←": .leftArrow,
        "→": .rightArrow,
        "↑": .upArrow,
        "↓": .downArrow,
        "↖": .home,
        "↘": .end,
        "⇞": .pageUp,
        "⇟": .pageDown,
    ]
}
