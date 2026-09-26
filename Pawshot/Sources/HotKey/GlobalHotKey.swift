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
    private static let logger = Logger(subsystem: "com.caramelheaven.pawshot", category: "hotkey")

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

    /// Registers a global hotkey, or explains why it couldn't.
    static func register(
        _ binding: HotKeyBinding,
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

        guard status == noErr, let ref else {
            // Most of the time this happens because the shortcut is already taken. Staying silent
            // is not an option: from the outside it just looks like "the hotkey doesn't work".
            logger.error("RegisterEventHotKey failed with status \(status)")
            throw status == OSStatus(eventHotKeyExistsErr)
                ? RegistrationError.alreadyTaken
                : RegistrationError.failed(status)
        }

        let hotKey = GlobalHotKey(id: id, ref: ref, action: action)
        registry[id] = WeakHotKey(value: hotKey)
        // `.public`: this line is how the owner checks that a hotkey took — by default the logger
        // redacts interpolated strings and prints `<private>` instead.
        logger.info("hotkey registered: \(binding.displayString, privacy: .public)")

        return hotKey
    }

    private init(id: UInt32, ref: EventHotKeyRef, action: @escaping () -> Void) {
        self.id = id
        hotKeyRef = ref
        self.action = action
    }

    /// `isolated deinit` — otherwise a plain deinit can touch neither `hotKeyRef`
    /// (a non-Sendable OpaquePointer) nor the shared registry under the main actor.
    isolated deinit {
        Self.registry[id] = nil
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
    }

    private static func installSharedHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
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
                    return OSStatus(eventNotHandledErr)
                }

                // Carbon delivers hotkeys on the main thread, so the isolation here is real and
                // not just a promise made to the compiler.
                MainActor.assumeIsolated {
                    GlobalHotKey.registry[hotKeyID.id]?.value?.action()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )
    }
}
