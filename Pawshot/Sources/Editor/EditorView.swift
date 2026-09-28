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
        // Read live: switching the placement in Settings moves the tools in open windows too.
        Group {
            switch Settings.shared.toolsPlacement {
            case .below:
                VStack(spacing: 0) {
                    shot
                    ToolCapsule(model: model)
                        .padding(.horizontal, Self.shotPadding)
                        .padding(.bottom, 12)
                }
            case .overlay:
                shot.overlay(alignment: .bottom) {
                    ScalableTools(model: model)
                        .padding(.horizontal, Self.shotPadding + 8)
                        .padding(.bottom, Self.shotPadding + 10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.secondary)
        .toolbar { EditorToolbar(model: model) }
        .sensoryFeedback(.levelChange, trigger: model.style.lineWidth)
        .sensoryFeedback(.alignment, trigger: model.displayEdgeHits)
    }

    private var shot: some View {
        CanvasScrollView(scrollView: scrollView)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { model.reportShotFrame($0) }
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

/// The turns, history and the ways out. Everything that draws — the tools, the colours and the
/// style — lives at the bottom (`ToolCapsule`), the owner's pick. One primary action, tinted with
/// the paw colour: Copy. Everything else is neutral glass, so the eye finds ⌘C first.
private struct EditorToolbar: ToolbarContent {
    let model: EditorChromeModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Rotate Left", systemImage: "rotate.left") { model.rotate(false) }
                .help("Rotate left — the selected object, or the whole shot (⌘L)")
            Button("Rotate Right", systemImage: "rotate.right") { model.rotate(true) }
                .help("Rotate right — the selected object, or the whole shot (⌘R)")
        }

        ToolbarSpacer(.flexible)

        ToolbarItemGroup {
            Button("Undo", systemImage: "arrow.uturn.backward") { model.undo() }
                .help("Undo (⌘Z)")
            Button("Redo", systemImage: "arrow.uturn.forward") { model.redo() }
                .help("Redo (⇧⌘Z)")
            Button("Clear All", systemImage: "eraser") { model.clearAll() }
                .help("Erase all markup (C)")
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

/// The tools over the shot, with a visible grip at each end: drag one out to make them bigger, in to
/// make them smaller, within `SelectionGeometry.toolsScale`; a double click puts them back at 100%.
/// The size is remembered in Settings, and a narrower window shrinks them without forgetting it.
private struct ScalableTools: View {
    let model: EditorChromeModel

    @State private var panelWidth: CGFloat = 0
    @State private var availableWidth: CGFloat = 0
    @State private var dragStartScale: CGFloat?

    private var scale: CGFloat {
        SelectionGeometry.toolsScale(
            Settings.shared.overlayToolsScale,
            panelWidth: panelWidth,
            availableWidth: availableWidth
        )
    }

    var body: some View {
        ToolCapsule(model: model)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { panelWidth = $0 }
            .padding(.horizontal, ToolsGrip.width)
            .overlay(alignment: .leading) { grip(outward: -1) }
            .overlay(alignment: .trailing) { grip(outward: 1) }
            // Measured inside the scale, so the frame is the one on screen. The canvas under it
            // leaves the cursor alone there.
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { model.reportToolsFrame($0) }
            .onDisappear { model.reportToolsFrame(nil) }
            .scaleEffect(scale, anchor: .bottom)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { availableWidth = $0 }
    }

    /// The panel is centred, so an end dragged out by `dx` makes it `2 dx` wider.
    private func grip(outward: CGFloat) -> some View {
        ToolsGrip(isLeading: outward < 0)
            .onTapGesture(count: 2) {
                Settings.shared.overlayToolsScale = 1
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = dragStartScale ?? scale
                        dragStartScale = start
                        guard panelWidth > 0 else { return }
                        let requested = start + 2 * outward * drag.translation.width / panelWidth
                        Settings.shared.overlayToolsScale = SelectionGeometry.toolsScale(
                            requested,
                            panelWidth: panelWidth,
                            availableWidth: availableWidth
                        )
                    }
                    .onEnded { _ in dragStartScale = nil }
            )
    }
}

/// A grip at one end of the floating tools: a thin pill that lights up in the paw colour under the
/// pointer, on a strip wide enough to catch without aiming.
private struct ToolsGrip: View {
    static let width: CGFloat = 16

    let isLeading: Bool
    @State private var isHovered = false

    var body: some View {
        Capsule()
            .fill(isHovered ? Tokens.paw : Color.secondary.opacity(0.35))
            .frame(width: 4, height: 20)
            .frame(width: Self.width)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .onHover { isHovered = $0 }
            .pointerStyle(.frameResize(position: isLeading ? .leading : .trailing))
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .help("Drag to resize the tools; double-click for 100%")
            .accessibilityLabel("Resize the tools")
    }
}

/// Two glass capsules under the shot, or over its bottom edge — where Settings puts them: the
/// tools, and the style — the colours and whatever the current tool or selected object has. Side
/// by side when they fit, the style above the tools when they don't; on a very narrow shot the
/// colours fold into one swatch and the capsules scroll.
private struct ToolCapsule: View {
    let model: EditorChromeModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                tools
                StyleCapsule(model: model, foldsColours: false)
            }
            VStack(spacing: 6) {
                StyleCapsule(model: model, foldsColours: false)
                tools
            }
            VStack(spacing: 6) {
                StyleCapsule(model: model, foldsColours: true)
                tools
            }
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(spacing: 6) {
                    StyleCapsule(model: model, foldsColours: true)
                    tools
                }
            }
        }
    }

    private var tools: some View {
        HStack(spacing: 2) {
            ForEach(AnnotationTool.allCases, id: \.self) { tool in
                ToolButton(tool: tool, model: model)
                    .buttonStyle(.plain)
                    .frame(width: 28, height: 28)
            }
        }
        .glassCapsule()
    }
}

