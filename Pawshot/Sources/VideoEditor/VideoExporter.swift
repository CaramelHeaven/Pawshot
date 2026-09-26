import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum VideoExportError: LocalizedError {
    case unsupported
    case gifFailed
    case noVideo

    var errorDescription: String? {
        switch self {
        case .unsupported: "This recording can't be exported in that format."
        case .gifFailed: "The GIF couldn't be written."
        case .noVideo: "The recording has no picture in it."
        }
    }
}

/// Writes the kept pieces of a recording out in one of the presets, butted together.
///
/// Nonisolated on purpose: an export of a long take runs for seconds, and nothing of it belongs on
/// the main thread. Progress comes back through a `@Sendable` callback.
enum VideoExporter {
    static func export(
        source: URL,
        keep: KeepRanges,
        preset: VideoPreset,
        to destination: URL,
        timeline: EventTimeline = EventTimeline(),
        effects: EffectsOptions = EffectsOptions(),
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try? FileManager.default.removeItem(at: destination)
        let asset = AVURLAsset(url: source)
        let withEffects = !effects.isEmpty(for: timeline)

        if preset == .gif {
            guard withEffects else {
                try await exportGIF(asset: asset, keep: keep, to: destination, progress: progress)
                return
            }
            // The image generator can't run a Core Animation tool, so the effects are rendered
            // into a movie first and the GIF is taken from that — each pass half of the bar.
            let rendered = FileManager.default.temporaryDirectory
                .appendingPathComponent("pawshot-effects-\(UUID().uuidString).mov")
            defer { try? FileManager.default.removeItem(at: rendered) }
            let session = try await effectsSession(
                for: asset, keep: keep, preset: .fullHD, timeline: timeline, effects: effects
            )
            try await run(session, to: rendered, as: .mov) { progress($0 * 0.5) }

            let renderedAsset = AVURLAsset(url: rendered)
            let length = try await renderedAsset.load(.duration).seconds
            try await exportGIF(asset: renderedAsset, keep: KeepRanges(duration: length), to: destination) {
                progress(0.5 + $0 * 0.5)
            }
            return
        }

        let session = withEffects
            ? try await effectsSession(for: asset, keep: keep, preset: preset, timeline: timeline, effects: effects)
            : try await exportSession(for: asset, keep: keep, preset: preset)
        try await run(session, to: destination, as: .mp4, progress: progress)
    }

    private static func run(
        _ session: AVAssetExportSession,
        to destination: URL,
        as fileType: AVFileType,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let states = session.states(updateInterval: 0.1)
        let watcher = Task {
            for await state in states {
                if case let .exporting(current) = state {
                    progress(current.fractionCompleted)
                }
            }
        }
        defer { watcher.cancel() }

        try await session.export(to: destination, as: fileType)
        progress(1)
    }

    // MARK: - Splicing

    /// The kept pieces laid end to end in a composition that starts at zero — picture and every
    /// sound track alike — and what the picture needs to be drawn upright.
    private struct Spliced {
        let composition: AVMutableComposition
        let video: AVMutableCompositionTrack
        let audio: [AVMutableCompositionTrack]
        let transform: CGAffineTransform
        let videoSize: CGSize
    }

    private static func splice(_ asset: AVURLAsset, keep: KeepRanges) async throws -> Spliced {
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoExportError.noVideo
        }
        let (naturalSize, transform) = try await sourceVideo.load(.naturalSize, .preferredTransform)
        let upright = naturalSize.applying(transform)

