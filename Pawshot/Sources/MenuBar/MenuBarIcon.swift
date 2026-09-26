import AppKit

/// The paw in the menu bar, in the three states it can show.
///
/// The variants are drawn in code from the one asset rather than kept as extra PDFs: they are
/// the same paw, and a hand-drawn copy would drift from it the first time the asset changes.
/// All three are template images, so macOS tints them for a light or dark menu bar.
@MainActor
enum MenuBarIcon {
    static let normal: NSImage = {
        let icon = NSImage(resource: .menuBarIcon)
        icon.accessibilityDescription = "Pawshot"
        return icon
    }()

    /// While a capture is running: the paw knocked out of a filled tile, the way the menu bar
    /// highlights a pressed item.
    static let capturing: NSImage = template(accessibility: "Pawshot, capturing") { rect in
        NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5).fill()
        normal.draw(in: rect.insetBy(dx: 2.5, dy: 2.5), from: .zero, operation: .destinationOut, fraction: 1)
    }

    /// For a moment after ⌘D: a dot in the corner says the text reached the clipboard.
    static let textCopied: NSImage = template(accessibility: "Pawshot, text copied") { rect in
        normal.draw(in: rect)

        let dot = CGRect(x: rect.maxX - 6.5, y: rect.maxY - 6.5, width: 6, height: 6)
        // A clear ring first, so the dot doesn't merge with the frame corner under it.
        NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill(using: .destinationOut)
        NSBezierPath(ovalIn: dot).fill()
    }

    /// Drawn once, up front, into 1× and 2× bitmaps: the menu bar asks for the image on every
    /// redraw, and a lazy drawing handler would run the compositing each time.
    private static func template(accessibility: String, draw: (CGRect) -> Void) -> NSImage {
        let size = normal.size
        let image = NSImage(size: size)

        for scale in [1, 2] {
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width) * scale,
                pixelsHigh: Int(size.height) * scale,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { continue }
            rep.size = size

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.black.setFill()
            draw(CGRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()

            image.addRepresentation(rep)
        }

        image.isTemplate = true
        image.accessibilityDescription = accessibility
        return image
    }
}

private extension NSBezierPath {
    func fill(using operation: NSCompositingOperation) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = operation
        fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
