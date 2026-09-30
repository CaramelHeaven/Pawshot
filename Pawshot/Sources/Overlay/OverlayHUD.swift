import AppKit
import SwiftUI

/// The glass pieces floating over the capture overlay: the size badge by the cursor, the key hints
/// along the bottom, and — when recording — the toolbar at the bottom of the screen.
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

    /// Unlike the badge and the hints, the toolbar has buttons, so it needs a real frame: with
    /// `sizingOptions = []` a hosting view's `fittingSize` is 0×0, SwiftUI still draws the content
    /// past the empty frame, and the toolbar looks fine while every click goes straight through
    /// it to the overlay — which read the click as the start of a new region.
    /// `.intrinsicContentSize` is what makes `fittingSize` measure. `RecordingBarInOverlayTests`
    /// clicks Record for real.
    ///
    /// The badge and the hints keep `[]` and their zero frames on purpose: they only show, and a
    /// zero frame is what keeps them from ever catching a click meant for the overlay.
    static let recordingBarHost: BarHostingView = {
        let host = BarHostingView(rootView: RecordingToolbarView(model: recordingBar))
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

    /// The toolbar's host, if it is inside `view` and `point` (in `view`'s coordinates) is on it.
    static func barContains(_ point: CGPoint, in view: NSView) -> Bool {
        recordingBarHost.superview === view && recordingBarHost.frame.contains(point)
    }

    /// Tells the toolbar where the mouse is, so its buttons can light up under it: the overlay
    /// hears every move of the mouse, toolbar included, and the buttons can't count on SwiftUI's
    /// own hover in a panel of an app that isn't active. `point` is in `view`'s coordinates.
    static func noteMouse(at point: CGPoint, in view: NSView) {
        let host = recordingBarHost
        var hover: CGPoint?
        if host.superview === view, host.frame.contains(point) {
            let local = host.convert(point, from: view)
            // SwiftUI counts from the top left whichever way the hosting view is flipped.
            hover = CGPoint(x: local.x, y: host.isFlipped ? local.y : host.bounds.height - local.y)
        }
        if recordingBar.hoverPoint != hover {
            recordingBar.hoverPoint = hover
        }
    }

    static func hide() {
        badgeHost.removeFromSuperview()
        hintsHost.removeFromSuperview()
        recordingBarHost.removeFromSuperview()
        recordingBar.hoverPoint = nil
        recordingBar.optionsShown = false
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

    /// What the recording toolbar shows and what its buttons do. The actions are filled in by
    /// whoever runs the overlay.
    @MainActor
    @Observable
    final class RecordingBarModel {
        var mode: SelectionView.Mode = .region
        var optionsShown = false
        /// Where the mouse is over the toolbar, in the toolbar's own space; see `ChromeButtonStyle`.
        var hoverPoint: CGPoint?

        var microphoneIsOn = false
        var systemAudioIsOn = true
        /// 0…1, for the meter next to the chosen microphone.
        var level: Float = 0
        /// The microphone is on and delivers nothing — dead, muted in hardware, or gone.
        var microphoneIsSilent = false
        /// The inputs the Mac has. Filled in when Options open: asking the system for the list is
        /// not something to do on the way from the hotkey to the dimming.
        var microphones: [MicrophoneDevices.Device] = []
        /// The one a take would record from.
        var microphoneID: String?
        /// The microphone is on and allowed, so a check of it (three seconds and back) can run.
        var canCheckMicrophone = false
        /// The profile the settings add up to, if they do.
        var profile: RecordingProfile?
        /// Zones to hide drawn on the region so far, and whether H is on (drawing one).
        var zoneCount = 0
        var isMarkingZones = false
        var echoPhase: MicrophoneEcho.Phase = .idle

        var showsClicks = true
        var showsKeystrokes = false
        /// Input Monitoring is granted: without it pressed shortcuts can't be read, and the
        /// overlay can't ask — the system's window would open underneath it.
        var keystrokesAllowed = false
        var nativeResolution = true
        /// A display with one pixel per point has nothing to switch.
        var canSwitchScale = true

        /// Our shortcuts of the take that macOS still holds, and the room on the disk. Read once,
        /// just after the overlay is up (`SelectionOverlayController.runPreflight`) — the
        /// preferences are not for the 4–13 ms between the hotkey and the dimming.
        var takenShortcuts: [RecordingPreflight.Taken] = []
        var freeBytes: Int64?

        /// What is wrong with the take right now: the facts above plus the microphone's, which
        /// change while the overlay is up. Empty means the line is not shown.
        var problems: [RecordingPreflight.Problem] {
            RecordingPreflight.problems(
                microphoneIsOn: microphoneIsOn,
                microphoneIsSilent: microphoneIsSilent,
                taken: takenShortcuts,
                freeBytes: freeBytes,
                ignoredZones: mode == .region ? 0 : zoneCount
            )
        }

        @ObservationIgnored var setMode: (SelectionView.Mode) -> Void = { _ in }
        @ObservationIgnored var toggleOptions: () -> Void = {}
        /// `nil` turns the microphone off.
        @ObservationIgnored var chooseMicrophone: (String?) -> Void = { _ in }
        @ObservationIgnored var toggleEcho: () -> Void = {}
        @ObservationIgnored var chooseProfile: (RecordingProfile) -> Void = { _ in }
        @ObservationIgnored var toggleZoneMarking: () -> Void = {}
        @ObservationIgnored var clearZones: () -> Void = {}
        @ObservationIgnored var toggleSystemAudio: () -> Void = {}
        @ObservationIgnored var toggleClicks: () -> Void = {}
        @ObservationIgnored var toggleKeystrokes: () -> Void = {}
        @ObservationIgnored var toggleScale: () -> Void = {}
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
        if model.mode == .region {
            hint("← →", "move")
            hint("A", "ratio")
        }
        hint("X", "1x / 2x")
        hint("M", "microphone")
        hint("S", "sound")
        hint("P", "profile")
        hint("H", "hide a zone")
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

/// The toolbar's hosting view, with the two things a plain `NSHostingView` gets wrong inside the
/// capture overlay:
///
/// - **the first click.** macOS 14+ may not grant Pawshot the activation after a Carbon hotkey,
///   and a click into an inactive app's view that doesn't accept the first mouse only activates
///   it — the region is drawn (the overlay accepts it), but Record does nothing;
/// - **the cursor.** The overlay puts its crosshair over the whole screen; over buttons it has to
///   be the ordinary arrow.
final class BarHostingView: NSHostingView<RecordingToolbarView> {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}

/// At the bottom of the screen before a take, the way the system's ⇧⌘5 has it: what to record —
/// a region, a window, the whole screen — then Options, then Record. It stays where it is while
/// the region is dragged about; the bar it replaced hung under the region and hid on every drag.
///
/// Options is a panel of this same view, not a menu: the overlay sits at the screen saver's
/// window level, and a system menu would open underneath it. It holds the microphone — none, or
/// one of the Mac's inputs, with the live level beside the chosen one — the system sound, what
/// is drawn into the video, and the scale.
///
/// A microphone that is on and delivers nothing puts a red dot on Options and says so inside —
/// no dialog, the take hasn't started and nothing is lost yet.
struct RecordingToolbarView: View {
    let model: OverlayHUD.RecordingBarModel

    var body: some View {
        VStack(spacing: 8) {
            if !model.problems.isEmpty {
                problems
            }
            if model.optionsShown {
                options
            }
            row
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(.white)
        .fixedSize()
        .coordinateSpace(.named(ChromeButtonStyle.space))
        .environment(\.chromeHoverPoint, model.hoverPoint)
        .environment(\.colorScheme, .dark)
    }

    private var row: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                modeButton(.region, symbol: "rectangle.dashed", tip: "Record Selected Portion")
                modeButton(.window, symbol: "macwindow", tip: "Record Selected Window (Space)")
                modeButton(.screen, symbol: "display", tip: "Record Entire Screen")
            }
            Divider().frame(height: 18)

            Button(action: { model.toggleOptions() }) {
                HStack(spacing: 5) {
                    Text("Options")
                    if model.microphoneIsOn, model.microphoneIsSilent {
                        Circle().fill(.red).frame(width: 6, height: 6)
                    }
                    Image(systemName: model.optionsShown ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.bold))
                }
            }
            .buttonStyle(ChromeButtonStyle(kind: model.optionsShown ? .selected : .plain))

            Button(action: { model.start() }) {
                HStack(spacing: 6) {
                    Circle().fill(.white).frame(width: 8, height: 8)
                    Text("Record")
                    Text("↩")
                        .font(.callout.monospaced().weight(.semibold))
                        .padding(.horizontal, 5)
                        .background(.white.opacity(0.2), in: .rect(cornerRadius: Tokens.Radius.keyCap))
                }
            }
            .buttonStyle(ChromeButtonStyle(
                kind: .record,
                tip: model.mode == .window ? "Click the window to record" : "Start recording (↩)"
            ))
            // A window is picked by clicking it, and the click starts the take.
            .disabled(model.mode == .window)
        }
        .padding(6)
        .background(.black.opacity(0.35), in: .rect(cornerRadius: 16))
        .glassEffect(.clear, in: .rect(cornerRadius: 16))
    }

    /// What will go wrong with the take, one line each, above the toolbar — nothing when nothing
    /// will. It only says; fixing is the person's move (a shortcut in System Settings, a cable).
    private var problems: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.problems.map(\.message), id: \.self) { message in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                    Text(verbatim: message)
                        .font(.callout)
                        .frame(width: 340, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.45), in: .rect(cornerRadius: 14))
        .glassEffect(.clear, in: .rect(cornerRadius: 14))
    }

    private func modeButton(_ mode: SelectionView.Mode, symbol: String, tip: LocalizedStringKey) -> some View {
        Button(action: { model.setMode(mode) }) {
            Image(systemName: symbol)
                .frame(width: 20, height: 18)
        }
        .buttonStyle(ChromeButtonStyle(kind: model.mode == mode ? .selected : .plain, tip: tip))
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 2) {
            header("Profile")
            ForEach(RecordingProfile.allCases) { profile in
                check(Text(verbatim: profile.title), isOn: model.profile == profile, action: { model.chooseProfile(profile) }) {
                    Text(verbatim: profile.summary).foregroundStyle(.white.opacity(0.55))
                }
            }

            header("Microphone")
            check(Text("None"), isOn: !model.microphoneIsOn) { model.chooseMicrophone(nil) }
            ForEach(model.microphones) { device in
                let chosen = model.microphoneIsOn && device.id == model.microphoneID
                // A device's name is its own, not a string of ours to translate.
                check(Text(verbatim: device.name), isOn: chosen, action: { model.chooseMicrophone(device.id) }) {
                    if chosen {
                        if model.microphoneIsSilent {
                            Text("no signal").foregroundStyle(.red)
                        } else {
                            LevelMeter(level: model.level)
                        }
                    }
                }
            }

            if model.canCheckMicrophone {
                check(Text(echoTitle), isOn: false) { model.toggleEcho() }
            }

            header("Sound")
            check(Text("System Audio"), isOn: model.systemAudioIsOn, key: "S") { model.toggleSystemAudio() }

            header("Hidden in the video")
            check(Text("Draw a zone to hide"), isOn: model.isMarkingZones, key: "H") { model.toggleZoneMarking() }
                // Zones are counted from a region; a window or the whole screen has none.
                .disabled(model.mode != .region)
            if model.zoneCount > 0 {
                check(Text("Clear zones (\(model.zoneCount))"), isOn: false) { model.clearZones() }
            }

            header("Shown in the video")
            check(Text("Clicks"), isOn: model.showsClicks) { model.toggleClicks() }
            check(Text("Pressed shortcuts"), isOn: model.showsKeystrokes && model.keystrokesAllowed, action: { model.toggleKeystrokes() }) {
                if !model.keystrokesAllowed {
                    Text("allow in Settings → Recording").foregroundStyle(.white.opacity(0.55))
                }
            }
            .disabled(!model.keystrokesAllowed)

            if model.canSwitchScale {
                header("Resolution")
                check(Text("Retina, 2x"), isOn: model.nativeResolution, key: "X") { model.toggleScale() }
            }
        }
        .buttonStyle(ChromeButtonStyle())
        .padding(8)
        .background(.black.opacity(0.45), in: .rect(cornerRadius: 16))
        .glassEffect(.clear, in: .rect(cornerRadius: 16))
    }

    private var echoTitle: LocalizedStringKey {
        switch model.echoPhase {
        case .idle: "Check the microphone"
        case .listening: "Say something… (tap to stop)"
        case .playing: "Playing it back… (tap to stop)"
        }
    }

    private func header(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.55))
            .padding(.horizontal, 9)
            .padding(.top, 6)
    }

    private func check(
        _ title: Text,
        isOn: Bool,
        key: LocalizedStringKey? = nil,
        action: @escaping () -> Void
    ) -> some View {
        check(title, isOn: isOn, key: key, action: action) { EmptyView() }
    }

    /// One row of Options: a tick, a name, and whatever goes on the right.
    private func check(
        _ title: Text,
        isOn: Bool,
        key: LocalizedStringKey? = nil,
        action: @escaping () -> Void,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .opacity(isOn ? 1 : 0)
                title
                Spacer(minLength: 16)
                trailing()
                if let key {
                    Text(key)
                        .font(.caption.monospaced().weight(.semibold))
                        .padding(.horizontal, 5)
                        .background(.white.opacity(0.16), in: .rect(cornerRadius: Tokens.Radius.keyCap))
                }
            }
            .frame(minWidth: 250)
        }
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
