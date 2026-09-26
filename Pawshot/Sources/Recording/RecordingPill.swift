import AppKit
import SwiftUI

/// What the pill can ask the recording to do.
struct RecordingPillActions {
    var togglePause: @MainActor () -> Void
    var restart: @MainActor () -> Void
    var stop: @MainActor () -> Void
    var zoom: @MainActor () -> Void
    var togglePen: @MainActor () -> Void
}

/// The whole interface of a recording in progress: the dot, the time, pause, zoom, pen, restart
/// and stop.
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
    private let panel: NSPanel
    private let model = PillModel()
    private var proximityTimer: Timer?
    private var lastNearDate = Date()
    private var notchFrames: (collapsed: CGRect, expanded: CGRect)?

    /// Wide and tall enough for five buttons with their shortcuts written under them.
    private static let size = CGSize(width: 380, height: 58)
    private static let nearDistance: CGFloat = 90
    private static let compactAfter: TimeInterval = 3
    private static let notchButtonsHeight: CGFloat = 56
    private static let notchExpandedWidth: CGFloat = 360

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
        panel.contentView = NSHostingView(rootView: RecordingPillView(model: model, actions: actions))
    }

    /// Shows the pill — in the notch of `screen` when it has one, otherwise by the recorded area
    /// (`area` in AppKit screen coordinates).
    /// `stopShortcut` is the one that started the take — pressing it again stops it.
    func show(near area: CGRect, on screen: NSScreen, penAvailable: Bool, stopShortcut: HotKeyBinding) {
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

        proximityTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkProximity() }
        }
        RunLoop.main.add(timer, forMode: .common)
        proximityTimer = timer
    }

    func hide() {
        proximityTimer?.invalidate()
        proximityTimer = nil
        panel.orderOut(nil)
    }

    func setPen(isOn: Bool) {
        model.penIsOn = isOn
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
            let expand = reach.contains(mouse)
            guard expand != model.isExpanded else { return }
            model.isExpanded = expand
            panel.setFrame(expand ? notchFrames.expanded : notchFrames.collapsed, display: true)
            return
        }

        let reach = panel.frame.insetBy(dx: -Self.nearDistance, dy: -Self.nearDistance)
        if reach.contains(mouse) {
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
    var stopShortcut: HotKeyBinding?
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
        .environment(\.colorScheme, .dark)
    }

    private func floating(_ status: AppState.RecordingStatus) -> some View {
        ZStack {
            if model.isCompact {
                dot(status, size: 12)
                    .opacity(0.4)
                    .transition(.opacity)
            } else {
                HStack(spacing: 12) {
                    dot(status, size: 10)
                    time(status)
                    Divider().frame(height: 18)
                    buttons(status)
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
                HStack(spacing: 12) {
                    buttons(status)
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

    private func time(_ status: AppState.RecordingStatus) -> some View {
        Text(status.elapsedText)
            .font(.system(size: 14, weight: .semibold).monospacedDigit())
            .frame(minWidth: 44, alignment: .trailing)
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
        pillButton("arrow.counterclockwise", help: "Restart — the take is thrown away", shortcut: settings.restartHotKey) {
            actions.restart()
        }
        pillButton("stop.fill", help: "Stop", shortcut: model.stopShortcut) {
            actions.stop()
        }
    }

    /// An icon with its shortcut written small underneath: the keys are learned by looking, not
    /// by hovering for a tooltip.
    private func pillButton(
        _ symbol: String,
        help: String,
        shortcut: HotKeyBinding? = nil,
        isOn: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let label = shortcut.map { "\(help) (\($0.displayString))" } ?? help
        return Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isOn ? Tokens.paw : Color.primary)
                    .frame(height: 20)
                Text(shortcut?.displayString ?? " ")
                    .font(.system(size: 9, weight: .medium).monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .frame(minWidth: 30, minHeight: 36)
            .contentShape(.rect)
            .animation(.easeOut(duration: 0.15), value: isOn)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
