import SwiftUI
import AppKit

/// A saved reference to a window, used only to rebuild membership after a
/// relaunch. Identifies a window the way a human would — which app, which
/// document — because that is the only thing about a window that survives the
/// process restarting.
struct MemberRef: Codable, Hashable {
    let bundleID: String
    let title: String
    /// The window's id at the moment it was saved.
    ///
    /// Ids are reassigned on reboot, so this is only trustworthy within one boot
    /// — but rebuilding the app kills and relaunches it in about two seconds,
    /// during which every window keeps the id it had. That makes this an exact
    /// key for the case that matters most, where titles are the least reliable.
    /// See `PersistedState.bootTime` for the guard.
    let windowID: CGWindowID?

    init(bundleID: String, title: String, windowID: CGWindowID? = nil) {
        self.bundleID = bundleID
        self.title = title
        self.windowID = windowID
    }

    /// Lenient like everything else persisted: a file written before `windowID`
    /// existed must still decode, and a member with an unreadable title is worth
    /// keeping rather than failing the whole group.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = (try? c.decodeIfPresent(String.self, forKey: .bundleID)) as? String ?? ""
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) as? String ?? ""
        windowID = (try? c.decodeIfPresent(CGWindowID.self, forKey: .windowID)) ?? nil
    }

    func matches(_ window: WindowInfo) -> Bool {
        window.bundleID == bundleID && window.title == title
    }

    /// Same app, and one title contains the other once case and spacing are
    /// normalised. Catches the common case of an app decorating its own title —
    /// VS Code prefixing "Merging: ", a browser appending a status — without the
    /// looseness of matching on the app alone.
    func looselyMatches(_ window: WindowInfo) -> Bool {
        guard window.bundleID == bundleID else { return false }
        let a = Self.normalise(title)
        let b = Self.normalise(window.title)
        // Short titles are too easy to collide with; "Inbox" would match half a
        // mail client.
        guard min(a.count, b.count) >= 8 else { return false }
        return a.contains(b) || b.contains(a)
    }

    private static func normalise(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// A position in the strip's manual arrangement. Windows and pinned apps share
/// one ordering, so a pin can sit between two windows and stay there — which
/// means the saved form has to describe either kind.
enum OrderRef: Codable, Hashable {
    case window(MemberRef)
    case pinned(String)
}

/// A named arrangement of windows — "Work", "Study", and so on.
///
/// Membership is held in **two** representations, because each covers the
/// other's weakness:
///
/// - `memberIDs` is authoritative while the app runs. `CGWindowID` is immune to
///   a window being renamed, which matters because browsers rewrite their window
///   title on every tab switch — keying membership on titles alone would evict
///   windows mid-session.
/// - `savedMembers` is a `(bundleID, title)` snapshot written on save. Window IDs
///   are reassigned by macOS on every launch, so this is the only thing that can
///   re-seed the group afterwards.
struct DeckGroup: Identifiable, Hashable {
    let id: UUID
    var name: String
    var memberIDs: Set<CGWindowID>
    /// Manual left-to-right order set by dragging entries in the strip, as
    /// `DeckItem.orderKey` values so windows and pins can interleave. Items
    /// absent from it fall to the end in the default order, so something newly
    /// opened never displaces what you already arranged.
    var order: [String]
    var colorIndex: Int
    /// A colour chosen from the picker, as "rrggbb". Overrides `colorIndex` when
    /// set, so the eight presets stay a one-click choice and anything else is
    /// still possible. Stored as hex rather than a `Color` because `Color` is
    /// not usefully Codable and the state file has to stay plain JSON.
    var customColorHex: String?
    /// Folded away in All's pill view: the group keeps its place in the bar as a
    /// dot in the overflow cluster rather than a full capsule.
    var isCollapsed: Bool = false
    /// Snapshot for restore. Entries are removed as they are matched, so a
    /// window the user later removes by hand is never silently re-added.
    var savedMembers: [MemberRef]
    /// The manual arrangement, saved the same way membership is. Consumed as it
    /// is matched, so the restored order is rebuilt in the sequence it was left.
    var savedOrder: [OrderRef]
    /// Windows collapsed into single icons within this group. Group-scoped by
    /// construction: clustering in one group leaves the others untouched.
    var clusters: [WindowCluster]
    /// Launchers shown while this group is active. Scoped per group like
    /// membership, since which apps you want to hand are exactly what differs
    /// between one context and another.
    var pinnedApps: [PinnedApp]
    /// The built-in "All" group: shows every window, can't be renamed, deleted,
    /// or moved out of first position, and is the only group with pinned apps.
    let isAll: Bool

    var color: GroupColor {
        isAll ? .neutral : GroupColor.from(index: colorIndex)
    }

    /// What the strip actually draws: the custom colour if one was picked,
    /// otherwise the preset. Everything user-facing goes through this.
    var displayColor: Color {
        if !isAll, let hex = customColorHex, let custom = Color(hex: hex) { return custom }
        return color.color
    }

    init(
        id: UUID = UUID(),
        name: String,
        memberIDs: Set<CGWindowID> = [],
        order: [String] = [],
        colorIndex: Int = GroupColor.blue.rawValue,
        customColorHex: String? = nil,
        isCollapsed: Bool = false,
        savedMembers: [MemberRef] = [],
        savedOrder: [OrderRef] = [],
        clusters: [WindowCluster] = [],
        pinnedApps: [PinnedApp] = [],
        isAll: Bool = false
    ) {
        self.pinnedApps = pinnedApps
        self.id = id
        self.name = name
        self.memberIDs = memberIDs
        self.order = order
        self.colorIndex = colorIndex
        self.customColorHex = customColorHex
        self.isCollapsed = isCollapsed
        self.savedMembers = savedMembers
        self.savedOrder = savedOrder
        self.clusters = clusters
        self.isAll = isAll
    }

    /// The built-in group keeps a fixed id across launches so the active-group
    /// setting can name it.
    static let allGroupID = UUID(uuidString: "00000000-0000-0000-0000-0000574E4441")!

    static func allGroup(order: [String] = [], savedOrder: [OrderRef] = [],
                         clusters: [WindowCluster] = [],
                         pinnedApps: [PinnedApp] = []) -> DeckGroup {
        DeckGroup(
            id: allGroupID,
            name: "All",
            order: order,
            colorIndex: GroupColor.neutral.rawValue,
            savedOrder: savedOrder,
            clusters: clusters,
            pinnedApps: pinnedApps,
            isAll: true
        )
    }

    /// Clusters whose membership has fallen below two windows are meaningless
    /// and are dropped as members close.
    ///
    /// Returns whether anything actually changed. The caller runs this on every
    /// refresh — a few times a second — and this type is observed, so writing
    /// unconditionally would redraw the whole strip continuously.
    @discardableResult
    mutating func pruneClusters(liveIDs: Set<CGWindowID>) -> Bool {
        let needsPrune = clusters.contains { cluster in
            cluster.memberIDs.contains { !liveIDs.contains($0) }
        } || clusters.contains { !$0.isViable && $0.savedMembers.isEmpty }

        guard needsPrune else { return false }

        for index in clusters.indices {
            clusters[index].memberIDs.removeAll { !liveIDs.contains($0) }
        }
        clusters.removeAll { !$0.isViable && $0.savedMembers.isEmpty }
        return true
    }
}
