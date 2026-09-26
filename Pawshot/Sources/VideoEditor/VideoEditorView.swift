import AVFoundation
import SwiftUI

/// What the video editor shows. Owned by `VideoEditorWindowController`, which does the work.
@MainActor
@Observable
final class VideoEditorModel {
    var videoSize: CGSize
    /// The pieces of the recording that go into the file.
    var keep = KeepRanges(duration: 0)
    /// The piece clicked last: ⌫ removes it.
    var selectedPiece: Int?
    var currentTime: TimeInterval = 0
    var isPlaying = false
    /// The pieces the playback splice was built for, `nil` before the first play.
    var spliceKeep: KeepRanges?
    /// The preview shows the splice rather than the recording — set once its frame is ready, so
    /// the switch never flashes.
    var showsSplice = false
    var preset: VideoPreset
    var thumbnails: [CGImage] = []
    var estimatedBytes: Int64 = 0
    /// 0…1 while an export runs, `nil` otherwise.
    var exportProgress: Double?
    var exportStarted: Date?
    /// What happened during the take, and which of it goes into the video.
    var timeline = EventTimeline()
    var effects = EffectsOptions()
    /// The key hints under the strip, for the first few openings.
    var showsHints = false

    init(videoSize: CGSize, preset: VideoPreset) {
        self.videoSize = videoSize
        self.preset = preset
    }
}

/// The buttons and gestures of the editor, answered by the window controller.
struct VideoEditorActions {
    var togglePlay: @MainActor () -> Void
    var seek: @MainActor (TimeInterval) -> Void
    /// The pieces while a hand is still on them — shown at once, not yet a step of ⌘Z.
    var editKeep: @MainActor (KeepRanges) -> Void
    /// The hand let go: what the pieces were before it is one step of ⌘Z.
    var commitKeep: @MainActor (_ before: KeepRanges) -> Void
    var selectPiece: @MainActor (Int?) -> Void
    var cyclePreset: @MainActor () -> Void
    var copy: @MainActor () -> Void
    var save: @MainActor () -> Void
    var setEffects: @MainActor (EffectsOptions) -> Void
}

/// The player, the film strip with the orange brackets around every kept piece, and the line that
/// says what comes out: the preset, the length, the size, and the two ways out.
struct VideoEditorView: View {
    let model: VideoEditorModel
    let player: AVPlayer
    let splicePlayer: AVPlayer
    let actions: VideoEditorActions

