import AppKit
import Foundation

// Draws the app icon as Icon Composer layers and writes two `.icon` bundles: `AppIcon.icon` for
// Release and a grey `AppIcon-Debug.icon`, so a DerivedData build can't be mistaken for the copy
// in /Applications. Run through `make icon`.
//
// macOS 26 draws the tile itself: the system squircle, the Liquid Glass highlights, the dark, clear
// and tinted variants. An icon that brings its own tile and insets gets shrunk into a grey plate,
// so the layers here are full-bleed: white shapes on a transparent 1024 canvas, and the colour of
// the tile is the `fill` in `icon.json`.

let resourcesDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
let canvasSide: CGFloat = 1024

// MARK: - Drawing

/// The frame corners — the same shape as in the menu bar icon.
func drawFrameCorners(in context: CGContext, tile: CGRect) {
    let frame = tile.insetBy(dx: tile.width * 0.2, dy: tile.width * 0.2)
    let arm = frame.width * 0.26
    let lineWidth = tile.width * 0.052
    let radius = lineWidth * 1.5

    context.saveGState()
    context.setStrokeColor(NSColor.white.cgColor)
    context.setLineWidth(lineWidth)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    // For each corner: the start of one arm, the corner vertex itself, the end of the other arm.
    // The rounding is done by `addArc(tangent1End:tangent2End:)` around the vertex.
    let corners: [(start: CGPoint, vertex: CGPoint, end: CGPoint)] = [
        (
            CGPoint(x: frame.minX, y: frame.maxY - arm),
            CGPoint(x: frame.minX, y: frame.maxY),
            CGPoint(x: frame.minX + arm, y: frame.maxY)
        ),
        (
            CGPoint(x: frame.maxX - arm, y: frame.maxY),
            CGPoint(x: frame.maxX, y: frame.maxY),
            CGPoint(x: frame.maxX, y: frame.maxY - arm)
        ),
        (
            CGPoint(x: frame.maxX, y: frame.minY + arm),
            CGPoint(x: frame.maxX, y: frame.minY),
            CGPoint(x: frame.maxX - arm, y: frame.minY)
        ),
        (
            CGPoint(x: frame.minX + arm, y: frame.minY),
            CGPoint(x: frame.minX, y: frame.minY),
            CGPoint(x: frame.minX, y: frame.minY + arm)
        ),
    ]

    for corner in corners {
        let path = CGMutablePath()
        path.move(to: corner.start)
        path.addArc(tangent1End: corner.vertex, tangent2End: corner.end, radius: radius)
        path.addLine(to: corner.end)
        context.addPath(path)
        context.strokePath()
    }
    context.restoreGState()
}

/// The paw: a pad and four toes.
func drawPaw(in context: CGContext, tile: CGRect) {
    context.saveGState()
    context.setFillColor(NSColor.white.cgColor)

    // The paw stays in the middle of the frame and doesn't run into the corners: at small sizes
    // shapes that touch turn into a blob.
    let center = CGPoint(x: tile.midX, y: tile.midY - tile.width * 0.02)
    let unit = tile.width * 0.82

    let padWidth = unit * 0.235
    let padHeight = unit * 0.185
    let pad = CGRect(
        x: center.x - padWidth / 2,
        y: center.y - padHeight * 0.85,
        width: padWidth,
        height: padHeight
    )
    context.addPath(CGPath(ellipseIn: pad, transform: nil))
    context.fillPath()

    // The toes: the outer ones are smaller and lower — that way the paw reads even at 16 px.
    let toes: [(dx: CGFloat, dy: CGFloat, w: CGFloat, h: CGFloat)] = [
        (-0.105, 0.055, 0.058, 0.076),
        (-0.036, 0.108, 0.062, 0.082),
        (0.036, 0.108, 0.062, 0.082),
        (0.105, 0.055, 0.058, 0.076),
    ]

    for toe in toes {
        let rect = CGRect(
            x: center.x + unit * toe.dx - unit * toe.w / 2,
            y: center.y + unit * toe.dy - unit * toe.h / 2,
            width: unit * toe.w,
            height: unit * toe.h
        )
        context.addPath(CGPath(ellipseIn: rect, transform: nil))
        context.fillPath()
    }
    context.restoreGState()
}

/// The Debug build's mark: a dark band across the lower part with "DEBUG" on it.
func drawDebugBand(in context: CGContext, tile: CGRect) {
    let band = CGRect(x: tile.minX, y: tile.minY + tile.height * 0.08, width: tile.width, height: tile.height * 0.14)
    context.saveGState()
    context.setFillColor(NSColor(white: 0.1, alpha: 0.85).cgColor)
    context.fill(band)

    let text = "DEBUG" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: band.height * 0.6, weight: .heavy),
        .foregroundColor: NSColor.white,
        .kern: band.height * 0.08,
    ]
    let size = text.size(withAttributes: attributes)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    text.draw(at: CGPoint(x: band.midX - size.width / 2, y: band.midY - size.height / 2), withAttributes: attributes)
    NSGraphicsContext.restoreGraphicsState()
    context.restoreGState()
}

// MARK: - Writing files

func layerPNG(_ draw: (CGContext, CGRect) -> Void) -> Data {
    guard let context = CGContext(
        data: nil,
        width: Int(canvasSide),
        height: Int(canvasSide),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("couldn't create a canvas") }

    context.setAllowsAntialiasing(true)
    draw(context, CGRect(x: 0, y: 0, width: canvasSide, height: canvasSide))

    guard
        let image = context.makeImage(),
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { fatalError("couldn't encode a layer") }
    return data
}

/// One `.icon` bundle: `icon.json` plus the layer images in `Assets/`.
func writeIcon(named name: String, fill: String, layers: [(name: String, data: Data)]) throws {
    let bundle = resourcesDirectory.appendingPathComponent("\(name).icon")
    let assets = bundle.appendingPathComponent("Assets")
    try? FileManager.default.removeItem(at: bundle)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

    for layer in layers {
        try layer.data.write(to: assets.appendingPathComponent("\(layer.name).png"))
    }

    let json: [String: Any] = [
        "fill": ["automatic-gradient": fill],
        "groups": [[
            "layers": layers.map { ["image-name": "\($0.name).png", "name": $0.name] },
            "shadow": ["kind": "neutral", "opacity": 0.5],
            "translucency": ["enabled": true, "value": 0.4],
        ]],
        "supported-platforms": ["squares": ["macOS"]],
    ]
    let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: bundle.appendingPathComponent("icon.json"))
    print("icon built: \(bundle.path)")
}

let paw = layerPNG(drawPaw)
let corners = layerPNG(drawFrameCorners)

// The orange of the paw (#F07F2E); the system derives the gradient from it.
try writeIcon(
    named: "AppIcon",
    fill: "extended-srgb:0.94118,0.49804,0.18039,1.00000",
    layers: [("paw", paw), ("corners", corners)]
)
try writeIcon(
    named: "AppIcon-Debug",
    fill: "extended-srgb:0.54000,0.56000,0.60000,1.00000",
    layers: [("debug", layerPNG(drawDebugBand)), ("paw", paw), ("corners", corners)]
)
