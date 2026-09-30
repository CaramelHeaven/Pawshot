import AppKit
import os
import SwiftUI

/// What the pill can ask the recording to do.
struct RecordingPillActions {
    var togglePause: @MainActor () -> Void
    var restart: @MainActor () -> Void
    var stop: @MainActor () -> Void
    var zoom: @MainActor () -> Void
    var togglePen: @MainActor () -> Void
    var badTake: @MainActor () -> Void
    /// From the hint "you are talking, and the microphone is off": start over with it on.
    var recordWithMicrophone: @MainActor () -> Void
    /// The hint's cross: go on as it is.
    var dismissMicrophoneHint: @MainActor () -> Void
}

/// The whole interface of a recording in progress: the dot, the time — against the length aimed
/// for, when there is one — how much the take weighs, pause, zoom, pen, "cut the last seconds",
/// restart and stop.
///
/// It lives in a borderless panel that never becomes active, so clicking it leaves the app being
/// recorded in front. The recording filter leaves every Pawshot window out, so the pill is never in
/// the video.
///
/// Two looks. On a screen with a camera notch it becomes part of the notch: a black band with the
/// dot on one side and the time on the other, dropping its buttons down when the cursor comes
/// near. Anywhere else it is a glass capsule by the recorded area that shrinks to a faint dot
/// after three seconds with the cursor away. Out of the way, never lost.
@MainActor
final class RecordingPillController {
    private static var logger: Logger {
        .pawshot("recording")
    }

    private let panel: NSPanel
    private let model = PillModel()
    private var proximityTimer: Timer?
    private var lastNearDate = Date()
    private var notchFrames: (collapsed: CGRect, expanded: CGRect)?

    /// Wide and tall enough for six buttons with their shortcuts written under them, the time
    /// against a goal and the size of the file.
    private static let size = CGSize(width: 540, height: 58)
    private static let nearDistance: CGFloat = 90
    private static let compactAfter: TimeInterval = 3
    private static let notchButtonsHeight: CGFloat = 56
    private static let notchExpandedWidth: CGFloat = 440

    init(actions: RecordingPillActions) {
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Above the menu bar, so the notch look can sit on it.
        panel.configureAsOverlay(level: .statusBar)
        let host = PillHostingView(rootView: RecordingPillView(model: model, actions: actions))
        host.onMouse = { [model] point in
            if model.hoverPoint != point {
                model.hoverPoint = point
            }
        }
        panel.contentView = host
    }

