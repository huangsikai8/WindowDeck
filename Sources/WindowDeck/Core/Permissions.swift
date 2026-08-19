import AppKit
import ApplicationServices

/// Accessibility is the one permission WindowDeck *needs*. Without it there are
/// no window titles and no way to raise a specific window, so the app is inert.
///
/// Screen Recording is optional and powers hover thumbnails and the switcher's
/// previews only. Input Monitoring is no longer asked for at all: it existed for
/// the trackpad gestures that switched groups, and there are no groups to switch
/// between now.
enum Permissions {

    // MARK: - Accessibility

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the system prompt. Returns the trust state as of right now —
    /// granting happens out of process, so a `false` here just means "not yet".
    @discardableResult
    static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openSettingsPane() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// macOS only re-reads trust when the process restarts, so polling is how we
    /// notice the user flipping the switch. Calls `onGranted` once, on the main
    /// actor, then stops.
    static func pollUntilTrusted(interval: TimeInterval = 1.0, onGranted: @escaping () -> Void) {
        guard !isTrusted else { onGranted(); return }
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            guard isTrusted else { return }
            timer.invalidate()
            onGranted()
        }
    }
}
