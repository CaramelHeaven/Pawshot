import AppKit
import CoreImage

enum BlurMode: CaseIterable {
    case blur
    case pixellate
}

/// Blurred versions of the shot. Computed by Core Image **once** and cached: running the filter
/// on every canvas redraw is not an option — on a multi-megapixel shot it is noticeable.
@MainActor
final class BlurSource {
    /// The region of the captured frame this source stands for, in points. Annotations live in
    /// frame coordinates, so the blurred copy has to be drawn at this exact rectangle.
    private(set) var frame: CGRect

    /// While the shot is being resized the cache is deliberately kept stale: a Gaussian on a
    /// multi-megapixel image per mouse step would make the drag crawl. The already blurred copy
    /// stretches a little for the duration of the gesture, and the recompute happens once, when
    /// the resize ends.
    var isFrozen = false {
        didSet {
            if !isFrozen, isFrozen != oldValue {
                cache.removeAll()
            }
        }
    }

    var imageSize: CGSize {
        frame.size
    }

    private var original: CGImage
    private let context = CIContext()
    private var cache: [BlurMode: NSImage] = [:]

    init(image: CGImage, frame: CGRect) {
        original = image
        self.frame = frame
    }

    /// Points at a new cutout after the crop changed. The blur strength is tied to the shot size,
    /// so the cached copies no longer match and are dropped — unless the resize is still running.
    func update(image: CGImage, frame: CGRect) {
        original = image
        self.frame = frame

        if !isFrozen {
            cache.removeAll()
        }
    }

    func image(for mode: BlurMode) -> NSImage? {
        if let cached = cache[mode] {
            return cached
        }
        guard let rendered = render(mode) else { return nil }
        cache[mode] = rendered
        return rendered
    }

    private func render(_ mode: BlurMode) -> NSImage? {
        let input = CIImage(cgImage: original)
        let output: CIImage?

        switch mode {
        case .blur:
            // Without clampedToExtent the blur eats the edges: the filter samples transparency
            // beyond the boundary.
            output = input
                .clampedToExtent()
                .applyingGaussianBlur(sigma: Double(max(original.width, original.height)) / 100)
                .cropped(to: input.extent)
        case .pixellate:
            let scale = max(8, Double(max(original.width, original.height)) / 90)
            output = input.applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: scale,
                kCIInputCenterKey: CIVector(x: 0, y: 0),
            ])
            .cropped(to: input.extent)
        }

        guard let output, let cgImage = context.createCGImage(output, from: input.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: imageSize)
    }
}