    /// Shows the pill — in the notch of `screen` when it has one, otherwise by the recorded area
    /// (`area` in AppKit screen coordinates).
    /// `stopShortcut` is the one that started the take — pressing it again stops it.
    func show(near area: CGRect, on screen: NSScreen, penAvailable: Bool, stopShortcut: HotKeyBinding?) {
        model.penAvailable = penAvailable
        model.stopShortcut = stopShortcut
        model.penIsOn = false
        model.isCompact = false
        model.isExpanded = false
        lastNearDate = Date()

        let collapsed = Self.notchFrame(on: screen, expanded: false)
        let expanded = Self.notchFrame(on: screen, expanded: true)
        if let collapsed, let expanded {
            notchFrames = (collapsed, expanded)
            model.style = .notch
            model.notchHeight = screen.safeAreaInsets.top
            panel.setFrame(collapsed, display: true)
        } else {
            notchFrames = nil
            model.style = .floating
            let origin = SelectionGeometry.pillOrigin(below: area, pillSize: Self.size, visibleFrame: screen.visibleFrame)
            panel.setFrame(CGRect(origin: origin, size: Self.size), display: true)
        }
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        let look = notchFrames == nil ? "floating" : "notch"
        Self.logger.notice("pill shown: \(look, privacy: .public)")

        proximityTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkProximity() }
        }
        RunLoop.main.add(timer, forMode: .common)
        proximityTimer = timer
    }

    /// The region moved (while paused): a floating pill follows it, a pill in the notch stays put.
    func follow(area: CGRect, on screen: NSScreen) {
        guard notchFrames == nil else { return }
        let origin = SelectionGeometry.pillOrigin(below: area, pillSize: Self.size, visibleFrame: screen.visibleFrame)
        panel.setFrame(CGRect(origin: origin, size: Self.size), display: true)
    }

    func hide() {
        proximityTimer?.invalidate()
        proximityTimer = nil
        model.hoverPoint = nil
        model.microphoneHint = false
        model.notice = nil
        panel.orderOut(nil)
    }

    func setPen(isOn: Bool) {
        model.penIsOn = isOn
    }

    /// How long the take is meant to be; 0 for no goal.
    func setGoal(_ goal: TimeInterval) {
        model.goal = goal
    }

    /// What the take weighs so far — or, `isWarning`, that the disk is running out.
    func setDetail(_ text: String?, isWarning: Bool) {
        if model.detail != text {
            model.detail = text
        }
        if model.detailIsWarning != isWarning {
            model.detailIsWarning = isWarning
        }
    }

    /// A word that something just happened — "Frame copied" — in place of the size for a moment.
    func flash(notice: String) {
        model.notice = notice
        Task { @MainActor [model] in
            try? await Task.sleep(for: .milliseconds(1600))
            if model.notice == notice {
                model.notice = nil
            }
        }
    }

    /// A word that stays for as long as a key is held — "Microphone muted" — and goes with `nil`.
    func hold(notice: String?) {
        model.notice = notice
    }

    /// "You are talking, and the microphone is off", with a button to start over with it on. It
    /// takes the pill over for ten seconds, or until it is answered.
    func showMicrophoneHint() {
        model.microphoneHint = true
        lastNearDate = Date()
        Self.logger.notice("pill: microphone hint shown")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.dismissMicrophoneHint(reason: "ten seconds passed")
        }
    }

    func dismissMicrophoneHint(reason: String) {
        guard model.microphoneHint else { return }
        model.microphoneHint = false
        Self.logger.notice("pill: microphone hint gone (\(reason, privacy: .public))")
    }

    /// The scissors light up for a moment: the last seconds are marked.
    func flashBadTake() {
        model.cutFlash = true
        Task { @MainActor [model] in
            try? await Task.sleep(for: .milliseconds(450))
            model.cutFlash = false
        }
    }

    /// The magnifier lights up for a moment: the zoom mark took.
    func flashZoom() {
        model.zoomFlash = true
        Task { @MainActor [model] in
            try? await Task.sleep(for: .milliseconds(450))
            model.zoomFlash = false
        }
    }

    private static func notchFrame(on screen: NSScreen, expanded: Bool) -> CGRect? {
        SelectionGeometry.notchPillFrame(
            screenFrame: screen.frame,
            leftAreaWidth: screen.auxiliaryTopLeftArea?.width,
            rightAreaWidth: screen.auxiliaryTopRightArea?.width,
            topInset: screen.safeAreaInsets.top,
            extraHeight: expanded ? notchButtonsHeight : 0,
            minimumWidth: expanded ? notchExpandedWidth : 0
        )
    }

    private func checkProximity() {
        let mouse = NSEvent.mouseLocation

        if let notchFrames {
            // The notch opens while the cursor is on it or on the buttons it dropped down.
            let reach = (model.isExpanded ? notchFrames.expanded : notchFrames.collapsed).insetBy(dx: -8, dy: -8)
            // The hint has to be seen: it opens the notch by itself.
            let expand = reach.contains(mouse) || model.microphoneHint
            guard expand != model.isExpanded else { return }
            model.isExpanded = expand
            panel.setFrame(expand ? notchFrames.expanded : notchFrames.collapsed, display: true)
            return
        }

        let reach = panel.frame.insetBy(dx: -Self.nearDistance, dy: -Self.nearDistance)
        // The hint keeps the pill from shrinking to a dot, as the cursor nearby does.
        if reach.contains(mouse) || model.microphoneHint {
            lastNearDate = Date()
        }
        let compact = Date().timeIntervalSince(lastNearDate) > Self.compactAfter
        guard compact != model.isCompact else { return }
        model.isCompact = compact
        // A shrunk pill is only a dot; the rest of the panel must not swallow clicks meant for
        // the app underneath.
        panel.ignoresMouseEvents = compact
    }
}

