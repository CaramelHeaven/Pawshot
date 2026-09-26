import AppKit
import SwiftUI

/// The editor's content: the shot as a sheet of paper — rounded, with a shadow — and the toolbar.
///
/// The shot itself stays the AppKit canvas inside its scroll view: SwiftUI `Canvas` has no
/// per-object hit-testing, no text input and no cursor rects. `EditorWindowController` builds the
/// scroll view and hands it over, because the window's resize logic measures it.
struct EditorView: View {
    /// The margin around the shot. Part of the window's chrome, measured like the toolbar.
    static let shotPadding: CGFloat = 14
    static let shotCornerRadius: CGFloat = 10

    let model: EditorChromeModel
    let scrollView: NSScrollView

    var body: some View {
        CanvasScrollView(scrollView: scrollView)
            .clipShape(.rect(cornerRadius: Self.shotCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Self.shotCornerRadius)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
            .overlay(alignment: chipAlignment) {
                if let chip = model.resizeChip {
                    ResizeChipView(chip: chip)
                        .padding(8)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: Tokens.Motion.exit), value: model.resizeChip == nil)
            .padding(Self.shotPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background.secondary)
            .toolbar { EditorToolbar(model: model) }
            .sensoryFeedback(.levelChange, trigger: model.style.lineWidth)
            .sensoryFeedback(.alignment, trigger: model.displayEdgeHits)
    }

    /// The chip sits by the edge that is being dragged, so the eye doesn't have to leave it.
    private var chipAlignment: Alignment {
        guard let edges = model.resizeChip?.edges else { return .bottom }

        let horizontal: HorizontalAlignment = edges.left ? .leading : edges.right ? .trailing : .center
        let vertical: VerticalAlignment = edges.top ? .top : edges.bottom ? .bottom : .center
        return Alignment(horizontal: horizontal, vertical: vertical)
    }
}

private struct ResizeChipView: View {
    let chip: ResizeChip

    var body: some View {
        Text(chip.text)
            .font(.callout.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(chip.isAtDisplayEdge ? .regular.tint(.red) : .regular, in: .capsule)
            .animation(.easeOut(duration: 0.15), value: chip.isAtDisplayEdge)
    }
}

/// The scroll view with the canvas, as `EditorWindowController` built it.
private struct CanvasScrollView: NSViewRepresentable {
    let scrollView: NSScrollView

    func makeNSView(context _: Context) -> NSScrollView {
        scrollView
    }

    func updateNSView(_: NSScrollView, context _: Context) {}
}

// MARK: - Toolbar

/// Tools, then the style — colours always on show, widths as strokes, fill — then history and the
/// ways out. One primary action, tinted with the paw colour: Copy. Everything else is neutral
/// glass, so the eye finds ⌘C first.
private struct EditorToolbar: ToolbarContent {
    let model: EditorChromeModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            ForEach(AnnotationTool.allCases, id: \.self) { tool in
                ToolButton(tool: tool, model: model)
            }
        }

        ToolbarItemGroup {
            ForEach(AnnotationStyle.Palette.colors.indices, id: \.self) { index in
                SwatchButton(index: index, model: model)
            }
        }

        ToolbarSpacer(.fixed)

        ToolbarItemGroup {
            ForEach(AnnotationStyle.LineWidth.steps, id: \.self) { width in
                WidthButton(width: width, model: model)
            }
            if model.tool == .text {
                Button {
                    model.cycleTextStyle()
                } label: {
                    TextStylePreview(style: model.style)
                }
                .help("Text style: plain, outline, plate (F)")
                .accessibilityLabel("Text style")
            } else {
                Button {
                    model.toggleFill()
                } label: {
                    Image(systemName: model.style.isFilled ? "square.fill" : "square")
                        .contentTransition(.symbolEffect(.replace))
                }
                .help("Fill (F)")
                .accessibilityLabel(model.style.isFilled ? "Fill on" : "Fill off")
            }
        }

        ToolbarSpacer(.flexible)

        ToolbarItemGroup {
            Button("Undo", systemImage: "arrow.uturn.backward") { model.undo() }
                .help("Undo (⌘Z)")
            Button("Redo", systemImage: "arrow.uturn.forward") { model.redo() }
                .help("Redo (⇧⌘Z)")
            Button("Clear All", systemImage: "trash") { model.clearAll() }
                .help("Clear all (C)")
        }

