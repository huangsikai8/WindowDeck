import AppKit
import SwiftUI

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
    /// A group member whose window was closed with the red button while the
    /// application kept running.
    ///
    /// `placeholderFor` is the id of the window that was closed. Membership
    /// outlives the window — `memberIDs` keeps closed ids — so this holds the
    /// exact slot the window had and carries the same group dots. Closing a
    /// window does not change which group it belongs to, so this is deliberately
    /// *not* a separate class of thing in the row: same icon, same place, same
    /// dot, exactly as the Dock behaves. Nil when the app was never in a group,
    /// which only happens in All.
    case running(PinnedApp, placeholderFor: CGWindowID?)

    var id: String {
        switch self {
        case .window(let window): "w\(window.id)"
        case .cluster(let cluster, _): "c\(cluster.id.uuidString)"
        case .ghost(let window): "g\(window.id)"
        case .ungrouped(let window): "u\(window.id)"
        case .pinned(let app): "p\(app.bundleID)"
        case .running(let app, _): "r\(app.bundleID)"
        }
    }

    /// Stable key used by the group's manual arrangement. Windows and pins share
    /// one ordering, so both need a key in the same namespace.
    var orderKey: String {
        switch self {
        case .window(let window), .ghost(let window), .ungrouped(let window): "w\(window.id)"
        case .cluster(_, let members): members.first.map { "w\($0.id)" } ?? id
        case .pinned(let app): "p\(app.bundleID)"
        // The closed window's own key, so the slot keeps the position it held in
        // the manual arrangement instead of jumping when the window closes.
        case .running(let app, let windowID):
            windowID.map { "w\($0)" } ?? "p\(app.bundleID)"
        }
    }

    var isPinned: Bool {
        switch self {
        case .pinned, .running: true
        default: false
        }
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
        case .pinned, .running: []
        }
    }

    /// The window a drop should target when combining.
    var primaryWindowID: CGWindowID? {
        windows.first?.id
    }
}

/// A run of items drawn together in pill view.
///
/// Sections exist only for the bucketed view of All. A window can belong to
/// several groups and therefore appear in several sections, which is why the
/// section id has to take part in each slot's identity — two views sharing one
/// identity is what corrupted the switcher's rendering once already.
struct DeckSection: Identifiable {
    let id: String
    /// Whose arrangement this section uses, and what a drop into it joins. Nil
    /// for sections that belong to no group: the unfiled capsule, and All's own
    /// leading launchers.
    let groupID: UUID?
    /// Tint of the capsule, or nil for items drawn without one.
    let color: Color?
    /// Draw a divider before this section.
    let dividerBefore: Bool
    let items: [DeckItem]

    var isPill: Bool { color != nil }
}