    var body: some View {
        VStack(spacing: 12) {
            EffectsPreview(
                player: player,
                splicePlayer: splicePlayer,
                timeline: model.timeline,
                effects: model.effects,
                videoSize: model.videoSize,
                duration: model.keep.duration,
                spliceKeep: model.spliceKeep,
                showsSplice: model.showsSplice
            )
            .aspectRatio(model.videoSize, contentMode: .fit)
            .background(.black)
            .clipShape(.rect(cornerRadius: 10))
            .contentShape(.rect)
            .onTapGesture { actions.togglePlay() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 6) {
                if model.keep.pieces.count > 1 {
                    HStack {
                        Spacer()
                        Text("\(model.keep.pieces.count) pieces · total \(VideoEditing.durationText(model.keep.totalLength))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                FilmStrip(model: model, actions: actions)
                    .frame(height: 52)
                if model.showsHints {
                    EditorHints()
                }
            }

            if let progress = model.exportProgress {
                exportLine(progress)
            } else {
                footer
            }
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(action: actions.togglePlay) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.glass)
            .help("Play / Pause (Space)")

            Button(action: actions.cyclePreset) {
                HStack(spacing: 6) {
                    Text(model.preset.title)
                    Text("P")
                        .font(.caption.monospaced().weight(.semibold))
                        .padding(.horizontal, 4)
                        .background(.quaternary, in: .rect(cornerRadius: Tokens.Radius.keyCap))
                }
            }
            .buttonStyle(.glass)
            .help("Format (P)")

            effectToggles

            Spacer()

            // The length of what comes out — every kept piece, butted together.
            Text(VideoEditing.durationText(model.keep.totalLength))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if model.estimatedBytes > 0 {
                Text(VideoEditing.approximateSize(model.estimatedBytes))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Button("Copy", action: actions.copy)
                .buttonStyle(.glass)
                .help("Copy the file (⌘C) — ⇧⌘C copies a GIF")
            Button("Save", action: actions.save)
                .buttonStyle(.glassProminent)
                .tint(Tokens.paw)
                .help("Save to the Desktop (⌘S)")
        }
        .controlSize(.large)
    }

    /// One small toggle per effect the take actually has — no clicks recorded, no clicks switch.
    @ViewBuilder
    private var effectToggles: some View {
        let timeline = model.timeline
        HStack(spacing: 6) {
            if !timeline.clicks.isEmpty {
                effectToggle("cursorarrow.click", "Clicks", isOn: model.effects.clicks) { $0.clicks.toggle() }
            }
            if !timeline.keys.isEmpty {
                effectToggle("command", "Shortcuts", isOn: model.effects.keys) { $0.keys.toggle() }
            }
            if !timeline.zoomMarks.isEmpty {
                effectToggle("plus.magnifyingglass", "Zooms", isOn: model.effects.zooms) { $0.zooms.toggle() }
            }
        }
    }

    private func effectToggle(
        _ symbol: String,
        _ help: String,
        isOn: Bool,
        change: @escaping (inout EffectsOptions) -> Void
    ) -> some View {
        Button {
            var effects = model.effects
            change(&effects)
            actions.setEffects(effects)
        } label: {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(isOn ? Tokens.paw : Color.secondary)
        }
        .buttonStyle(.glass)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(isOn ? "on" : "off")
    }

    private func exportLine(_ progress: Double) -> some View {
        HStack(spacing: 12) {
            ProgressView(value: progress)
                .tint(Tokens.paw)
            Text(exportStatus(progress))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 140, alignment: .trailing)
        }
        .frame(height: 32)
    }

    private func exportStatus(_ progress: Double) -> String {
        let percent = "\(Int(progress * 100))%"
        guard
            let started = model.exportStarted,
            let left = VideoEditing.remainingTime(elapsed: Date().timeIntervalSince(started), progress: progress)
        else { return percent }
        return "\(percent) · \(Int(left.rounded(.up))) s left"
    }
}

/// What the keys do, for the first few openings — the same idea as the hints on the capture
/// overlay. Only what really works here is listed.
private struct EditorHints: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { hints }
            VStack(alignment: .leading, spacing: 4) { hints }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var hints: some View {
        hint("Space", "play")
        hint("drag over the grey", "keep another piece")
        hint("⌫", "remove the piece")
        hint("P", "format")
        hint("⌘C", "copy")
        hint("⇧⌘C", "GIF")
        hint("⌘S", "save")
    }

    private func hint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.caption.monospaced().weight(.semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: .rect(cornerRadius: Tokens.Radius.keyCap))
            Text(action)
        }
        .fixedSize()
    }
}

/// Thumbnails along the whole recording. Every kept piece sits inside a pair of orange corner
/// brackets — the app icon's corners — and the grey between them is what gets cut.
///
/// - drag a bracket's edge to move it;
/// - drag over the grey to keep another piece there;
/// - click a piece to select it (⌫ removes it), click the grey to go there.
private struct FilmStrip: View {
    let model: VideoEditorModel
    let actions: VideoEditorActions

    private enum Drag {
        /// Pressed on a piece: the drag scrubs.
        case scrub
        /// Pressed on the grey: a drag keeps a new piece, a click only goes there.
        case newPiece(anchor: TimeInterval, before: KeepRanges)
    }

    @State private var drag: Drag?
    @State private var edgeDragBefore: KeepRanges?

    private static let handleWidth: CGFloat = 14
    /// Less than this and a press on the grey is a click, not a new piece.
    private static let dragThreshold: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let keep = model.keep
            let x = { (time: TimeInterval) in keep.fraction(of: time) * width }