/// The pill's hosting view, telling where the mouse is over it.
///
/// The pill floats over whatever app is being recorded, so Pawshot is not the active app and the
/// panel is never key; a tracking area that is active always still hears the mouse there, which
/// is what the buttons' hover is made of — see `ChromeButtonStyle`.
final class PillHostingView: NSHostingView<RecordingPillView> {
    /// The mouse in SwiftUI's terms — from the top left of the view — or `nil` once it has left.
    var onMouse: ((CGPoint?) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        onMouse?(CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouse?(nil)
    }
}

@MainActor
@Observable
final class PillModel {
    enum Style {
        case floating
        case notch
    }

    var style = Style.floating
    var isCompact = false
    var isExpanded = false
    var notchHeight: CGFloat = 32
    var penAvailable = false
    var penIsOn = false
    var zoomFlash = false
    var cutFlash = false
    /// Seconds the take is meant to last; 0 for none.
    var goal: TimeInterval = 0
    /// The size of the file so far, or a warning about the disk.
    var detail: String?
    var detailIsWarning = false
    /// Said for a moment in place of `detail`.
    var notice: String?
    /// The take runs with the microphone off, and somebody is talking: the pill says so.
    var microphoneHint = false
    var stopShortcut: HotKeyBinding?
    /// Where the mouse is over the pill, from its top left; `nil` when it is elsewhere.
    var hoverPoint: CGPoint?
}

struct RecordingPillView: View {
    let model: PillModel
    let actions: RecordingPillActions
    private let state = AppState.shared
    private let settings = Settings.shared

    var body: some View {
        let status = state.recording ?? AppState.RecordingStatus(elapsed: 0, isPaused: false)

        Group {
            switch model.style {
            case .floating: floating(status)
            case .notch: notch(status)
            }
        }
        .animation(.easeOut(duration: Tokens.Motion.enter), value: model.isCompact)
        .animation(.easeOut(duration: Tokens.Motion.enter), value: model.isExpanded)
        .coordinateSpace(.named(ChromeButtonStyle.space))
        .environment(\.chromeHoverPoint, model.hoverPoint)
        .environment(\.colorScheme, .dark)
    }

