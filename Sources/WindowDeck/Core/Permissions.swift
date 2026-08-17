import AppKit
import ApplicationServices
import IOKit.hid

/// Accessibility is the one permission WindowDeck *needs*. Without it there are
/// no window titles and no way to raise a specific window, so the app is inert.
///
/// Input Monitoring is optional and only powers trackpad gestures. It is kept
/// separate and off by default because it is the more invasive of the two: it
/// covers all keyboard and pointer input, not just window metadata.
enum Permissions {

    // MARK: - Input Monitoring

    /// Measured, not assumed: `NSEvent.addGlobalMonitorForEvents` happily returns
    /// a monitor for scroll and gesture events with only Accessibility granted,
    /// and then delivers nothing at all — not one event, not even a two-finger
    /// scroll. Observing those event types genuinely requires this permission.
    static var canMonitorInput: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Shows the system prompt. Like Accessibility, the answer arrives out of
    /// process, so a `false` means "not yet" rather than "denied".
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// Same shape as `pollUntilTrusted`: the grant happens out of process, so
    /// polling is the only way to notice the switch being flipped.
    static func pollUntilInputMonitoring(interval: TimeInterval = 1.0,
                                         onGranted: @escaping () -> Void) {
        guard !canMonitorInput else { onGranted(); return }
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            guard canMonitorInput else { return }
            timer.invalidate()
            onGranted()
        }
    }

    static func openInputMonitoringPane() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

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