            ZStack(alignment: .topLeading) {
                thumbnails(width: width, height: height)

                ForEach(Array(keep.gaps.enumerated()), id: \.offset) { _, gap in
                    Rectangle()
                        .fill(.black.opacity(0.6))
                        .frame(width: max(0, x(gap.end) - x(gap.start)), height: height)
                        .offset(x: x(gap.start))
                        .allowsHitTesting(false)
                }

                ForEach(Array(keep.pieces.enumerated()), id: \.offset) { index, piece in
                    CornerBrackets(armLength: 12)
                        .bracketStroke(Tokens.paw, width: model.selectedPiece == index && keep.pieces.count > 1 ? 4.5 : 3)
                        .frame(width: max(0, x(piece.end) - x(piece.start)), height: height)
                        .offset(x: x(piece.start))
                        .allowsHitTesting(false)
                }

                Rectangle()
                    .fill(.white)
                    .frame(width: 2, height: height + 6)
                    .offset(x: x(model.currentTime) - 1, y: -3)
                    .shadow(radius: 1)
                    .allowsHitTesting(false)

                ForEach(Array(keep.pieces.enumerated()), id: \.offset) { index, piece in
                    edge(at: x(piece.start), height: height, width: width) { keep, time in
                        keep.moveStart(of: index, to: time)
                        return keep.pieces[index].start
                    }
                    edge(at: x(piece.end), height: height, width: width) { keep, time in
                        keep.moveEnd(of: index, to: time)
                        return keep.pieces[index].end
                    }
                }
            }
            .coordinateSpace(.named("strip"))
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                    .onChanged { dragChanged($0, width: width) }
                    .onEnded { dragEnded($0, width: width) }
            )
        }
    }

    private func dragChanged(_ value: DragGesture.Value, width: CGFloat) {
        let time = model.keep.time(at: value.location.x / width)

        if drag == nil {
            let pressed = model.keep.time(at: value.startLocation.x / width)
            if let piece = model.keep.piece(containing: pressed) {
                drag = .scrub
                actions.selectPiece(piece)
                actions.seek(pressed)
            } else {
                drag = .newPiece(anchor: pressed, before: model.keep)
            }
        }

        switch drag {
        case .scrub:
            actions.seek(time)
        case let .newPiece(anchor, before):
            guard abs(value.translation.width) > Self.dragThreshold else { return }
            var keep = before
            if let index = keep.add(from: anchor, to: time) {
                actions.editKeep(keep)
                actions.selectPiece(index)
            } else {
                // Too short to keep: the index it had selected may belong to another piece now.
                actions.editKeep(before)
                actions.selectPiece(nil)
            }
        case nil:
            break
        }
    }

    private func dragEnded(_ value: DragGesture.Value, width _: CGFloat) {
        if case let .newPiece(anchor, before) = drag {
            if abs(value.translation.width) <= Self.dragThreshold {
                actions.selectPiece(nil)
                actions.seek(anchor)
            } else if model.keep != before {
                actions.commitKeep(before)
            }
        }
        drag = nil
    }

    private func thumbnails(width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, image in
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width / CGFloat(max(1, model.thumbnails.count)), height: height)
                    .clipped()
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .background(.quaternary)
        .clipShape(.rect(cornerRadius: 6))
    }

    /// An invisible grip on one edge of a piece, wider than the line, so it is easy to catch.
    /// `move` applies the drag to a copy of the pieces and says where the edge ended up.
    private func edge(
        at x: CGFloat,
        height: CGFloat,
        width: CGFloat,
        move: @escaping (inout KeepRanges, TimeInterval) -> TimeInterval
    ) -> some View {
        Rectangle()
            .fill(.clear)
            .frame(width: Self.handleWidth, height: height)
            .contentShape(.rect)
            .offset(x: x - Self.handleWidth / 2)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                    .onChanged { value in
                        let before = edgeDragBefore ?? model.keep
                        edgeDragBefore = before
                        var keep = before
                        let landed = move(&keep, model.keep.time(at: value.location.x / width))
                        actions.editKeep(keep)
                        actions.seek(landed)
                    }
                    .onEnded { _ in
                        if let before = edgeDragBefore, before != model.keep {
                            actions.commitKeep(before)
                        }
                        edgeDragBefore = nil
                    }
            )
            .pointerStyle(.frameResize(position: .leading))
    }
}

