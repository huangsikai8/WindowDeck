import AppKit

// Deliberately not named main.swift: top-level code is nonisolated, and every
// AppKit call here needs the main actor.
@main
struct WindowDeckApp {
    @MainActor
    static func main() {
        // Before anything else: a crash during start-up is exactly the kind
        // that leaves nothing behind to ask, and the handlers are not armed
        // until this returns.
        Trace.minimumLevel = ProcessInfo.processInfo.environment["WINDOWDECK_TRACE"] == "1" ? .debug : .info
        Trace.start()

        let app = NSApplication.shared
        if SelfTest.isRequested { SelfTest.run() }

        let delegate = AppDelegate()
        app.delegate = delegate
        // .accessory keeps WindowDeck out of the Dock and out of Cmd-Tab, which
        // matters when the app itself is standing in for the Dock.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
