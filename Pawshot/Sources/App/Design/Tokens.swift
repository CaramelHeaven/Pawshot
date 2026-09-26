import AppKit
import SwiftUI

/// The few values the whole app shares, so a colour or a duration is decided once.
///
/// Text sizes are deliberately absent: every label uses a system text style (`.body`, `.title3`,
/// `.largeTitle`) and every number `.monospacedDigit()`, so there is no private type scale to keep
/// in sync with the platform.
enum Tokens {
    /// The orange of the app icon. The only tinted colour in the chrome: it marks the one primary
    /// action and the current selection. Tint anything else and nothing stands out any more.
    static let pawNSColor = NSColor(srgbRed: 0xF0 / 255, green: 0x7F / 255, blue: 0x2E / 255, alpha: 1)
    static let paw = Color(nsColor: pawNSColor)

    enum Radius {
        /// Floating panels: the permission window's drag card, the About tile.
        static let panel: CGFloat = 20
        /// A single row or key cap inside a panel.
        static let row: CGFloat = 10
        static let keyCap: CGFloat = 6
    }

    enum Motion {
        /// ⌘C, ⌘S, ⌘D: the window dissolves instead of vanishing. Short enough that the hand,
        /// already on its way to another app, never waits for it.
        static let dissolve: TimeInterval = 0.15
        static let enter: TimeInterval = 0.18
        static let exit: TimeInterval = 0.12
        /// Only for things that arrive: a slight overshoot reads as physical. Leaving is always a
        /// plain ease, never a bounce.
        static let arrival = Animation.spring(response: 0.42, dampingFraction: 0.8)
    }
}
