import AppKit

// Deliberately not named main.swift: top-level code is nonisolated, and every
// AppKit call here needs the main actor.
@main
struct WindowDeckApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // .accessory keeps WindowDeck out of the Dock and out of Cmd-Tab, which
        // matters when the app itself is standing in for the Dock.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
