import AppKit
import AVFoundation
import CoreText
import QuartzCore

/// Which effects go into the video.
struct EffectsOptions: Equatable {
    var clicks = true
    var keys = true
    var zooms = true

    /// Nothing to draw: the video can go out as it is.
    func isEmpty(for timeline: EventTimeline) -> Bool {
        (!clicks || timeline.clicks.isEmpty)
            && (!keys || timeline.keys.isEmpty)
            && (!zooms || timeline.zoomMarks.isEmpty)
    }
}

/// Builds the Core Animation tree of the effects. One tree, two uses: the export hands it to
/// `AVVideoCompositionCoreAnimationTool`, the editor's preview puts it in an `AVSynchronizedLayer`
/// over the player — so what is previewed is what comes out.
///
/// ```
/// root (the video's size, clipping)
///   ├ content (zoomed)
///   │   ├ video
///   │   └ click rings
///   └ key captions (not zoomed: they are a caption, not part of the picture)
/// ```
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
                for (index, span) in spans(from: segment.start, to: segment.end, in: keep).enumerated() {
                    content.add(
                        zoom(center: segment.center, from: span.start, to: span.end, videoSize: videoSize),
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
        keep.pieces.compactMap { piece in
            let low = max(start, piece.start)
            let high = min(end, piece.end)
            guard high - low > 0.05, let output = keep.outputTime(forSource: low) else { return nil }
            return (output, output + (high - low))
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

    private static func zoom(center normalized: CGPoint, from start: Double, to end: Double, videoSize: CGSize) -> CAAnimation {
        let scale = EffectsPlanner.zoomScale
        let center = SelectionGeometry.layerPoint(normalized, in: videoSize)
        let offset = SelectionGeometry.zoomOffset(center: center, scale: scale, size: videoSize)
        let zoomed = CATransform3DScale(CATransform3DMakeTranslation(offset.x, offset.y, 0), scale, scale, 1)

        let length = end - start
        let ramp = min(EffectsPlanner.zoomRamp, length / 2) / length
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = [CATransform3DIdentity, zoomed, zoomed, CATransform3DIdentity].map { NSValue(caTransform3D: $0) }
        animation.keyTimes = [0, ramp, 1 - ramp, 1].map { NSNumber(value: $0) }
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
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
