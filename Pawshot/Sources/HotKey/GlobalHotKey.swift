import AppKit
import Carbon.HIToolbox
import os

/// A global hotkey on top of the Carbon Event Manager.
///
/// Why Carbon and not something newer: `RegisterEventHotKey` is the only way to catch a shortcut
/// while the app is inactive without asking the user for a permission. The alternatives
/// (`NSEvent.addGlobalMonitorForEvents`, `CGEvent.tapCreate`) require Accessibility / Input
/// Monitoring and on top of that don't swallow the event — it reaches the active app as well.
@MainActor
final class GlobalHotKey {
    /// The four-letter tag Carbon uses to tell our hotkeys apart from everyone else's.
    private static let signature = OSType(0x5041_5753) // 'PAWS'
    private static var logger: Logger {
        .pawshot("hotkey")
    }

    /// Every live hotkey by its id — a C callback can't capture context, so the path from an
    /// event to an object goes through this table.
    ///
    /// Weak on purpose. Whoever registered a hotkey owns it, and dropping it is how a combination is
    /// given back: `deinit` unregisters it. A strong table kept every hotkey alive forever, so
    /// nothing was ever unregistered — a replaced shortcut kept firing, and every recording after
    /// the first got -9878 for its own shortcuts. `GlobalHotKeyTests` pins it.
    private static var registry: [UInt32: WeakHotKey] = [:]

    private struct WeakHotKey {
        weak var value: GlobalHotKey?
    }

    private static var nextID: UInt32 = 1
    private static var eventHandler: EventHandlerRef?

    /// Why a registration didn't take.
    ///
    /// The distinction matters for the settings window: "taken" is something the user can fix by
    /// picking another combination or freeing this one, anything else is our problem to log.
    enum RegistrationError: Error {
        /// The combination already belongs to the system or to another app.
        case alreadyTaken
        case failed(OSStatus)
    }

    private let id: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private let action: () -> Void
    /// Told when the keys are let go — for the one shortcut that means something held: the zoom.
    private let onRelease: (() -> Void)?

    /// Registers a global hotkey, or explains why it couldn't.
    ///
    /// `name` — the action, English, for the log: "⇧⌘2 (capture a region)" tells a dead key apart
    /// from one that fired into the wrong action.
    static func register(
        _ binding: HotKeyBinding,
        name: String? = nil,
        onRelease: (() -> Void)? = nil,
        action: @escaping () -> Void
    ) throws -> GlobalHotKey {
        installSharedHandlerIfNeeded()

        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.carbonModifiers,
            EventHotKeyID(signature: signature, id: id),
            GetApplicationEventTarget(),
            0,
            &ref
        )

        let shortcut = name.map { "\(binding.logString) (\($0))" } ?? binding.logString
        guard status == noErr, let ref else {
            // Most of the time this happens because the shortcut is already taken. Staying silent
            // is not an option: from the outside it just looks like "the hotkey doesn't work".
            logger.error("RegisterEventHotKey failed for \(shortcut, privacy: .public) with status \(status)")
            throw status == OSStatus(eventHotKeyExistsErr)
                ? RegistrationError.alreadyTaken
                : RegistrationError.failed(status)
        }

        let hotKey = GlobalHotKey(id: id, ref: ref, label: shortcut, action: action, onRelease: onRelease)
        registry[id] = WeakHotKey(value: hotKey)
        // `.public`: this line is how the owner checks that a hotkey took — by default the logger
        // redacts interpolated strings and prints `<private>` instead.
        logger.notice("hotkey registered: \(shortcut, privacy: .public), id \(id, privacy: .public)")

        return hotKey
    }

    /// What every caller wants: the hotkey for one action, or `nil` — with the reason in the log.
    /// A shortcut cleared with the field's × comes in as `nil` and registers nothing. A failure
    /// is only logged: the settings window is where the user learns about it.
    static func register(
        _ binding: HotKeyBinding?,
        for name: String,
        onRelease: (() -> Void)? = nil,
        action: @escaping () -> Void
    ) -> GlobalHotKey? {
        guard let binding else {
            logger.notice("\(name, privacy: .public): no shortcut, nothing registered")
            return nil
        }
        do {
            return try register(binding, name: name, onRelease: onRelease, action: action)
        } catch {
            // `register` has already logged the Carbon status; this names what is now dead.
            logger.error("\(name, privacy: .public): \(binding.logString, privacy: .public) not registered: \(String(describing: error), privacy: .public) — this action has no shortcut until it is changed")
            return nil
        }
    }

    /// The combination, for the log.
    private let label: String

    private init(
        id: UInt32,
        ref: EventHotKeyRef,
        label: String,
        action: @escaping () -> Void,
        onRelease: (() -> Void)?
    ) {
        self.id = id
        hotKeyRef = ref
        self.label = label
        self.action = action
        self.onRelease = onRelease
    }

    /// `isolated deinit` — otherwise a plain deinit can touch neither `hotKeyRef`
    /// (a non-Sendable OpaquePointer) nor the shared registry under the main actor.
    isolated deinit {
        Self.registry[id] = nil
        if let hotKeyRef {
            let status = UnregisterEventHotKey(hotKeyRef)
            let shortcut = label
            Self.logger.notice("hotkey unregistered: \(shortcut, privacy: .public), status \(status)")
        }
    }

    private static func installSharedHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        // The release too: a hotkey with `onRelease` is one that can be held.
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == GlobalHotKey.signature else {
                    // Not ours (or unreadable): some other hotkey in this process. Logged, since
                    // "the key did nothing" is exactly what these lines are for.
                    let signature = hotKeyID.signature
                    MainActor.assumeIsolated {
                        GlobalHotKey.logger.notice("hotkey event not ours: status \(status, privacy: .public), signature \(signature, privacy: .public)")
                    }
                    return OSStatus(eventNotHandledErr)
                }

                let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
                // Carbon delivers hotkeys on the main thread, so the isolation here is real and
                // not just a promise made to the compiler.
                MainActor.assumeIsolated {
                    if released {
                        // Most hotkeys only care about the press; their release says nothing.
                        if let hotKey = GlobalHotKey.registry[hotKeyID.id]?.value, let onRelease = hotKey.onRelease {
                            let shortcut = hotKey.label
                            GlobalHotKey.logger.notice("hotkey let go: \(shortcut, privacy: .public)")
                            onRelease()
                        }
                        return
                    }
                    guard let hotKey = GlobalHotKey.registry[hotKeyID.id]?.value else {
                        // Pressed, but whoever registered it is gone: from the outside, a dead key.
                        GlobalHotKey.logger.error("hotkey \(hotKeyID.id) pressed with nobody behind it")
                        return
                    }
                    let shortcut = hotKey.label
                    let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                    GlobalHotKey.logger.notice("hotkey fired: \(shortcut, privacy: .public), \(frontmost, privacy: .public) in front")
                    hotKey.action()
                }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            nil,
            &eventHandler
        )
        logger.notice("hotkey event handler installed, status \(status)")
    }
}
