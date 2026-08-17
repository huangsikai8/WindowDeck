import AppKit
import SwiftUI

/// Hosts the settings window. Kept alive across closes so reopening is instant
/// and the selected tab is preserved.
@MainActor
final class SettingsWindowController {

    private let store: AppStore
    private var window: NSWindow?

    init(store: AppStore) {
        self.store = store
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "WindowDeck Settings"
            window.contentView = NSHostingView(rootView: SettingsView(store: store))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }

        // The deck panel is non-activating and the app is an accessory, so
        // nothing here can take keyboard focus unless we activate explicitly.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
