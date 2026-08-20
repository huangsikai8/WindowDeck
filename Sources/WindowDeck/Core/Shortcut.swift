import AppKit
import Carbon.HIToolbox

/// Something a shortcut can trigger.
///
/// Two actions, and both of them cycle windows. The group shortcuts — step to
/// the next group, jump to group N — went with group switching itself: every
/// group is on screen at once now, so there is nothing to switch to. Their
/// storage keys are simply no longer recognised, which is how they drop out of
/// an existing state file without any migration.
enum ShortcutAction: Hashable, Codable {
    /// Cycle windows within the capsule you are working in.
    case cycleGroupWindows
    /// Cycle windows of the frontmost app, within that capsule.
    case cycleAppWindows
    /// Cycle the things the strip draws, across every capsule — ⌥Tab.
    case cycleEntries

    var storageKey: String {
        switch self {
        case .cycleGroupWindows: "cycleGroupWindows"
        case .cycleAppWindows: "cycleAppWindows"
        case .cycleEntries: "cycleEntries"
        }
    }

    static func from(storageKey: String) -> ShortcutAction? {
        switch storageKey {
        case "cycleGroupWindows": .cycleGroupWindows
        case "cycleAppWindows": .cycleAppWindows
        case "cycleEntries": .cycleEntries
        default: nil
        }
    }

    var label: String {
        switch self {
        case .cycleGroupWindows: "Cycle windows in group"
        case .cycleAppWindows: "Cycle windows of current app"
        case .cycleEntries: "Switch between everything on the strip"
        }
    }
}

/// A key plus its modifiers, stored in Carbon's terms because that is what
/// `RegisterEventHotKey` consumes.
struct Shortcut: Codable, Equatable, Hashable {
    var keyCode: UInt16
    /// Carbon modifier mask (`controlKey`, `optionKey`, `cmdKey`, `shiftKey`).
    var carbonModifiers: UInt32

    init(keyCode: UInt16, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let carbon = Shortcut.carbonMask(from: flags)
        // A shortcut with no modifier would swallow that key everywhere on the
        // system — press it once and you could never type that character again.
        guard carbon != 0 else { return nil }
        self.keyCode = event.keyCode
        self.carbonModifiers = carbon
    }

    static func carbonMask(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }

    /// The modifier flags this shortcut is held with, used to notice the release
    /// that commits a switcher cycle.
    var triggerFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        // Shift is deliberately excluded: it is the reverse-direction key while
        // cycling, so its release must not commit.
        return flags
    }

    var displayString: String {
        var text = ""
        if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Shortcut.keyName(for: keyCode)
    }

    static func keyName(for keyCode: UInt16) -> String {
        if let named = specialKeyNames[Int(keyCode)] { return named }

        // Ask the current keyboard layout what this key produces, so a shortcut
        // reads correctly on non-US layouts.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "Key \(keyCode)" }

        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)

        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return OSStatus(-1)
            }
            return UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, characters.count, &length, &characters
            )
        }

        guard status == noErr, length > 0 else { return "Key \(keyCode)" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Tab: "⇥", kVK_Return: "↩", kVK_Escape: "⎋",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_ANSI_Grave: "`",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12"
    ]

    /// ⌃` — the default for cycling windows in a group.
    static let defaultGroupCycle = Shortcut(
        keyCode: UInt16(kVK_ANSI_Grave),
        carbonModifiers: UInt32(controlKey)
    )

    /// ⌥Tab — moving between the things on the strip.
    ///
    /// Deliberately the neighbour of ⌘Tab, because it is the same gesture aimed
    /// at a different list: macOS switches applications, this switches what the
    /// bar draws. ⌘Tab and ⌘⇧Tab belong to the system and cannot be taken; ⌥Tab
    /// is free, and Settings will accept anything else if it collides with
    /// something you use.
    static let defaultEntryCycle = Shortcut(
        keyCode: UInt16(kVK_Tab),
        carbonModifiers: UInt32(optionKey)
    )
}
