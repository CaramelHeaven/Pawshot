import AppKit
import Foundation

// Draws the background of the DMG window: an arrow from where Pawshot sits to where Applications
// sits, and one line saying what to do. Writes `background.png` and `background@2x.png` into the
// folder given as the first argument; `Tools/make-dmg.sh` glues them into one Retina TIFF.
//
// The icon positions here must match the ones `make-dmg.sh` hands to Finder.

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
let windowSize = CGSize(width: 640, height: 400)
let iconCentreY: CGFloat = 190 // from the top, the way Finder counts
let appIconX: CGFloat = 160
let applicationsIconX: CGFloat = 480

/// `Tokens.pawNSColor`, the orange of the app icon.
let paw = NSColor(srgbRed: 0xF0 / 255, green: 0x7F / 255, blue: 0x2E / 255, alpha: 1)

func drawBackground(scale: CGFloat) -> Data {
    let pixels = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(windowSize.width * scale), pixelsHigh: Int(windowSize.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    pixels.size = windowSize // points, so the drawing below is in points at any scale

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: pixels)

    NSColor(white: 0.97, alpha: 1).setFill()
    CGRect(origin: .zero, size: windowSize).fill()

    // AppKit counts from the bottom; Finder's positions count from the top.
    let y = windowSize.height - iconCentreY
    let start = appIconX + 90
    let end = applicationsIconX - 90
    let head: CGFloat = 14

    let arrow = NSBezierPath()
    arrow.move(to: CGPoint(x: start, y: y))
    arrow.line(to: CGPoint(x: end, y: y))
    arrow.move(to: CGPoint(x: end - head, y: y + head))
    arrow.line(to: CGPoint(x: end, y: y))
    arrow.line(to: CGPoint(x: end - head, y: y - head))
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    paw.setStroke()
    arrow.stroke()

    let caption = NSAttributedString(string: "Drag Pawshot to Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        .foregroundColor: NSColor(white: 0.45, alpha: 1),
    ])
    let captionSize = caption.size()
    caption.draw(at: CGPoint(x: (windowSize.width - captionSize.width) / 2, y: 70))

    NSGraphicsContext.restoreGraphicsState()
    return pixels.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
try drawBackground(scale: 1).write(to: outputDirectory.appendingPathComponent("background.png"))
try drawBackground(scale: 2).write(to: outputDirectory.appendingPathComponent("background@2x.png"))