/// The colours, then only what the current kind of object has: widths and the fill with its
/// opacity for a rectangle, widths and the ends for a line, the look, the weights and the plate's
/// opacity for a label, widths for the rest. The opacity slider is always out — no chevron.
private struct StyleCapsule: View {
    let model: EditorChromeModel
    let foldsColours: Bool

    var body: some View {
        HStack(spacing: 2) {
            if foldsColours {
                FoldedColours(model: model)
            } else {
                ForEach(AnnotationStyle.Palette.colors.indices, id: \.self) { index in
                    SwatchButton(index: index, model: model)
                }
                CustomSwatchButton(model: model)
            }
            CapsuleDivider()
            if model.showsTextControls {
                Button {
                    model.cycleTextStyle()
                } label: {
                    TextStylePreview(style: model.style)
                }
                .buttonStyle(.plain)
                .frame(width: 26, height: 26)
                .help("Text style: plain, outline, plate (F)")
                .accessibilityLabel("Text style")
                CapsuleDivider()
                ForEach(model.textWeights, id: \.rawValue) { weight in
                    WeightButton(weight: weight, model: model)
                }
                CapsuleDivider()
                OpacitySlider(model: model, minimum: 0.1)
            } else {
                ForEach(AnnotationStyle.LineWidth.steps, id: \.self) { width in
                    WidthButton(width: width, model: model)
                }
                if model.showsLineEnds {
                    CapsuleDivider()
                    LineEndsPicker(model: model)
                } else if model.showsFill {
                    CapsuleDivider()
                    ShapeKindPicker(model: model)
                    CapsuleDivider()
                    Button {
                        model.cycleFill()
                    } label: {
                        FillPreview(style: model.style)
                    }
                    .buttonStyle(.plain)
                    .help("Fill: none, 30%, 60%, solid (F)")
                    .accessibilityLabel("Fill")
                    .accessibilityValue(model.style.isFilled ? "\(Int(model.style.fillOpacity * 100))%" : "off")
                    OpacitySlider(model: model, minimum: 0)
                }
            }
        }
        .glassCapsule()
    }
}

