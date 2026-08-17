import AppKit

/// One slot in the strip: either a single window, or a cluster standing in for
/// several.
enum DeckItem: Identifiable {
    case window(WindowInfo)
    case cluster(WindowCluster, [WindowInfo])
    /// The focused window when it isn't a member of the group on show — drawn
    /// faded after a separator, so the strip can still say what you're in.
    case ghost(WindowInfo)
    /// A window belonging to no group at all. Shown in All, after a separator,
    /// so it is obvious at a glance what still needs filing.
    case ungrouped(WindowInfo)
    /// A pinned launcher. An ordinary item in the row rather than a section of
    /// its own — which is also what makes it shrink alongside everything else
    /// instead of holding a fixed width while windows compress around it.
    case pinned(PinnedApp)

    var id: String {
        switch self {
        case .window(let window): "w\(window.id)"
        case .cluster(let cluster, _): "c\(cluster.id.uuidString)"
        case .ghost(let window): "g\(window.id)"
        case .ungrouped(let window): "u\(window.id)"
        case .pinned(let app): "p\(app.bundleID)"
        }
    }

    /// Stable key used by the group's manual arrangement. Windows and pins share
    /// one ordering, so both need a key in the same namespace.
    var orderKey: String {
        switch self {
        case .window(let window), .ghost(let window), .ungrouped(let window): "w\(window.id)"
        case .cluster(_, let members): members.first.map { "w\($0.id)" } ?? id
        case .pinned(let app): "p\(app.bundleID)"
        }
    }

    var isPinned: Bool {
        if case .pinned = self { return true }
        return false
    }

    var isCluster: Bool {
        if case .cluster = self { return true }
        return false
    }

    var isGhost: Bool {
        if case .ghost = self { return true }
        return false
    }

    var isUngrouped: Bool {
        if case .ungrouped = self { return true }
        return false
    }

    /// Windows this item stands for — one for a plain entry, several for a
    /// cluster.
    var windows: [WindowInfo] {
        switch self {
        case .window(let window): [window]
        case .cluster(_, let members): members
        case .ghost(let window): [window]
        case .ungrouped(let window): [window]
        case .pinned: []
        }
    }

    /// The window a drop should target when combining.
    var primaryWindowID: CGWindowID? {
        windows.first?.id
    }
}
