import AppKit

/// A blurred region. It stores only a rectangle — the pixels themselves come from the shared
/// `BlurSource`, so copies of the shot don't pile up one per object.
@MainActor
final class BlurAnnotation: Annotation {
    let id = UUID()
    var style: AnnotationStyle
    var mode: BlurMode

    private var start: CGPoint
    private var end: CGPoint
    private unowned let source: BlurSource

    var rect: CGRect {
        SelectionGeometry.rect(from: start, to: end)
    }

    init(start: CGPoint, style: AnnotationStyle, mode: BlurMode, source: BlurSource) {
        self.start = start
        end = start
        self.style = style
        self.mode = mode
        self.source = source
    }

    var boundingBox: CGRect {
        rect
    }

    var isMeaningful: Bool {
        rect.width >= 4 && rect.height >= 4
    }

    func update(to point: CGPoint) {
        end = point
    }

    func move(by delta: CGVector) {
        start.x += delta.dx
        start.y += delta.dy
        end.x += delta.dx
        end.y += delta.dy
    }

    func draw() {
        guard let image = source.image(for: mode), !rect.isEmpty else { return }

        // Draw the whole blurred shot clipped to the rectangle: that way there is no need to
        // recompute the source rect and fight the flipped coordinate system. `source.frame` is
        // where the shot sits inside the captured frame — the coordinate system annotations use.
        //
        // The edge is soft, but only on the outside: the rectangle itself stays fully covered, and
        // a narrow band around it fades out. Feathering inwards would let whatever sits at the edge
        // of a blurred password show through.
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let feather = min(6, min(rect.width, rect.height) / 4)
        let outer = rect.insetBy(dx: -feather, dy: -feather)

        context.saveGState()
        context.clip(to: outer)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        image.draw(
            in: source.frame,
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        if feather > 0 {
            Self.fadeOutBand(outside: rect, width: feather, in: context)
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// Erases the band between `rect` and `rect` grown by `width`, fully at the outer edge and not
    /// at all at `rect` itself.
    private static func fadeOutBand(outside rect: CGRect, width: CGFloat, in context: CGContext) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceGray(),
            colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)] as CFArray,
            locations: [0, 1]
        ) else { return }

        context.setBlendMode(.destinationOut)
        let bands: [(CGPoint, CGPoint)] = [
            (CGPoint(x: rect.minX - width, y: rect.midY), CGPoint(x: rect.minX, y: rect.midY)),
            (CGPoint(x: rect.maxX + width, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY)),
            (CGPoint(x: rect.midX, y: rect.minY - width), CGPoint(x: rect.midX, y: rect.minY)),
            (CGPoint(x: rect.midX, y: rect.maxY + width), CGPoint(x: rect.midX, y: rect.maxY)),
        ]
        for (start, end) in bands {
            context.drawLinearGradient(gradient, start: start, end: end, options: [])
        }
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    }
}