private struct CapsuleDivider: View {
    var body: some View {
        Divider()
            .frame(height: 18)
            .padding(.horizontal, 5)
    }
}

private extension View {
    func glassCapsule() -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: .capsule)
            .fixedSize()
    }
}

/// "Аа" in one weight of the labels' family: as many buttons as the family has weights.
private struct WeightButton: View {
    let weight: NSFont.Weight
    let model: EditorChromeModel

    private var isSelected: Bool {
        LabelFont.nearest(model.style.textWeight, in: model.textWeights) == weight
    }

    var body: some View {
        Button {
            model.pickTextWeight(weight)
        } label: {
            Text(verbatim: "Аа")
                .font(Font(LabelFont.font(size: 13, weight: weight)))
                .frame(width: 26, height: 22)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.14))
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(LabelFont.name(of: weight))
        .accessibilityLabel(LabelFont.name(of: weight))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The fill's or the plate's opacity, always on show. Applied when the knob is let go — one step
/// of ⌘Z for the whole drag.
private struct OpacitySlider: View {
    let model: EditorChromeModel
    let minimum: CGFloat

    @State private var value: CGFloat = 0
    @State private var isDragging = false

    /// The fill follows the slider while it moves (`previewFillOpacity`, no undo per tick); letting
    /// go is the one step of ⌘Z. Until 0.4.9 the fill changed only on letting go.
    var body: some View {
        HStack(spacing: 6) {
            Slider(value: $value, in: minimum ... 1, step: 0.05) { editing in
                isDragging = editing
                if !editing {
                    model.setFillOpacity(value)
                }
            }
            .onChange(of: value) { _, opacity in
                if isDragging {
                    model.previewFillOpacity(opacity)
                }
            }
            .controlSize(.small)
            .frame(width: 90)
            Text("\(Int((value * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .help("Opacity")
        .onAppear { value = max(model.style.fillOpacity, minimum) }
        .onChange(of: model.style.fillOpacity) { _, opacity in
            value = max(opacity, minimum)
        }
    }
}

/// The colours behind one swatch of the current colour, for a capsule that has no room for five.
private struct FoldedColours: View {
    let model: EditorChromeModel
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Circle()
                .fill(Color(nsColor: model.style.color))
                .overlay(Circle().strokeBorder(.primary.opacity(0.35), lineWidth: 0.75))
                .frame(width: 16, height: 16)
                .frame(width: 24, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Colours")
        .accessibilityLabel("Colours")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            HStack(spacing: 2) {
                ForEach(AnnotationStyle.Palette.colors.indices, id: \.self) { index in
                    SwatchButton(index: index, model: model)
                }
                CustomSwatchButton(model: model)
            }
            .padding(10)
        }
    }
}

/// A square filled as the shape will be: empty, see-through or solid.
private struct FillPreview: View {
    let style: AnnotationStyle

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color(nsColor: style.color).opacity(style.fillOpacity))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.primary, lineWidth: 1.5))
            .frame(width: 15, height: 15)
            .frame(width: 22, height: 22)
    }
}

/// Plain, arrow, double arrow — the one line tool's three looks, and the ends of a selected line.
private struct LineEndsPicker: View {
    let model: EditorChromeModel

