import AppKit
import SwiftUI

/// One slot in the strip: either a single window, or a cluster standing in for
/// several.
enum DeckItem: Identifiable {
    case window(WindowInfo)
    case cluster(WindowCluster, [WindowInfo])
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
    /// `instance` is the process this launcher stands for. Two copies of one
    /// application share a bundle id, so it is the process — not the bundle —
    /// that makes two launchers two different things. Nil only in fixtures.
    case running(PinnedApp, placeholderFor: CGWindowID?, instance: AppStore.AppInstance?)
    /// Every window of one application in this group, behind that application's
    /// own icon.
    ///
    /// Deliberately *not* a `cluster` of one app. A cluster is a list of window
    /// ids the user assembled; this is a rule about an application, so its
    /// members are recomputed from `windows` on every redraw and a window opened
    /// later joins with nothing having to be told. The two also behave
    /// differently on click — a cluster raises all its members, a stack raises
    /// one — which is why they are separate kinds rather than a flag.
    case appStack(bundleID: String, windows: [WindowInfo])

    var id: String {
        switch self {
        case .window(let window): "w\(window.id)"
        case .cluster(let cluster, _): "c\(cluster.id.uuidString)"
        case .pinned(let app): "p\(app.bundleID)"
        // The process, not the bundle id: two copies of one application would
        // otherwise be one identity on two views, which is what once rendered
        // the switcher rotated with two tiles highlighted at once.
        case .running(let app, _, let instance):
            instance.map { "r\(app.bundleID)#\($0.pid)" } ?? "r\(app.bundleID)"
        case .appStack(let bundleID, _): "s\(bundleID)"
        }
    }

    /// Stable key used by the group's manual arrangement. Windows and pins share
    /// one ordering, so both need a key in the same namespace.
    var orderKey: String {
        switch self {
        case .window(let window): "w\(window.id)"
        // The cluster itself, never its leading member. Keying on
        // `members.first` is a key that moves under the tile: close the front
        // window of a cluster and the whole thing re-keys to the next member and
        // is drawn wherever *that* window sat in the arrangement, and a cluster
        // that falls below two live members unfolds and draws its survivor at the
        // survivor's own old position. Both jump the tile across the capsule on a
        // close. A cluster is a slot the user made by hand, so — exactly like
        // `.appStack` below — its key is good for its whole life however its
        // windows come and go.
        case .cluster(let cluster, _): "c\(cluster.id.uuidString)"
        case .pinned(let app): "p\(app.bundleID)"
        // The closed window's own key, so the slot keeps the position it held in
        // the manual arrangement instead of jumping when the window closes.
        case .running(let app, let windowID, _):
            windowID.map { "w\($0)" } ?? "p\(app.bundleID)"
        // The application, not its leftmost member: a stack's identity *is* the
        // app, so this key is good for the stack's whole life however its windows
        // come and go. A cluster now holds its slot the same way, by its own id.
        case .appStack(let bundleID, _): "s\(bundleID)"
        }
    }

    /// Which applications this item stands for.
    ///
    /// A *set* rather than one id because a hand-made cluster can hold windows
    /// of two applications, and a new window of either one should recognise the
    /// cluster its siblings are already in.
    ///
    /// A window with no bundle id falls back to its application's name. Both
    /// halves are namespaced, or an app named after another's bundle id would
    /// match it.
    var appKeys: Set<String> {
        switch self {
        case .pinned(let app), .running(let app, _, _): ["b\(app.bundleID)"]
        // The rule, not its current members: a stack is an application, and it
        // has to answer for that application even in the moment it is drawing
        // no windows.
        case .appStack(let bundleID, _): ["b\(bundleID)"]
        default: Set(windows.map { window in
                window.bundleID.map { "b\($0)" } ?? "n\(window.appName)"
            })
        }
    }

    /// Do these two items belong to the same application? What "beside the
    /// window that is already open" means when the strip places a tile the user
    /// has not arranged by hand.
    func sharesApp(with other: DeckItem) -> Bool {
        !appKeys.isDisjoint(with: other.appKeys)
    }

    /// The application a launcher stands for, if this item is one. Main defers
    /// to the other capsules over these, so it has to be able to ask.
    var launcherBundleID: String? {
        switch self {
        case .pinned(let app), .running(let app, _, _): app.bundleID
        default: nil
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

    var isStack: Bool {
        if case .appStack = self { return true }
        return false
    }

    /// Windows this item stands for — one for a plain entry, several for a
    /// cluster.
    var windows: [WindowInfo] {
        switch self {
        case .window(let window): [window]
        case .cluster(_, let members): members
        case .pinned, .running: []
        // Reporting these is what keeps `pins(alongside:)` hiding the launcher
        // for a stacked app: the rule there is "an app with a window here does
        // not also need a launcher", and a stacked window is still a window.
        case .appStack(_, let members): members
        }
    }

    /// The window a drop should target when combining.
    var primaryWindowID: CGWindowID? {
        windows.first?.id
    }
}

/// One capsule's worth of items.
///
/// The strip is a row of these, one per group, Main first. The section id takes
/// part in each slot's identity even though a window is only drawn once: a
/// pinned launcher genuinely can appear in two capsules, and two views sharing
/// one identity is what corrupted the switcher's rendering once already.
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
