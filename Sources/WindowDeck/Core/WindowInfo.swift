import AppKit
import ApplicationServices

/// One open window — the unit everything in WindowDeck is built from.
///
/// `id` is the window server's `CGWindowID`. It is unique while the window
/// lives, which is what group membership keys on. It is *not* stable across
/// relaunches, which is why membership is session-scoped.
struct WindowInfo: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let bundleID: String?
    let appName: String
    var title: String
    var isMinimized: Bool
    let element: AXUIElement

    /// What the strip shows when a window has no title of its own.
    var displayTitle: String {
        title.isEmpty ? appName : title
    }

    var icon: NSImage? {
        IconCache.icon(pid: pid)
    }
}

extension WindowInfo: Hashable {
    // Identity is the window ID; title and minimized state participate in
    // equality so SwiftUI redraws when either changes.
    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.isMinimized == rhs.isMinimized
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// App icons are fetched per window row every redraw; NSRunningApplication
/// lookups are cheap but not free, so results are memoised per process.
enum IconCache {
    private static var cache: [pid_t: NSImage] = [:]

    static func icon(pid: pid_t) -> NSImage? {
        if let hit = cache[pid] { return hit }
        guard let image = NSRunningApplication(processIdentifier: pid)?.icon else { return nil }
        cache[pid] = image
        return image
    }

    static func forget(pid: pid_t) {
        cache.removeValue(forKey: pid)
    }
}