        let composition = AVMutableComposition()
        let ranges = keep.timeRanges
        guard let video = try await insert(sourceVideo, pieces: ranges, into: composition) else {
            throw VideoExportError.noVideo
        }
        // A re-encode without a video composition reads the orientation off the track.
        video.preferredTransform = transform
        var audio: [AVMutableCompositionTrack] = []
        for track in try await asset.loadTracks(withMediaType: .audio) {
            if let inserted = try await insert(track, pieces: ranges, into: composition) {
                audio.append(inserted)
            }
        }
        return Spliced(
            composition: composition,
            video: video,
            audio: audio,
            transform: transform,
            videoSize: CGSize(width: abs(upright.width), height: abs(upright.height))
        )
    }

    /// What the editor plays: the very splice the export makes, sound mixed the same way — so
    /// playback shows no frame of the grey and the effects stop at a seam exactly where the file
    /// will stop them.
    @MainActor
    static func previewItem(source: URL, keep: KeepRanges) async throws -> AVPlayerItem {
        let spliced = try await splice(AVURLAsset(url: source), keep: keep)
        let item = AVPlayerItem(asset: spliced.composition)
        item.audioMix = mixed(spliced.audio)
        return item
    }

    /// Copies the parts of `track` inside `pieces` to one new track of `composition`, each piece
    /// straight after the one before. A sound track can start a moment after the picture; only
    /// what overlaps a piece is copied, at its own offset inside that piece, and the rest of the
    /// piece stays silent.
    private static func insert(
        _ track: AVAssetTrack,
        pieces: [CMTimeRange],
        into composition: AVMutableComposition
    ) async throws -> AVMutableCompositionTrack? {
        let own = try await track.load(.timeRange)
        var target: AVMutableCompositionTrack?
        var cursor = CMTime.zero
        for piece in pieces {
            let overlap = piece.intersection(own)
            if !overlap.isEmpty {
                if target == nil {
                    target = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                try target?.insertTimeRange(overlap, of: track, at: cursor + (overlap.start - piece.start))
            }
            cursor = cursor + piece.duration
        }
        return target
    }

    private static func mixed(_ tracks: [AVAssetTrack]) -> AVMutableAudioMix? {
        guard tracks.count > 1 else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.map { AVMutableAudioMixInputParameters(track: $0) }
        return mix
    }

    // MARK: - Sessions

    /// The spliced recording with the effects laid over it by `AVVideoCompositionCoreAnimationTool`.
    /// Splicing the composition — rather than setting a time range on the session — is what makes
    /// time zero of the animations the start of the first piece, and every later piece follow on.
    private static func effectsSession(
        for asset: AVURLAsset,
        keep: KeepRanges,
        preset: VideoPreset,
        timeline: EventTimeline,
        effects: EffectsOptions
    ) async throws -> AVAssetExportSession {
        let spliced = try await splice(asset, keep: keep)

        let videoLayer = CALayer()
        let root = EffectsLayerBuilder.build(
            timeline: timeline,
            options: effects,
            videoSize: spliced.videoSize,
            keep: keep,
            videoLayer: videoLayer
        )

        var layerInstruction = AVVideoCompositionLayerInstruction.Configuration(assetTrack: spliced.video)
        layerInstruction.setTransform(spliced.transform, at: .zero)
        let instruction = AVVideoCompositionInstruction(configuration: .init(
            layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layerInstruction)],
            timeRange: CMTimeRange(start: .zero, duration: spliced.composition.duration)
        ))

        var configuration = AVVideoComposition.Configuration()
        // The recording's frame rate is variable — a still screen sends nothing — so the effects
        // are rendered at a steady 60, or a zoom would stutter over a static page.
        configuration.frameDuration = CMTime(value: 1, timescale: 60)
        configuration.renderSize = spliced.videoSize
        configuration.instructions = [instruction]
        configuration.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: root
        )
        let videoComposition = AVVideoComposition(configuration: configuration)

        // Effects mean re-encoding, so the original becomes the best HEVC rather than passthrough.
        let name = preset == .fullHD ? AVAssetExportPreset1920x1080 : AVAssetExportPresetHEVCHighestQuality
        guard let session = AVAssetExportSession(asset: spliced.composition, presetName: name) else {
            throw VideoExportError.unsupported
        }
        session.videoComposition = videoComposition
        session.audioMix = mixed(spliced.audio)
        session.shouldOptimizeForNetworkUse = true
        return session
    }

    /// The size the export will come out at, for the "≈ 4.2 MB" under the strip. `0` when it can't
    /// be told.
    static func estimatedSize(source: URL, keep: KeepRanges, preset: VideoPreset) async -> Int64 {
        let asset = AVURLAsset(url: source)
        do {
            if preset == .gif {
                return try await estimatedGIFSize(asset: asset, keep: keep)
            }
            let session = try await exportSession(for: asset, keep: keep, preset: preset)
            let estimate = try await session.estimatedOutputFileLengthInBytes
            if estimate > 0 {
                return estimate
            }
        } catch {
            return 0
        }

        // Passthrough sometimes won't estimate; its output is the input, cut.
        let fileSize = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return keep.duration > 0 ? Int64(Double(fileSize) * keep.totalLength / keep.duration) : 0
    }

    /// One piece goes out untouched — passthrough, no re-encoding — unless the microphone was
    /// recorded as well. Then there are two sound tracks, and most players play only the first, so
    /// they have to become one, and only re-encoding can do that.
    ///
    /// Measured, not assumed: `HEVCHighestQuality` on its own keeps both tracks (1920x1080 happens
    /// to mix them). An explicit `audioMix` naming every track is what makes any preset mix them —
    /// `VideoExporterTests.testTwoSoundTracksComeOutMixedIntoOne` pins it.
    ///
    /// Several pieces are re-encoded too. Butted together in passthrough, a seam that doesn't fall
    /// on a key frame is carried by an edit list, and not every player honours one.
    private static func exportSession(
        for asset: AVURLAsset,
        keep: KeepRanges,
        preset: VideoPreset
    ) async throws -> AVAssetExportSession {
        guard preset != .gif else { throw VideoExportError.unsupported }

        if keep.pieces.count > 1 {
            let spliced = try await splice(asset, keep: keep)
            let name = preset == .fullHD ? AVAssetExportPreset1920x1080 : AVAssetExportPresetHEVCHighestQuality
            guard let session = AVAssetExportSession(asset: spliced.composition, presetName: name) else {
                throw VideoExportError.unsupported
            }
            session.audioMix = mixed(spliced.audio)
            session.shouldOptimizeForNetworkUse = true
            return session
        }

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let name = switch preset {
        case .fullHD: AVAssetExportPreset1920x1080
        default: audioTracks.count > 1 ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetPassthrough
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: name) else {
            throw VideoExportError.unsupported
        }
        if !keep.isWhole, let range = keep.timeRanges.first {
            session.timeRange = range
        }
        session.audioMix = mixed(audioTracks)
        session.shouldOptimizeForNetworkUse = true
        return session
    }

    // MARK: - GIF

    /// Fifteen frames a second out of every kept piece, and none from what was cut.
    private static func frameTimes(for keep: KeepRanges) -> [CMTime] {
        let step = 1 / Double(VideoPreset.gifFramesPerSecond)
        return keep.pieces.flatMap { piece in
            stride(from: piece.start, to: piece.end, by: step).map {
                CMTime(seconds: $0, preferredTimescale: 600)
            }
        }
    }

    private static func gifGenerator(for asset: AVURLAsset) async throws -> AVAssetImageGenerator {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoExportError.noVideo
        }
        let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
        let upright = naturalSize.applying(transform)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = VideoPreset.gifPixelSize(for: CGSize(width: abs(upright.width), height: abs(upright.height)))
        // Half a GIF frame either way: exact frames would make the decoder work for nothing.
        let tolerance = CMTime(value: 1, timescale: CMTimeScale(VideoPreset.gifFramesPerSecond * 2))
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        return generator
    }

    /// Frames come one at a time and go straight into the file: a minute at 15 frames a second is
    /// 900 pictures, gigabytes if they were held. `images(for:)` delivers them in the order asked.
    private static func exportGIF(
        asset: AVURLAsset,
        keep: KeepRanges,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let times = frameTimes(for: keep)
        let generator = try await gifGenerator(for: asset)
        guard let writer = GIFWriter(url: destination, frameCount: times.count) else {
            throw VideoExportError.gifFailed
        }

        var done = 0
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            if let image = try? result.image {
                writer.add(image)
            }
            done += 1
            progress(Double(done) / Double(max(1, times.count)))
        }
        guard writer.finish() else { throw VideoExportError.gifFailed }
    }

    /// Six frames spread over the kept pieces, encoded for real, scaled up to the whole length. GIF sizes
    /// depend on what is on screen far more than on anything a formula could know.
    private static func estimatedGIFSize(asset: AVURLAsset, keep: KeepRanges) async throws -> Int64 {
        let times = frameTimes(for: keep)
        guard !times.isEmpty else { return 0 }
        let sampleCount = min(6, times.count)
        let sample = (0 ..< sampleCount).map { times[$0 * times.count / sampleCount] }

        let generator = try await gifGenerator(for: asset)
        let data = NSMutableData()
        guard let writer = GIFWriter(data: data, frameCount: sampleCount) else { return 0 }
        for await result in generator.images(for: sample) {
            if let image = try? result.image {
                writer.add(image)
            }
        }
        guard writer.finish() else { return 0 }
        return Int64(Double(data.length) / Double(sampleCount) * Double(times.count))
    }
}

