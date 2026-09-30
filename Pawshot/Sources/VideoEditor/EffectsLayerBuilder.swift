import AppKit
import AVFoundation
import CoreImage
import CoreText
import QuartzCore

/// Which effects go into the video.
struct EffectsOptions: Equatable {
    var clicks = true
    var keys = true
    var zooms = true
    var spotlights = true
    /// The stretches hidden with the blur key. Off, they go out plain: the recording itself was
    /// never blurred, which is what lets a stretch hidden by mistake be shown after all.
    var blurs = true

    /// Nothing to draw: the video can go out as it is.
    func isEmpty(for timeline: EventTimeline) -> Bool {
        (!clicks || timeline.clicks.isEmpty)
            && (!keys || timeline.keys.isEmpty)
            && (!zooms || !timeline.hasZooms)
            && (!spotlights || timeline.spotlights.isEmpty)
            && (!blurs || timeline.blurs.isEmpty)
    }
}

/// Builds the Core Animation tree of the effects. One tree, two uses: the export hands it to
/// `AVVideoCompositionCoreAnimationTool`, the editor's preview puts it in an `AVSynchronizedLayer`
/// over the player — so what is previewed is what comes out.
///
/// ```
/// root (the video's size, clipping)
///   ├ content (zoomed; blurred over the hidden stretches)
///   │   ├ video
///   │   ├ spotlights (a dark sheet with a hole that follows the cursor)
///   │   └ click rings
///   └ key captions (not zoomed: they are a caption, not part of the picture)
/// ```
///
/// A hidden stretch is a Gaussian blur on `content`, its radius animated from nothing and back.
/// Measured on a rendered file, not assumed: `AVVideoCompositionCoreAnimationTool` does draw a
/// layer's Core Image filters and does animate `filters.<name>.inputRadius` — while a second
/// video layer with a filter of its own, faded in and out, came out unblurred. The filter is put
/// on only when the take has something hidden: it is paid for on every frame.
///
/// Coordinates are Core Animation's, origin bottom left — which both the export and an
/// unflipped layer-backed view use.
enum EffectsLayerBuilder {
    /// - Parameters:
    ///   - videoLayer: an empty layer for the export, the `AVPlayerLayer` for the preview.
    ///   - keep: the pieces that go into the file. The timeline is in the recording's time; every
    ///     event is moved to where its piece lands in the file, and one that was cut is dropped. A
    ///     zoom or a caption crossing a seam is cut at the edge of its piece, so it never carries
    ///     on over the next piece's picture. The preview plays the recording itself and passes the
    ///     whole of it, which leaves every time as it is.
    static func build(
        timeline: EventTimeline,
        options: EffectsOptions,
        videoSize: CGSize,
        keep: KeepRanges,
        videoLayer: CALayer
    ) -> CALayer {
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: videoSize)
        root.masksToBounds = true

        let content = CALayer()
        content.frame = root.bounds
        root.addSublayer(content)

        videoLayer.frame = root.bounds
        content.addSublayer(videoLayer)

        if options.spotlights {
            for span in timeline.spotlights {
                for part in parts(from: span.start, to: span.end, in: keep) {
                    let path = EffectsPlanner.cursorPath(
                        from: part.low,
                        to: part.high,
                        timeline: timeline,
                        step: EffectsPlanner.spotlightStep,
                        fallback: CGPoint(x: 0.5, y: 0.5)
                    )
                    content.addSublayer(spotlight(along: path, startingAt: part.output, videoSize: videoSize))
                }
            }
        }

        if options.blurs, !timeline.blurs.isEmpty {
            // The edge of the picture carried on outwards first: a blur that finds nothing beyond
            // the frame darkens a rim all round it.
            let clamp = CIFilter(name: "CIAffineClamp")
            clamp?.setValue(NSAffineTransform(), forKey: kCIInputTransformKey)
            let blur = CIFilter(name: "CIGaussianBlur")
            blur?.name = "hide"
            blur?.setValue(0, forKey: kCIInputRadiusKey)
            content.filters = [clamp, blur].compactMap(\.self)

            let radius = EffectsPlanner.blurRadius(for: videoSize)
            let fade = EffectsPlanner.effectFade
            for span in timeline.blurs {
                // The way in and the way out lie outside the stretch: inside it nothing is ever
                // half sharp.
                for (index, part) in spans(from: span.start - fade, to: span.end + fade, in: keep).enumerated() {
                    content.add(
                        hide(from: part.start, to: part.end, radius: radius),
                        forKey: "blur-\(span.start)-\(index)"
                    )
                }
            }
        }

