import AppKit
import SwiftUI

/// The colour of one's own, behind the fifth swatch: saturation and brightness in a square, hue in
/// a strip, the hex, the last eight colours and an eyedropper that takes a colour straight off the
/// screen — the shot included. The owner's pick among three pickers: the system Colors panel is a
/// separate window that stays open, and a grid of presets can't give "the exact blue of that
/// button".
///
/// A colour is applied when the finger lifts, the hex is submitted or a recent one is clicked —
/// not on every step of a drag, which would put dozens of steps into ⌘Z.
struct ColorPickerPopover: View {
    let initial: NSColor
    let recents: [NSColor]
    let onPick: (NSColor) -> Void

    @State private var hue: CGFloat = 0
    @State private var saturation: CGFloat = 1
    @State private var brightness: CGFloat = 1
    @State private var hex = ""
    @State private var sampler = NSColorSampler()

    private static let squareSize = CGSize(width: 200, height: 130)

    private var color: NSColor {
        NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            saturationBrightnessSquare
            hueStrip
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: color))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.2), lineWidth: 0.5))
                    .frame(width: 24, height: 24)
                TextField("HEX", text: $hex)
                    .font(.body.monospaced())
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .onSubmit {
                        guard let parsed = ColorHex.color(hex) else { return }
                        load(parsed)
                        onPick(color)
                    }
                Spacer(minLength: 0)
                Button("Eyedropper", systemImage: "eyedropper") {
                    sampler.show { picked in
                        guard let picked else { return }
                        MainActor.assumeIsolated {
                            load(picked)
                            onPick(color)
                        }
                    }
                }
                .labelStyle(.iconOnly)
                .help("Pick a colour from the screen")
            }
            if !recents.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(recents.enumerated()), id: \.offset) { _, recent in
                        Button {
                            load(recent)
                            onPick(recent)
                        } label: {
                            Circle()
                                .fill(Color(nsColor: recent))
                                .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 0.5))
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                        .help(ColorHex.string(recent))
                    }
                }
            }
        }
        .padding(12)
        .frame(width: Self.squareSize.width + 24)
        .onAppear { load(initial) }
    }

    private var saturationBrightnessSquare: some View {
        let size = Self.squareSize
        return ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [.white, Color(nsColor: NSColor(hue: hue, saturation: 1, brightness: 1, alpha: 1))],
                startPoint: .leading,
                endPoint: .trailing
            )
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
            Circle()
                .strokeBorder(.white, lineWidth: 2)
                .shadow(color: .black.opacity(0.4), radius: 1)
                .frame(width: 14, height: 14)
                .offset(x: saturation * size.width - 7, y: (1 - brightness) * size.height - 7)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(.rect(cornerRadius: 8))
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    saturation = min(max(drag.location.x / size.width, 0), 1)
                    brightness = 1 - min(max(drag.location.y / size.height, 0), 1)
                    hex = ColorHex.string(color)
                }
                .onEnded { _ in onPick(color) }
        )
        .accessibilityLabel("Saturation and brightness")
    }

    private var hueStrip: some View {
        let width = Self.squareSize.width
        let stops = stride(from: 0.0, through: 1.0, by: 1.0 / 6).map {
            Color(nsColor: NSColor(hue: $0, saturation: 1, brightness: 1, alpha: 1))
        }
        return ZStack(alignment: .leading) {
            Capsule().fill(LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing))
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.4), radius: 1)
                .frame(width: 14, height: 14)
                .offset(x: hue * width - 7)
        }
        .frame(width: width, height: 12)
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    hue = min(max(drag.location.x / width, 0), 1)
                    hex = ColorHex.string(color)
                }
                .onEnded { _ in onPick(color) }
        )
        .accessibilityLabel("Hue")
    }

    private func load(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // A grey has no hue of its own: keep the strip where it was instead of jumping to red.
        if s > 0 {
            hue = h
        }
        saturation = s
        brightness = b
        hex = ColorHex.string(rgb)
    }
}

/// `#AF52DE` and back. How a custom colour is stored and typed.
enum ColorHex {
    static func string(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#000000" }

        func byte(_ component: CGFloat) -> Int {
            Int((min(max(component, 0), 1) * 255).rounded())
        }
        return String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }

    /// Takes `#AF52DE`, `af52de` or ` #af52de `; anything else is `nil`.
    static func color(_ string: String) -> NSColor? {
        var digits = string.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") {
            digits.removeFirst()
        }
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else {
            return nil
        }

        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
