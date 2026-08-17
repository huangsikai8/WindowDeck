import AppKit
import SwiftUI

/// Hosts the settings window. Kept alive across closes so reopening is instant
/// and the selected tab is preserved.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private let store: AppStore
    private var window: NSWindow?

    init(store: AppStore) {
        self.store = store
        super.init()
    }

    /// Back to an accessory the moment the window closes, so WindowDeck doesn't
    /// keep a Dock icon and a menu bar it has no use for.
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            // Deferred, and conditional. `windowWillClose` fires *before* the
            // window goes away, so counting immediately still sees it; and a
            // rename prompt may be open behind Settings, which would be dropped
            // back behind other apps if the policy stepped down while it was up.
            try? await Task.sleep(nanoseconds: 100_000_000)
            let stillOpen = NSApp.windows.contains {
                $0.isVisible && !($0 is DeckPanel) && $0.className != "NSStatusBarWindow"
            }
            if !stillOpen { NSApp.setActivationPolicy(.accessory) }
        }
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 620),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "WindowDeck Settings"
            window.contentView = NSHostingView(rootView: SettingsView(store: store))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }

        // The deck panel is non-activating and the app is an accessory, so
        // nothing here can take keyboard focus unless we activate explicitly.
        //
        // Deferred by a runloop turn because this is usually reached from an
        // NSMenu item, and a menu runs its own tracking loop: activating while
        // that loop is still unwinding gets swallowed, which is why "Edit
        // Groups…" appeared to do nothing until you clicked it a second time.
        // A default-mode async cannot run until tracking has finished, which is
        // exactly the wait needed.
        // Becoming a regular app first is the part that actually works.
        // WindowDeck runs as an accessory (LSUIElement), and macOS will not hand
        // an accessory app activation on request — `NSApp.activate()` quietly
        // does nothing, which is why this needed a second click. Switching the
        // policy for as long as a window is open makes it an ordinary app that
        // can come forward; `windowWillClose` puts it back so no Dock icon or
        // menu bar lingers.
        NSApp.setActivationPolicy(.regular)

        DispatchQueue.main.async { [weak self] in
            // `ignoringOtherApps` is the load-bearing part, and it is deprecated
            // rather than optional here. Measured: plain `NSApp.activate()` left
            // `isActive == false` on every attempt, so the window was ordered
            // front *within* WindowDeck and stayed behind whatever app was
            // actually frontmost — it looked like the click did nothing.
            //
            // The cause is the strip: it is a `.nonactivatingPanel` by design, so
            // clicking it never makes WindowDeck frontmost, and macOS does not
            // grant activation to an app that is not already in front. Asking
            // politely can therefore never work from here.
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.makeKeyAndOrderFront(nil)
            // Belt and braces: if activation is refused anyway, at least put the
            // window above other applications rather than silently behind them.
            self?.window?.orderFrontRegardless()
        }
    }
}
