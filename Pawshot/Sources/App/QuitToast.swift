import AppKit
import SwiftUI

/// "Hold ⌘Q to Quit" — Chrome's toast, shown once ⌘Q has been held longer than a tap. The bar
/// fills while the keys stay down; when it is full, Pawshot quits. A glass capsule in the middle
/// of the screen, a little above centre, that never takes a click or the keyboard.
@MainActor
enum QuitToast {
    private static let model = QuitToastModel()
    private static var panel: NSPanel?

    static func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        model.progress = 0

        let screen = NSApp.keyWindow?.screen
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        if let frame = screen?.frame {
            let size = panel.frame.size
            panel.setFrameOrigin(CGPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.55 - size.height / 2))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    static func setProgress(_ progress: Double) {
        model.progress = min(max(progress, 0), 1)
    }

    /// The keys were let go before the bar filled: the toast melts away and nothing else happens.
    static func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
            }
        }
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]

        let host = NSHostingView(rootView: QuitToastView(model: model))
        host.frame.size = host.fittingSize
        panel.setContentSize(host.fittingSize)
        panel.contentView = host
        return panel
    }
}

@MainActor
@Observable
final class QuitToastModel {
    var progress: Double = 0
}

private struct QuitToastView: View {
    let model: QuitToastModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Text("Hold", comment: "The quit toast, before the ⌘Q key caps: Hold ⌘Q to Quit")
                KeyCaps(caps: ["⌘", "Q"])
                Text("to Quit", comment: "The quit toast, after the ⌘Q key caps: Hold ⌘Q to Quit")
            }
            .font(.title3.weight(.semibold))

            ProgressView(value: model.progress)
                .progressViewStyle(.linear)
                .tint(Tokens.paw)
                .frame(width: 180)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 16)
        .glassEffect(.regular, in: .capsule)
        .padding(12)
    }
}
