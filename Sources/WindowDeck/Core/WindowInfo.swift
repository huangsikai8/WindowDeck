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
    /// Where the window sits. macOS tabs of one window share an identical frame,
    /// which is the only signal tying them together — each tab is a separate
    /// `NSWindow` with its own id, and only the front one is ever on screen.
    let frame: CGRect?
    let element: AXUIElement

    /// What the strip shows when a window has no title of its own.
    var displayTitle: String {
        title.isEmpty ? appName : title
    }

    var icon: NSImage? {
        IconCache.icon(pid: pid)
    }

    /// The 16pt copy the "Group with" menu draws. Separate from `icon` because
    /// `menuSized` rasterises a *fresh* bitmap on every access, and the menu
    /// model is rebuilt for every tile on every redraw — see `IconCache`.
    var menuIcon: NSImage? {
        IconCache.menuIcon(pid: pid)
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
///
/// The 16pt menu copy is memoised too, and that one is not a micro-optimisation.
/// `NSImage.menuSized` locks focus on a new bitmap and redraws the icon through
/// IconServices on *every* access, measured at 0.036ms. `groupWithTargets` asks
/// for one per candidate window and is evaluated once per tile per redraw, so
/// the cost is N-squared in the window count: 33 windows meant ~900 fresh
/// rasterisations, 32ms, per strip redraw. A stack profile put that single
/// expression at 46% of the app's entire idle CPU. Caching `icon` alone does not
/// help — the rasterisation happens on the layer above it.
enum IconCache {
    private static var cache: [pid_t: NSImage] = [:]
    private static var menuCache: [pid_t: NSImage] = [:]

    static func icon(pid: pid_t) -> NSImage? {
        if let hit = cache[pid] { return hit }
        guard let image = NSRunningApplication(processIdentifier: pid)?.icon else { return nil }
        cache[pid] = image
        return image
    }

    static func menuIcon(pid: pid_t) -> NSImage? {
        if let hit = menuCache[pid] { return hit }
        guard let image = icon(pid: pid) else { return nil }
        let scaled = image.menuSized
        menuCache[pid] = scaled
        return scaled
    }

    /// Both caches, since a pid going away invalidates the menu copy too.
    static func forget(pid: pid_t) {
        cache.removeValue(forKey: pid)
        menuCache.removeValue(forKey: pid)
    }
}


extension WindowInfo {
    /// Only for the self-test. A real `WindowInfo` carries an `AXUIElement`,
    /// which cannot be conjured; a null element is fine because the harness never
    /// touches Accessibility.
    /// - Parameter pid: defaults to 0, which is fine for anything keyed on
    ///   window id or bundle id — but **app-scoped cycling filters on `pid`**, so
    ///   a fixture that leaves every window at 0 makes every window the same
    ///   application and any test of that scoping vacuous. Set it whenever the
    ///   thing under test distinguishes applications.
    static func testInstance(id: CGWindowID, bundleID: String, title: String,
                             frame: CGRect? = nil, pid: pid_t = 0) -> WindowInfo {
        WindowInfo(
            id: id,
            pid: pid,
            bundleID: bundleID,
            appName: bundleID,
            title: title,
            isMinimized: false,
            frame: frame,
            element: AXUIElementCreateApplication(0)
        )
    }
}
