import AppKit

/// Flattens the shot and the annotations into one picture — the thing that goes to the clipboard
/// and to a file.
@MainActor
enum AnnotationRenderer {
    /// Rendering happens at the original's full resolution: on Retina that is twice as many
    /// points, and those pixels must not be lost on export.
    static func render(_ document: EditorDocument) -> CGImage? {
        let pixelWidth = document.image.width
        let pixelHeight = document.image.height

        guard pixelWidth > 0, pixelHeight > 0, document.imageSize.width > 0 else { return nil }

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Annotations live in the captured frame's coordinates with the origin at the top left —
        // the same as in the canvas. Hence the Y axis flip and the `flipped: true` flag on
        // NSGraphicsContext: without the flag AppKit draws the text upside down.
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: 1, y: -1)

        let scale = CGFloat(pixelWidth) / document.imageSize.width
        context.scaleBy(x: scale, y: scale)

        // The same shift the canvas applies: the bitmap starts at the crop, annotations count from
        // the frame. Whatever falls outside the crop is clipped away by the context — that is how
        // an annotation left behind by a shrunken shot survives without showing up in the export.
        context.translateBy(x: -document.cropRect.minX, y: -document.cropRect.minY)

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.current = previous }

        let snapshot = NSImage(cgImage: document.image, size: document.imageSize)
        snapshot.draw(in: document.cropRect)

        // The selection frame is not drawn: it is part of the UI, not of the picture.
        for annotation in document.annotations {
            annotation.draw()
        }

        return context.makeImage()
    }
}