    var body: some View {
        ForEach(AnnotationStyle.LineEnds.allCases, id: \.self) { ends in
            let isSelected = model.style.lineEnds == ends
            Button {
                model.pickLineEnds(ends)
            } label: {
                Image(systemName: Self.symbol(for: ends))
                    .foregroundStyle(isSelected ? Tokens.paw : .primary)
                    .frame(width: 22, height: 22)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.14))
                        }
                    }
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(Self.title(for: ends))
            .accessibilityLabel(Self.title(for: ends))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    private static func symbol(for ends: AnnotationStyle.LineEnds) -> String {
        switch ends {
        case .none: "minus"
        case .end: "arrow.right"
        case .both: "arrow.left.and.right"
        }
    }

    private static func title(for ends: AnnotationStyle.LineEnds) -> String {
        switch ends {
        case .none: String(localized: "Line (A)")
        case .end: String(localized: "Arrow (A)")
        case .both: String(localized: "Double arrow (A)")
        }
    }
}

/// Rectangle, circle, triangle, diamond — R's four shapes, and the shape of a selected one. The
/// owner's Ф-A of 2026-09-28: the same place and look as the line's three.
private struct ShapeKindPicker: View {
    let model: EditorChromeModel

    var body: some View {
        ForEach(AnnotationStyle.ShapeKind.allCases, id: \.self) { kind in
            let isSelected = model.style.shapeKind == kind
            Button {
                model.pickShapeKind(kind)
            } label: {
                Image(systemName: kind.symbolName)
                    .foregroundStyle(isSelected ? Tokens.paw : .primary)
                    .frame(width: 22, height: 22)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.14))
                        }
                    }
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(kind.title)
            .accessibilityLabel(kind.title)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}

extension AnnotationStyle.ShapeKind {
    var symbolName: String {
        switch self {
        case .rectangle: "rectangle"
        case .circle: "circle"
        case .triangle: "triangle"
        case .diamond: "diamond"
        }
    }

    var title: String {
        switch self {
        case .rectangle: String(localized: "Rectangle (R)")
        case .circle: String(localized: "Circle (R)")
        case .triangle: String(localized: "Triangle (R)")
        case .diamond: String(localized: "Diamond (R)")
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
            // R shows the shape it draws now.
            Image(systemName: tool == .rectangle ? model.drawingShapeKind.symbolName : tool.symbolName)
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
private struct SwatchButton: View {
    let index: Int
    let model: EditorChromeModel

    private var isSelected: Bool {
        model.colorIndex == index
    }

    var body: some View {
        Button {
            model.pickColor(index)
        } label: {
            Circle()
                .fill(Color(nsColor: AnnotationStyle.Palette.colors[index]))
                // Strong enough to show the white swatch on a light toolbar.
                .overlay(Circle().strokeBorder(.primary.opacity(0.35), lineWidth: 0.75))
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

/// The fifth slot: the colour of one's own inside a rainbow ring. A click picks it; a click when it
/// is already on opens the picker.
private struct CustomSwatchButton: View {
    let model: EditorChromeModel
    @State private var isPresented = false

    private var isSelected: Bool {
        model.colorIndex == AnnotationStyle.Palette.customIndex
    }

    var body: some View {
        Button {
            if isSelected {
                isPresented = true
            } else {
                model.pickColor(AnnotationStyle.Palette.customIndex)
            }
        } label: {
            Circle()
                .fill(Color(nsColor: isSelected ? model.style.color : model.customColor))
                .padding(3)
                .background {
                    Circle().fill(AngularGradient(
                        colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                        center: .center
                    ))
                }
                .frame(width: isSelected ? 18 : 15, height: isSelected ? 18 : 15)
                .background {
                    if isSelected {
                        Circle()
                            .stroke(.primary, lineWidth: 1.5)
                            .frame(width: 23, height: 23)
                    }
                }
                .frame(width: 24, height: 22)
                .contentShape(.rect)
                .animation(.easeOut(duration: Tokens.Motion.enter), value: isSelected)
        }
        .buttonStyle(.plain)
        .help("Your colour (5) — click again to pick")
        .accessibilityLabel("Your colour")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ColorPickerPopover(
                initial: model.style.color,
                recents: model.recentColors,
                onPick: { model.pickCustomColor($0) }
            )
        }
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
