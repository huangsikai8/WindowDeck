import AppKit
import Carbon.HIToolbox

/// Registers global shortcuts and reports which ones the system let us have.
///
/// Carbon's `RegisterEventHotKey` is used rather than an event tap: it is the
/// only system-wide hotkey API needing no extra permission (a tap would require
/// Input Monitoring on top of Accessibility).
@MainActor
final class HotKeyManager {

    /// Fired on key-down, with whether Shift was held — the switcher uses that
    /// to cycle backwards.
    var onTrigger: ((ShortcutAction, Bool) -> Void)?

    /// Fired when the shortcut's *key* is let go, while its modifier may still
    /// be held.
    ///
    /// Carbon hotkeys do not auto-repeat — `RegisterEventHotKey` delivers one
    /// press however long the key is held down — so holding Tab to run down a
    /// long list did nothing at all. The switcher runs its own repeat, and this
    /// is what tells it to stop. It is a separate question from the *modifier*
    /// being released, which is what ends the session.
    var onRelease: ((ShortcutAction) -> Void)?

    /// Actions whose shortcut registered successfully. A failure almost always
    /// means macOS already owns the combination — ⌃1–⌃9 belong to "Switch to
    /// Desktop" whenever multiple Spaces exist — so it is surfaced in Settings
    /// rather than left as a dead key.
    private(set) var registeredActions: Set<ShortcutAction> = []

    private var hotKeys: [EventHotKeyRef?] = []
    private var actionsByID: [UInt32: ShortcutAction] = [:]
    private var handler: EventHandlerRef?
    private var isInstalled = false
    private var nextID: UInt32 = 1

    private let signature: OSType = 0x5744_636B // 'WDck'

    func register(_ shortcuts: [ShortcutAction: Shortcut]) {
        installHandlerIfNeeded()
        unregisterAll()

        for (action, shortcut) in shortcuts.sorted(by: { $0.key.storageKey < $1.key.storageKey }) {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: signature, id: nextID)

            let status = RegisterEventHotKey(
                UInt32(shortcut.keyCode),
                shortcut.carbonModifiers,
                id,
                GetApplicationEventTarget(),
                0,
                &ref
            )

            if status == noErr {
                hotKeys.append(ref)
                actionsByID[nextID] = action
                registeredActions.insert(action)
                nextID += 1
            }
        }
    }

    func unregisterAll() {
        for ref in hotKeys where ref != nil {
            UnregisterEventHotKey(ref!)
        }
        hotKeys.removeAll()
        actionsByID.removeAll()
        registeredActions.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard !isInstalled else { return }
        isInstalled = true

        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased))
        ]

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                var id = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &id
                )
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                let raw = id.id
                let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
                // Shift is read live rather than from the registration, so one
                // binding covers both directions of cycling.
                let reversed = NSEvent.modifierFlags.contains(.shift)
                Task { @MainActor in
                    guard let action = manager.actionsByID[raw] else { return }
                    if released {
                        manager.onRelease?(action)
                    } else {
                        manager.onTrigger?(action, reversed)
                    }
                }
                return noErr
            },
            2,
            &specs,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
    }
}
