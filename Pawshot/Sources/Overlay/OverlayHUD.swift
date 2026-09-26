import AppKit
import SwiftUI

/// The glass pieces floating over the capture overlay: the size badge by the cursor, the key hints
/// along the bottom, and — when recording — the sound bar under the region.
///
/// One of each for the whole app, built and laid out once at launch (`prepare()`), then moved into
/// whichever overlay view the cursor is over. A SwiftUI view is not free to create, and the overlay
/// has 4–13 ms to appear after the hotkey — so it never pays for a fresh one.
@MainActor
enum OverlayHUD {
    static let badge = BadgeModel()
    static let hints = HintsModel()
    static let recordingBar = RecordingBarModel()

    static let badgeHost: NSHostingView<OverlayBadgeView> = {
        let host = NSHostingView(rootView: OverlayBadgeView(model: badge))
        host.sizingOptions = []
        return host
    }()

    static let hintsHost: NSHostingView<OverlayHintsView> = {
        let host = NSHostingView(rootView: OverlayHintsView(model: hints))
        host.sizingOptions = []
        return host
    }()

    /// Unlike the badge and the hints, the bar has buttons, so it needs a real frame: with
    /// `sizingOptions = []` a hosting view's `fittingSize` is 0×0, SwiftUI still draws the content
    /// past the empty frame, and the bar looks fine while every click goes straight through it to
    /// the overlay — which read the click as the start of a new region. `.intrinsicContentSize`
    /// is what makes `fittingSize` measure. `RecordingBarInOverlayTests` clicks Record for real.
    ///
    /// The badge and the hints keep `[]` and their zero frames on purpose: they only show, and a
    /// zero frame is what keeps them from ever catching a click meant for the overlay.
    static let recordingBarHost: BarHostingView = {
        let host = BarHostingView(rootView: RecordingBarView(model: recordingBar))
        host.sizingOptions = [.intrinsicContentSize]
        return host
    }()

    /// Builds the views and runs their first layout ahead of time, at launch.
    static func prepare() {
        badge.primary = "0000 × 0000 px"
        badge.secondary = "0000, 0000"
        _ = badgeHost.fittingSize
        _ = hintsHost.fittingSize
        _ = recordingBarHost.fittingSize
    }

    /// The bar's host, if it is inside `view` and `point` (in `view`'s coordinates) is on it.
    static func barContains(_ point: CGPoint, in view: NSView) -> Bool {
        recordingBarHost.superview === view && recordingBarHost.frame.contains(point)
    }

    static func hide() {
        badgeHost.removeFromSuperview()
        hintsHost.removeFromSuperview()
        recordingBarHost.removeFromSuperview()
    }

    @MainActor
    @Observable
    final class BadgeModel {
        var primary = ""
        var secondary = ""
    }

    @MainActor
    @Observable
    final class HintsModel {
        var mode: SelectionView.Mode = .region
        var purpose: OverlayPurpose = .screenshot
        var loupeIsOn = false
    }

    /// What the sound bar shows and what its buttons do. The actions are filled in by whoever
    /// runs the overlay.
    @MainActor
    @Observable
    final class RecordingBarModel {
        var microphoneIsOn = false
        var systemAudioIsOn = true
        /// 0…1, for the meter next to the microphone.
        var level: Float = 0
        /// The microphone is on and delivers nothing — dead, muted in hardware, or gone.
        var microphoneIsSilent = false

        @ObservationIgnored var toggleMicrophone: () -> Void = {}
        @ObservationIgnored var toggleSystemAudio: () -> Void = {}
        @ObservationIgnored var start: () -> Void = {}
    }
}

/// The size of the selection in pixels of the file, big; where the cursor is, in points, small.
/// Clear glass over a dark scrim: the frozen screen underneath can be anything, and the text has to
/// read over all of it.
struct OverlayBadgeView: View {
    let model: OverlayHUD.BadgeModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(model.primary)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
            if !model.secondary.isEmpty {
                Text(model.secondary)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
        .foregroundStyle(.white)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(.black.opacity(0.42), in: .capsule)
        .glassEffect(.clear, in: .capsule)
        .environment(\.colorScheme, .dark)
    }
}

/// What the keys do, for the first few captures. Only keys that really do something are listed.
struct OverlayHintsView: View {
    let model: OverlayHUD.HintsModel

