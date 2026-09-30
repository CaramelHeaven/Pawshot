import SwiftUI

extension EnvironmentValues {
    /// Where the mouse is, in the `ChromeButtonStyle.space` of the piece of chrome it is over;
    /// `nil` when it is elsewhere. Supplied by whoever owns the piece — see `ChromeButtonStyle`.
    @Entry var chromeHoverPoint: CGPoint?
}

/// A button on a piece of dark glass that floats over the screen — the recording toolbar, its
/// Options, the pill of a take: it lights up under the cursor and gives way under a press.
///
/// Those buttons used to be `.plain`, which answers the mouse with nothing at all: a row of icons
/// that looked like a picture of a toolbar.
///
/// The hover does not come from SwiftUI's `onHover`. Both places live in a panel of an app that is
/// not the active one — the capture overlay never activates Pawshot, and the pill floats over
/// whatever is being recorded — and whether hover reaches a view there is not something to lean
/// on. The owner already knows where the mouse is (the overlay tracks every move, the pill polls
/// it), so it puts that point into the environment, the root of the piece declares the coordinate
/// space, and each button checks the point against its own frame.
///
/// A tooltip is drawn by the button itself for the same kind of reason: the overlay sits at the
/// screen saver's window level, and a system tooltip opens underneath it.
struct ChromeButtonStyle: ButtonStyle {
    /// The coordinate space the root of a piece of chrome declares and its hover point is in.
    nonisolated static let space = "chrome"

    enum Kind {
        /// An ordinary control.
        case plain
        /// The one that is on among its neighbours: a mode, a chosen row.
        case selected
        /// The action the whole bar exists for: Record.
        case record
    }

    var kind: Kind = .plain
    var tip: LocalizedStringKey?
    /// The room around the label that lights up with it. The pill, which is tight, asks for less.
    var insets = EdgeInsets(top: 6, leading: 9, bottom: 6, trailing: 9)

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, kind: kind, tip: tip, insets: insets)
    }

    private struct Face: View {
        let configuration: Configuration
        let kind: Kind
        let tip: LocalizedStringKey?
        let insets: EdgeInsets
        @State private var frame = CGRect.zero
        @Environment(\.chromeHoverPoint) private var hoverPoint
        @Environment(\.isEnabled) private var isEnabled

        private var hovered: Bool {
            hoverPoint.map(frame.contains) ?? false
        }

        private var fill: Color {
            let lit = hovered && isEnabled
            return switch kind {
            case .record: Color.red.opacity(configuration.isPressed ? 0.72 : lit ? 1 : 0.86)
            case .selected: Color.white.opacity(configuration.isPressed ? 0.36 : lit ? 0.32 : 0.24)
            case .plain: Color.white.opacity(configuration.isPressed ? 0.26 : lit ? 0.16 : 0)
            }
        }

        var body: some View {
            configuration.label
                .padding(insets)
                .background(fill, in: .rect(cornerRadius: Tokens.Radius.row))
                .contentShape(.rect(cornerRadius: Tokens.Radius.row))
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .animation(.easeOut(duration: Tokens.Motion.exit), value: hovered)
                .animation(.easeOut(duration: Tokens.Motion.exit), value: configuration.isPressed)
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(ChromeButtonStyle.space))
                } action: { frame = $0 }
                .overlay(alignment: .top) {
                    if hovered, let tip {
                        Text(tip)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.82), in: .rect(cornerRadius: Tokens.Radius.keyCap))
                            .fixedSize()
                            .offset(y: -30)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}