        ToolbarItemGroup {
            Button("Save to Desktop", systemImage: "square.and.arrow.down") { model.save() }
                .help("Save to Desktop (⌘S)")
            Button("Copy Text", systemImage: "text.viewfinder") { model.copyText() }
                .help("Copy the text in the shot (⌘D)")
        }

        ToolbarItem {
            Button {
                model.copy()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.glassProminent)
            .tint(Tokens.paw)
            .help("Copy to clipboard (⌘C)")
        }
    }
}

/// A small "A" in the current label style, so the button says what F will give next time round.
private struct TextStylePreview: View {
    let style: AnnotationStyle

    var body: some View {
        let color = Color(nsColor: style.color)
        let letter = Text("A").font(.system(size: 13, weight: .heavy, design: .rounded))

        switch style.textStyle {
        case .plain:
            letter.foregroundStyle(color)
        case .outline:
            let outline = Color(nsColor: AnnotationStyle.contrastingTextColor(on: style.color))
            letter.foregroundStyle(color)
                .shadow(color: outline, radius: 0, x: 1, y: 0)
                .shadow(color: outline, radius: 0, x: -1, y: 0)
                .shadow(color: outline, radius: 0, x: 0, y: 1)
                .shadow(color: outline, radius: 0, x: 0, y: -1)
        case .plate:
            letter.foregroundStyle(Color(nsColor: AnnotationStyle.contrastingTextColor(on: style.color)))
                .padding(.horizontal, 4)
                .background(Capsule().fill(color))
        }
    }
}

/// A tool with its hotkey letter tucked into the corner: the letters are how people end up using
/// the editor, and a tooltip alone hides them.
private struct ToolButton: View {
    let tool: AnnotationTool
    let model: EditorChromeModel

    private var isSelected: Bool {
        model.tool == tool
    }

    var body: some View {
        Button {
            model.selectTool(tool)
        } label: {
            Image(systemName: tool.symbolName)
                .symbolVariant(isSelected ? .fill : .none)
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(isSelected ? Tokens.paw : .primary)
                .overlay(alignment: .bottomTrailing) {
                    Text(tool.hotKey.uppercased())
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .offset(x: 6, y: 5)
                }
                .padding(.trailing, 3)
        }
        .help("\(tool.title) (\(tool.hotKey.uppercased()))")
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One palette colour, always visible — picking a colour is one click, not "open, then pick".
/// The sixth slot is black or white, whichever is on; pressing it again flips it.
private struct SwatchButton: View {
    let index: Int
    let model: EditorChromeModel

    private var isSelected: Bool {
        model.colorIndex == index
    }

    private var color: NSColor {
        let isLast = index == AnnotationStyle.Palette.colors.count - 1
        if isLast, isSelected {
            return model.style.color
        }
        return AnnotationStyle.Palette.colors[index]
    }

    var body: some View {
        Button {
            model.pickColor(index)
        } label: {
            Circle()
                .fill(Color(nsColor: color))
                .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 0.5))
                .frame(width: isSelected ? 16 : 13, height: isSelected ? 16 : 13)
                .background {
                    if isSelected {
                        Circle()
                            .stroke(.primary, lineWidth: 1.5)
                            .frame(width: 21, height: 21)
                    }
                }
                .frame(width: 22, height: 22)
                .contentShape(.rect)
                .animation(.easeOut(duration: Tokens.Motion.enter), value: isSelected)
        }
        .buttonStyle(.plain)
        .help("Colour \(index + 1)")
        .accessibilityLabel("Colour \(index + 1)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A line width shown as a stroke of that width in the current colour, instead of a number.
private struct WidthButton: View {
    let width: CGFloat
    let model: EditorChromeModel

    private var isSelected: Bool {
        model.style.lineWidth == width
    }

    var body: some View {
        Button {
            model.pickLineWidth(width)
        } label: {
            Capsule()
                .fill(Color(nsColor: model.style.color))
                .frame(width: 14, height: max(1.5, width * 0.7))
                .frame(width: 20, height: 22)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.primary.opacity(0.14))
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Line width \(Int(width)) ([ and ])")
        .accessibilityLabel("Line width \(Int(width))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