/// The player with the effects over it, exactly as the export will draw them: the same
/// `EffectsLayerBuilder` tree, driven by the player's clock through an `AVSynchronizedLayer`. No
/// transport controls of AVKit's own — the strip and the footer are the controls.
///
/// Two of them, one above the other. Playing, the splice the export makes, with the export's own
/// tree — no frame of the grey, and effects stopping at a seam where the file stops them. Paused
/// or edited, the recording itself on its own time, so the grey an edge is dragged into shows.
private struct EffectsPreview: NSViewRepresentable {
    let player: AVPlayer
    let splicePlayer: AVPlayer
    let timeline: EventTimeline
    let effects: EffectsOptions
    let videoSize: CGSize
    let duration: Double
    let spliceKeep: KeepRanges?
    let showsSplice: Bool

    func makeNSView(context _: Context) -> EffectsPreviewView {
        EffectsPreviewView(player: player, splicePlayer: splicePlayer)
    }

    func updateNSView(_ view: EffectsPreviewView, context _: Context) {
        view.show(
            timeline: timeline,
            effects: effects,
            videoSize: videoSize,
            duration: duration,
            spliceKeep: spliceKeep,
            showsSplice: showsSplice
        )
    }
}

final class EffectsPreviewView: NSView {
    /// A player, and the effects tree over it bound to that player's item.
    private final class Stack {
        let player: AVPlayer
        let playerLayer: AVPlayerLayer
        var synchronized: AVSynchronizedLayer?
        var tree: CALayer?
        var shown: (EventTimeline, EffectsOptions, CGSize, KeepRanges, ObjectIdentifier)?

        init(player: AVPlayer) {
            self.player = player
            playerLayer = AVPlayerLayer(player: player)
            playerLayer.videoGravity = .resize
        }
    }

    private let recording: Stack
    private let splice: Stack

    init(player: AVPlayer, splicePlayer: AVPlayer) {
        recording = Stack(player: player)
        splice = Stack(player: splicePlayer)
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unused — the UI is built in code")
    }

    func show(
        timeline: EventTimeline,
        effects: EffectsOptions,
        videoSize: CGSize,
        duration: Double,
        spliceKeep: KeepRanges?,
        showsSplice: Bool
    ) {
        build(recording, keep: KeepRanges(duration: max(duration, 0.01)), timeline, effects, videoSize)
        if let spliceKeep {
            build(splice, keep: spliceKeep, timeline, effects, videoSize)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        recording.synchronized?.isHidden = showsSplice
        splice.synchronized?.isHidden = !showsSplice
        CATransaction.commit()
    }

    /// Rebuilds a tree only when something in it changed — SwiftUI calls `show` on every redraw,
    /// the playhead included — or when its player got a new item, which the old tree isn't
    /// synchronised to.
    private func build(
        _ stack: Stack,
        keep: KeepRanges,
        _ timeline: EventTimeline,
        _ effects: EffectsOptions,
        _ videoSize: CGSize
    ) {
        guard let item = stack.player.currentItem, videoSize.width > 0 else { return }
        let key = (timeline, effects, videoSize, keep, ObjectIdentifier(item))
        if let shown = stack.shown, shown == key {
            return
        }
        stack.shown = key

        stack.synchronized?.removeFromSuperlayer()
        stack.playerLayer.removeFromSuperlayer()

        let root = EffectsLayerBuilder.build(
            timeline: timeline,
            options: effects,
            videoSize: videoSize,
            keep: keep,
            videoLayer: stack.playerLayer
        )
        let synchronized = AVSynchronizedLayer(playerItem: item)
        synchronized.addSublayer(root)
        layer?.addSublayer(synchronized)
        stack.synchronized = synchronized
        stack.tree = root
        needsLayout = true
    }

    /// The trees are built in the video's pixels; here they are scaled to whatever the view is.
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for stack in [recording, splice] {
            guard let synchronized = stack.synchronized, let tree = stack.tree else { continue }
            synchronized.frame = bounds
            let size = tree.bounds.size
            let scale = size.width > 0 ? min(bounds.width / size.width, bounds.height / size.height) : 1
            tree.position = CGPoint(x: bounds.midX, y: bounds.midY)
            tree.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        }
        CATransaction.commit()
    }
}