    private func floating(_ status: AppState.RecordingStatus) -> some View {
        ZStack {
            if model.isCompact {
                dot(status, size: 12)
                    .opacity(0.4)
                    .transition(.opacity)
            } else {
                HStack(spacing: 8) {
                    dot(status, size: 10)
                    time(status)
                    if model.microphoneHint {
                        microphoneHint
                    } else {
                        detail
                        Divider().frame(height: 18)
                        buttons(status)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                .glassEffect(.regular, in: .capsule)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Black like the notch it grows out of, so the notch reads as wider rather than as something
    /// stuck under it.
    private func notch(_ status: AppState.RecordingStatus) -> some View {
        VStack(spacing: 0) {
            HStack {
                dot(status, size: 8)
                Spacer()
                time(status)
            }
            .padding(.horizontal, 16)
            .frame(height: model.notchHeight)

            if model.isExpanded {
                HStack(spacing: 8) {
                    if model.microphoneHint {
                        microphoneHint
                    } else {
                        detail
                        buttons(status)
                    }
                }
                .frame(height: 56)
                .transition(.opacity)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14))
    }

    private func dot(_ status: AppState.RecordingStatus, size: CGFloat) -> some View {
        Circle()
            .fill(status.isPaused ? Color.gray : Color.red)
            .frame(width: size, height: size)
            .shadow(color: status.isPaused ? .clear : .red.opacity(0.7), radius: 4)
    }

    /// The time — and, with a goal, the goal after it and a bar underneath that fills up and
    /// turns red for the last ten seconds and beyond. The take is never stopped by it.
    private func time(_ status: AppState.RecordingStatus) -> some View {
        let goal = RecordingBudget.goal(elapsed: status.elapsed, goal: model.goal)
        return VStack(spacing: 3) {
            HStack(spacing: 4) {
                Text(status.elapsedText)
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .frame(minWidth: 44, alignment: .trailing)
                if goal != nil {
                    Text(verbatim: "/ " + AppState.RecordingStatus(elapsed: model.goal, isPaused: false).elapsedText)
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let goal {
                Capsule()
                    .fill(.white.opacity(0.2))
                    .frame(height: 2.5)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(goal.isClose ? Color.red : Tokens.paw)
                                .frame(width: proxy.size.width * goal.fraction)
                        }
                    }
            }
        }
        .fixedSize()
    }

    /// In place of the buttons, once in a take: somebody is talking and the microphone is off.
    /// One button starts the take over with the microphone on; the cross leaves things as they are.
    private var microphoneHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.slash.fill")
                .foregroundStyle(.red)
            Text("You're talking, and the microphone is off")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .fixedSize()
            Button(action: { actions.recordWithMicrophone() }) {
                Text("Start over with it")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(ChromeButtonStyle(kind: .selected, insets: EdgeInsets(top: 5, leading: 9, bottom: 5, trailing: 9)))
            .help("Throws this take away and records again with the microphone on")
            Button(action: { actions.dismissMicrophoneHint() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(ChromeButtonStyle(insets: EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)))
            .help("Keep recording without the microphone")
        }
    }

    /// The size of the file, a warning that the disk is running out, or a word about what just
    /// happened. Nothing until the first part of the file is written.
    @ViewBuilder
    private var detail: some View {
        if let text = model.notice ?? model.detail {
            Text(text)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(model.notice == nil && model.detailIsWarning ? Color.red : Color.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    @ViewBuilder
    private func buttons(_ status: AppState.RecordingStatus) -> some View {
        pillButton(status.isPaused ? "play.fill" : "pause.fill", help: status.isPaused ? "Resume" : "Pause") {
            actions.togglePause()
        }
        pillButton(
            "plus.magnifyingglass",
            help: "Zoom in here at export",
            shortcut: settings.zoomMarkHotKey,
            isOn: model.zoomFlash
        ) {
            actions.zoom()
        }
        if model.penAvailable {
            pillButton(
                "pencil.tip",
                help: "Pen — draw on the screen, Esc to stop",
                shortcut: settings.penHotKey,
                isOn: model.penIsOn
            ) {
                actions.togglePen()
            }
        }
        pillButton(
            "scissors",
            help: "Cut the last 10 seconds — a bad take",
            shortcut: settings.badTakeHotKey,
            isOn: model.cutFlash
        ) {
            actions.badTake()
        }
        pillButton("arrow.counterclockwise", help: "Restart — the take is thrown away", shortcut: settings.restartHotKey) {
            actions.restart()
        }
        pillButton("stop.fill", help: "Stop", shortcut: model.stopShortcut, tint: .red) {
            actions.stop()
        }
    }

    /// An icon with its shortcut written small underneath: the keys are learned by looking, not
    /// by hovering for a tooltip. It lights up under the cursor and gives way under a press.
    private func pillButton(
        _ symbol: String,
        help: LocalizedStringResource,
        shortcut: HotKeyBinding? = nil,
        isOn: Bool = false,
        tint: Color = .primary,
        action: @escaping () -> Void
    ) -> some View {
        let help = String(localized: help)
        let label = shortcut.map { "\(help) (\($0.displayString))" } ?? help
        return Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isOn ? Tokens.paw : tint)
                    .frame(height: 20)
                Text(shortcut?.displayString ?? " ")
                    .font(.system(size: 9, weight: .medium).monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .frame(minWidth: 30, minHeight: 36)
            .animation(.easeOut(duration: 0.15), value: isOn)
        }
        .buttonStyle(ChromeButtonStyle(insets: EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4)))
        .help(label)
        .accessibilityLabel(label)
    }
}