    var body: some View {
        HStack(spacing: 16) {
            if model.purpose == .recording {
                recordingHints
            } else {
                hint("Space", model.mode == .region ? "window" : "region")
                if model.mode == .region {
                    hint("M", model.loupeIsOn ? "hide loupe" : "loupe")
                }
                hint("Esc", "cancel")
            }
        }
        .font(.callout)
        .foregroundStyle(.white)
        .fixedSize()
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.black.opacity(0.3), in: .capsule)
        .glassEffect(.clear, in: .capsule)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var recordingHints: some View {
        hint("↩", "record")
        hint("A", "ratio")
        hint("X", "1x / 2x")
        hint("Space", model.mode == .region ? "window" : "region")
        hint("Esc", "cancel")
    }

    private func hint(_ key: LocalizedStringKey, _ action: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.callout.monospaced().weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.white.opacity(0.16), in: .rect(cornerRadius: Tokens.Radius.keyCap))
            Text(action)
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

/// The bar's hosting view, with the two things a plain `NSHostingView` gets wrong inside the
/// capture overlay:
///
/// - **the first click.** macOS 14+ may not grant Pawshot the activation after a Carbon hotkey,
///   and a click into an inactive app's view that doesn't accept the first mouse only activates
///   it — the region is drawn (the overlay accepts it), but Record does nothing;
/// - **the cursor.** The overlay puts its crosshair over the whole screen; over buttons it has to
///   be the ordinary arrow.
final class BarHostingView: NSHostingView<RecordingBarView> {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}

/// Under a recording region before the take: the microphone with its live level, the system sound,
/// and the key that starts. Each piece is a button as well as a key (M, S, ↩).
///
/// A microphone that is on and delivers nothing pulses red once and says so — no dialog, the take
/// hasn't started and nothing is lost yet.
struct RecordingBarView: View {
    let model: OverlayHUD.RecordingBarModel

    var body: some View {
        HStack(spacing: 14) {
            Button(action: { model.toggleMicrophone() }) {
                HStack(spacing: 6) {
                    Image(systemName: model.microphoneIsOn ? "mic.fill" : "mic.slash.fill")
                        .foregroundStyle(microphoneColor)
                        .symbolEffect(.bounce, value: model.microphoneIsSilent)
                    if model.microphoneIsOn {
                        if model.microphoneIsSilent {
                            Text("no signal")
                                .foregroundStyle(.red)
                        } else {
                            LevelMeter(level: model.level)
                        }
                    }
                }
                .barHitArea()
            }
            .help("Microphone (M)")

            Button(action: { model.toggleSystemAudio() }) {
                Image(systemName: model.systemAudioIsOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .foregroundStyle(model.systemAudioIsOn ? Color.white : Color.white.opacity(0.45))
                    .barHitArea()
            }
            .help("System audio (S)")

            Divider().frame(height: 16)

            Button(action: { model.start() }) {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 9, height: 9)
                    Text("Record")
                    Text("↩")
                        .font(.callout.monospaced().weight(.semibold))
                        .padding(.horizontal, 5)
                        .background(.white.opacity(0.16), in: .rect(cornerRadius: Tokens.Radius.keyCap))
                }
                .barHitArea()
            }
        }
        .buttonStyle(.plain)
        .font(.callout.weight(.medium))
        .foregroundStyle(.white)
        .fixedSize()
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(.black.opacity(0.35), in: .capsule)
        .glassEffect(.clear, in: .capsule)
        .environment(\.colorScheme, .dark)
    }

    private var microphoneColor: Color {
        guard model.microphoneIsOn else { return .white.opacity(0.45) }
        return model.microphoneIsSilent ? .red : .white
    }
}

/// Five bars that light up with the level, the way the menu bar's input meter reads.
private struct LevelMeter: View {
    let level: Float

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0 ..< 5, id: \.self) { index in
                Capsule()
                    .fill(Float(index) / 5 < level ? Color.green : Color.white.opacity(0.22))
                    .frame(width: 3, height: 6 + CGFloat(index) * 2)
            }
        }
        .frame(height: 14, alignment: .bottom)
        .animation(.linear(duration: 0.08), value: level)
    }
}

private extension View {
    /// A plain-style button only answers where its label draws something; this makes the whole
    /// piece of the bar — gaps and padding included — part of the button.
    func barHitArea() -> some View {
        padding(.vertical, 4)
            .contentShape(.rect)
    }
}