/// An animated GIF, written frame by frame through ImageIO: looping forever, 15 frames a second.
/// No gifski — its licence is AGPL, and ImageIO ships with the system.
final class GIFWriter {
    private let destination: CGImageDestination
    private let frameProperties: CFDictionary

    convenience init?(url: URL, frameCount: Int) {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frameCount, nil
        ) else { return nil }
        self.init(destination: destination)
    }

    convenience init?(data: NSMutableData, frameCount: Int) {
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.gif.identifier as CFString, frameCount, nil
        ) else { return nil }
        self.init(destination: destination)
    }

    private init(destination: CGImageDestination) {
        self.destination = destination
        let delay = 1 / Double(VideoPreset.gifFramesPerSecond)
        frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ],
        ] as CFDictionary
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
    }

    func add(_ image: CGImage) {
        CGImageDestinationAddImage(destination, image, frameProperties)
    }

    func finish() -> Bool {
        CGImageDestinationFinalize(destination)
    }
}

/// Where a finished video goes: the Desktop, or a file on the clipboard.
enum VideoHandOff {
    static func desktopURL(for preset: VideoPreset) throws -> URL {
        let desktop = try FileManager.default.url(
            for: .desktopDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )
        return desktop.appendingPathComponent(ExportNaming.fileName(extension: preset.fileExtension))
    }

    /// A file on the clipboard has to outlive the paste, so clips live in Caches rather than in
    /// the temporary folder. Anything older than a day is swept on the way in.
    static func clipURL(for preset: VideoPreset) throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let folder = caches.appendingPathComponent("com.caramelheaven.pawshot/Clips", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        sweep(folder, olderThan: 24 * 60 * 60)
        return folder.appendingPathComponent(ExportNaming.fileName(extension: preset.fileExtension))
    }

    /// The file itself, the way Finder copies one: apps take it as an attachment. A GIF also goes
    /// as GIF data, for the apps that paste pictures rather than files.
    static func copy(_ file: URL, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(file.absoluteString, forType: .fileURL)
        if file.pathExtension == "gif", let data = try? Data(contentsOf: file) {
            item.setData(data, forType: NSPasteboard.PasteboardType(UTType.gif.identifier))
        }
        pasteboard.writeObjects([item])
    }

    private static func sweep(_ folder: URL, olderThan age: TimeInterval) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, Date().timeIntervalSince(modified) > age {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