        if options.clicks {
            for click in timeline.clicks {
                guard let time = keep.outputTime(forSource: click.time) else { continue }
                content.addSublayer(ring(
                    at: SelectionGeometry.layerPoint(CGPoint(x: click.x, y: click.y), in: videoSize),
                    videoSize: videoSize,
                    time: time
                ))
            }
        }

        if options.zooms {
            for segment in EffectsPlanner.zoomSegments(timeline: timeline, duration: keep.duration) {
                for (index, part) in parts(from: segment.start, to: segment.end, in: keep).enumerated() {
                    let path = EffectsPlanner.zoomPath(of: segment, from: part.low, to: part.high, timeline: timeline)
                    content.add(
                        zoom(along: path, startingAt: part.output, videoSize: videoSize),
                        forKey: "zoom-\(segment.start)-\(index)"
                    )
                }
            }
        }

        if options.keys {
            for caption in EffectsPlanner.keyCaptions(timeline: timeline) {
                for span in spans(from: caption.start, to: caption.end, in: keep) {
                    root.addSublayer(captionLayer(caption.text, from: span.start, to: span.end, videoSize: videoSize))
                }
            }
        }

        return root
    }

    /// The parts of a stretch of the recording that survive the cuts, in the file's time: one per
    /// piece it overlaps. Slivers under a twentieth of a second are dropped — they would only
    /// flicker.
    static func spans(
        from start: TimeInterval,
        to end: TimeInterval,
        in keep: KeepRanges
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        parts(from: start, to: end, in: keep).map { ($0.output, $0.output + ($0.high - $0.low)) }
    }

    /// The same parts with both clocks: `low…high` in the recording's time — what an effect that
    /// follows the cursor needs, to know where the cursor was — and where the part starts in
    /// the file.
    private static func parts(
        from start: TimeInterval,
        to end: TimeInterval,
        in keep: KeepRanges
    ) -> [(low: TimeInterval, high: TimeInterval, output: TimeInterval)] {
        keep.pieces.compactMap { piece in
            let low = max(start, piece.start)
            let high = min(end, piece.end)
            guard high - low > 0.05, let output = keep.outputTime(forSource: low) else { return nil }
            return (low, high, output)
        }
    }

    // MARK: - Pieces

    /// `beginTime` 0 means "now" to Core Animation; the start of the video is this constant.
    private static func begin(_ time: Double) -> CFTimeInterval {
        time <= 0 ? AVCoreAnimationBeginTimeAtZero : time
    }

    /// An orange ring that grows and fades — the paw colour, like the brackets.
    private static func ring(at point: CGPoint, videoSize: CGSize, time: Double) -> CALayer {
        let radius = max(14, min(videoSize.width, videoSize.height) * 0.03)
        let layer = CAShapeLayer()
        layer.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        layer.position = point
        layer.path = CGPath(ellipseIn: layer.bounds.insetBy(dx: 2, dy: 2), transform: nil)
        layer.fillColor = nil
        layer.strokeColor = CGColor(srgbRed: 0.94, green: 0.50, blue: 0.18, alpha: 1)
        layer.lineWidth = max(3, radius * 0.18)
        layer.opacity = 0

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.4
        scale.toValue = 1.3
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, 0.3, 1]

        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.beginTime = begin(time)
        group.duration = 0.45
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: "click")
        return layer
    }

    /// The way in, the zoom held on each centre of `path` in turn, the way out. A marked zoom's
    /// path is one place; a held zoom's is where the cursor went, a step every tenth of a second,
    /// and the picture glides from one to the next.
    private static func zoom(
        along path: [(time: Double, center: CGPoint)],
        startingAt start: Double,
        videoSize: CGSize
    ) -> CAAnimation {
        let scale = EffectsPlanner.zoomScale
        func zoomed(on normalized: CGPoint) -> CATransform3D {
            let center = SelectionGeometry.layerPoint(normalized, in: videoSize)
            let offset = SelectionGeometry.zoomOffset(center: center, scale: scale, size: videoSize)
            return CATransform3DScale(CATransform3DMakeTranslation(offset.x, offset.y, 0), scale, scale, 1)
        }
        let first = path[0].time
        let length = max(0.01, path[path.count - 1].time - first)
        let ramp = min(EffectsPlanner.zoomRamp, length / 2)
        func center(at time: Double) -> CGPoint {
            path.last { $0.time <= time }?.center ?? path[0].center
        }

        var frames: [(time: Double, transform: CATransform3D)] = [
            (0, CATransform3DIdentity),
            (ramp, zoomed(on: center(at: first + ramp))),
        ]
        for step in path where step.time > first + ramp && step.time < first + length - ramp {
            frames.append((step.time - first, zoomed(on: step.center)))
        }
        frames.append((length - ramp, zoomed(on: center(at: first + length - ramp))))
        frames.append((length, CATransform3DIdentity))

        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = frames.map { NSValue(caTransform3D: $0.transform) }
        animation.keyTimes = frames.map { NSNumber(value: $0.time / length) }
        animation.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut)]
            + Array(repeating: CAMediaTimingFunction(name: .linear), count: frames.count - 3)
            + [CAMediaTimingFunction(name: .easeInEaseOut)]
        animation.beginTime = begin(start)
        animation.duration = length
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// A dark sheet over the picture with a round hole in it, the hole travelling with the cursor.
    /// The sheet is twice the video each way with the hole in its middle, so wherever the cursor
    /// is inside the video, the sheet still covers all of it.
    private static func spotlight(
        along path: [(time: Double, point: CGPoint)],
        startingAt start: Double,
        videoSize: CGSize
    ) -> CALayer {
        let radius = min(videoSize.width, videoSize.height) * EffectsPlanner.spotlightRadius
        let sheet = CAShapeLayer()
        sheet.bounds = CGRect(x: 0, y: 0, width: videoSize.width * 2, height: videoSize.height * 2)
        let shape = CGMutablePath()
        shape.addRect(sheet.bounds)
        shape.addEllipse(in: CGRect(
            x: videoSize.width - radius,
            y: videoSize.height - radius,
            width: radius * 2,
            height: radius * 2
        ))
        sheet.path = shape
        sheet.fillRule = .evenOdd
        sheet.fillColor = CGColor(gray: 0, alpha: EffectsPlanner.spotlightDim)
        sheet.position = SelectionGeometry.layerPoint(path[0].point, in: videoSize)
        sheet.opacity = 0

        let first = path[0].time
        let length = max(0.1, path[path.count - 1].time - first)
        let move = CAKeyframeAnimation(keyPath: "position")
        move.values = path.map { NSValue(point: SelectionGeometry.layerPoint($0.point, in: videoSize)) }
        move.keyTimes = path.map { NSNumber(value: min(1, max(0, ($0.time - first) / length))) }

        let fade = min(EffectsPlanner.effectFade, length / 4) / length
        let show = CAKeyframeAnimation(keyPath: "opacity")
        show.values = [0, 1, 1, 0]
        show.keyTimes = [0, fade, 1 - fade, 1].map { NSNumber(value: $0) }

        let group = CAAnimationGroup()
        group.animations = [move, show]
        group.beginTime = begin(start)
        group.duration = length
        group.isRemovedOnCompletion = false
        sheet.add(group, forKey: "spotlight")
        return sheet
    }

    /// The blur of a hidden stretch coming in, staying and going: the radius of the filter named
    /// `hide` on the content layer.
    private static func hide(from start: Double, to end: Double, radius: CGFloat) -> CAAnimation {
        let length = max(0.1, end - start)
        let fade = min(EffectsPlanner.effectFade, length / 4) / length
        let animation = CAKeyframeAnimation(keyPath: "filters.hide.inputRadius")
        animation.values = [0, radius, radius, 0]
        animation.keyTimes = [0, fade, 1 - fade, 1].map { NSNumber(value: $0) }
        animation.beginTime = begin(start)
        animation.duration = length
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// A dark capsule with the shortcut, at the bottom of the video.
    private static func captionLayer(_ string: String, from start: Double, to end: Double, videoSize: CGSize) -> CALayer {
        let fontSize = max(18, (videoSize.height * 0.045).rounded())
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold) as CTFont
        let text = NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: CGColor(gray: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(text)
        let textWidth = CTLineGetTypographicBounds(line, nil, nil, nil)

        let height = fontSize * 1.9
        let width = CGFloat(textWidth) + fontSize * 1.6
        let capsule = CALayer()
        capsule.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        capsule.position = CGPoint(x: videoSize.width / 2, y: height / 2 + videoSize.height * 0.06)
        capsule.backgroundColor = CGColor(gray: 0, alpha: 0.72)
        capsule.cornerRadius = height / 2
        capsule.opacity = 0

        let label = CATextLayer()
        label.string = text
        label.alignmentMode = .center
        label.frame = CGRect(x: 0, y: (height - fontSize * 1.25) / 2, width: width, height: fontSize * 1.25)
        label.contentsScale = 2
        capsule.addSublayer(label)

        let length = max(0.1, end - start)
        let fade = min(0.15, length / 4) / length
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0, 1, 1, 0]
        animation.keyTimes = [0, fade, 1 - fade, 1].map { NSNumber(value: $0) }
        animation.beginTime = begin(start)
        animation.duration = length
        animation.isRemovedOnCompletion = false
        capsule.add(animation, forKey: "caption")
        return capsule
    }
}
