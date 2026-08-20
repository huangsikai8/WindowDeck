import AppKit
import ApplicationServices

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
    /// Launches the app, or asks an already-running one to show itself.
    ///
    /// Deliberately *not* `NSRunningApplication.activate()` for the running case.
    /// Activating only brings an app forward, and an app whose last window was
    /// closed with the red button has nothing to bring forward — so clicking its
    /// launcher appeared to do nothing at all, and the window only turned up if
    /// the app got round to it by itself.
    ///
    /// `openApplication` delivers the same reopen event the Dock sends when you
    /// click a running app's icon, which is what makes it create a window again.
    /// It launches the app when it isn't running, so one path covers both.
    static func open(_ app: PinnedApp) {
        open(url: app.url)
    }

    /// Reopens one specific copy of an application.
    ///
    /// Two installations share a bundle id, so `urlForApplication(withBundleIdentifier:)`
    /// cannot tell them apart and answers with whichever LaunchServices prefers —
    /// clicking the launcher for `/Applications/Slack 2.app` would reopen
    /// `/Applications/Slack.app`. The process's own `bundleURL` is the only thing
    /// that names the right one.
    static func open(url: URL?) {
        guard let url else { NSSound.beep(); return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { running, _ in
            guard let running else { return }
            // `configuration.activates` is not enough on its own. The request
            // comes from a background agent, so cooperative activation can
            // refuse it — and at the instant the app is launched or sent its
            // reopen event there is no window yet to bring forward anyway. The
            // result is an app that starts up behind whatever you were looking
            // at. Following up once the window has had a moment to appear is
            // what puts it in front.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                // Same reasoning as `WindowEngine.bringForward`: unhiding is a
                // separate verb, and Accessibility is what actually brings an app
                // forward from a background agent — `activate()` is a request
                // cooperative activation refuses.
                if running.isHidden { running.unhide() }
                AX.setBool(AXUIElementCreateApplication(running.processIdentifier),
                           kAXFrontmostAttribute, true)
                running.activate()
            }
        }
    }
}

extension NSImage {
    /// A 16pt copy for use in a menu. An application icon is 32pt or larger, and
    /// SwiftUI draws it at its natural size — which made every row in the "Group
    /// with" menu twice as tall as it needed to be.
    var menuSized: NSImage {
        let size = NSSize(width: 16, height: 16)
        let copy = NSImage(size: size)
        copy.lockFocus()
        draw(in: NSRect(origin: .zero, size: size))
        copy.unlockFocus()
        return copy
    }
}

extension String {
    /// Middle-truncates, so both the start and the distinguishing tail survive.
    func truncated(to limit: Int) -> String {
        guard count > limit else { return self }
        let head = prefix(limit / 2)
        let tail = suffix(limit / 2 - 2)
        return "\(head)…\(tail)"
    }
}
