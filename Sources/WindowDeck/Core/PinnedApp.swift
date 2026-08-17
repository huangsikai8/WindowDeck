import AppKit

/// A launcher in the "All" group. Unlike window entries these are static — they
/// exist whether or not the app is running, which is the one piece of ordinary
/// Dock behaviour WindowDeck keeps.
struct PinnedApp: Identifiable, Hashable, Codable {
    let bundleID: String
    var name: String

    var id: String { bundleID }

    var url: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    var icon: NSImage? {
        AppIconCache.icon(bundleID: bundleID)
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    init?(url: URL) {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        self.bundleID = id
        self.name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

enum AppIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(bundleID: String) -> NSImage? {
        if let hit = cache[bundleID] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = image
        return image
    }
}

enum AppLauncher {
    /// Activates the app if it's already running, launches it otherwise.
    static func open(_ app: PinnedApp) {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first {
            running.activate()
            return
        }
        guard let url = app.url else { NSSound.beep(); return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
