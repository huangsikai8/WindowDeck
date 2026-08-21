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
    /// An app stack, by bundle id. Every kind of thing the row can draw needs a
    /// case here or its *position* is not persisted at all: `orderSnapshot`
    /// silently drops any key it cannot describe, and `applyManualOrder` has
    /// nowhere to put a key it cannot rank but the end of the row, since a stack
    /// has no window of its own app left beside it to sit next to — so a stack
    /// came back on the far right of its capsule after every relaunch, however
    /// it had been arranged. Nothing failed and nothing was logged; the arrangement simply
    /// changed under you. Adding a case is safe (an old file has none of them);
    /// changing one is what wipes a file.
    case stacked(String)
    /// A hand-made cluster, by its own id — which is persisted and stable across
    /// relaunches, so it means the same thing after one as before.
    ///
    /// The cluster used to have no case here because it borrowed its *first live
    /// member's* window key. That is a key which changes under it: close the
    /// window at the front of a cluster and the whole tile re-keys to the next
    /// member, landing wherever that window happened to sit in the arrangement —
    /// or, if the cluster fell below two live members and unfolded, the survivor
    /// was drawn at its own old position. Either way the tile jumped across the
    /// capsule on a close, which is exactly the failure `.stacked` exists to
    /// prevent for an application. A cluster is a slot the user made by hand, so
    /// it holds one position for its whole life.
    case cluster(String)
}

/// One slot of a saved arrangement while that arrangement is being restored.
///
/// The slot exists because a saved arrangement comes back in pieces. Windows
/// reappear over tens of seconds after a reboot, and even a rebuild has apps
/// that time out on Accessibility for a tick or two — so restore is spread over
/// many passes, and it used to *append* each entry as it matched. The row was
/// then in the sequence the windows happened to arrive rather than the sequence
/// they were left in. Keeping the whole saved list, and recording which order
/// key each entry bound to, is what lets a late arrival be put back in its own
/// place instead of on the end.
///
/// Runtime only: this never reaches the file. `AppStore.orderSnapshot` renders
/// it back to `[OrderRef]`, which is the persisted shape and is unchanged.
struct RestoreSlot: Hashable {
    let ref: OrderRef
    /// The `DeckGroup.order` key this slot bound to once its item was back, or
    /// nil while it is still waiting. A bound slot holds the position of its
    /// still-waiting neighbours; it is dropped when its key leaves the row.
    var key: String?

    init(_ ref: OrderRef, key: String? = nil) {
        self.ref = ref
        self.key = key
    }
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
    /// `DeckItem.orderKey` values so windows and pins can interleave. Nothing
    /// here is ever displaced by something newly opened: an item absent from
    /// this list is drawn beside the windows of its own application, or at the
    /// end when it has none here. See `AppStore.applyManualOrder`.
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
    /// The manual arrangement, saved the same way membership is — one slot per
    /// saved position, each binding to an order key as its item comes back.
    ///
    /// Entries are *not* consumed as they match. They were, and the position
    /// went with them: a pin or a stack binds on the first pass, having nothing
    /// to wait for, while every window waits for its application, so appending
    /// as they matched sent every launcher to the far left of its capsule on
    /// every relaunch. See `RestoreSlot`.
    var savedOrder: [RestoreSlot]
    /// Windows collapsed into single icons within this group. Group-scoped by
    /// construction: clustering in one group leaves the others untouched.
    var clusters: [WindowCluster]
    /// Launchers shown while this group is active. Scoped per group like
    /// membership, since which apps you want to hand are exactly what differs
    /// between one context and another.
    var pinnedApps: [PinnedApp]
    /// Applications whose windows are collapsed behind a single icon here.
    ///
    /// A *rule*, not a list of windows — which is the whole difference from
    /// `clusters`. Every window of a named app in this group is in its stack, so
    /// one opened later joins on its own and one closed leaves without anything
    /// having to notice. That is why this can be a bare bundle id: there are no
    /// window ids to go stale and nothing to prune.
    var stackedAppBundleIDs: Set<String> = []
    /// The fallback group — "Main".
    ///
    /// Every window that no other group claims is drawn in it, so its membership
    /// is *implicit*: `memberIDs` stays empty and the strip computes the
    /// complement. That is what makes "if it isn't filed, it goes to Main" free
    /// — a newly opened window needs no bookkeeping to land somewhere sensible. It cannot be deleted and always sorts first;
    /// unlike the retired "All" group it is otherwise ordinary, with its own
    /// name, colour, launchers, clusters and arrangement.
    let isMain: Bool

    var color: GroupColor {
        GroupColor.from(index: colorIndex)
    }

    /// What the strip actually draws: the custom colour if one was picked,
    /// otherwise the preset. Everything user-facing goes through this.
    var displayColor: Color {
        if let hex = customColorHex, let custom = Color(hex: hex) { return custom }
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
        stackedAppBundleIDs: Set<String> = [],
        isMain: Bool = false
    ) {
        self.pinnedApps = pinnedApps
        self.stackedAppBundleIDs = stackedAppBundleIDs
        self.id = id
        self.name = name
        self.memberIDs = memberIDs
        self.order = order
        self.colorIndex = colorIndex
        self.customColorHex = customColorHex
        self.isCollapsed = isCollapsed
        self.savedMembers = savedMembers
        self.savedOrder = savedOrder.map { RestoreSlot($0) }
        self.clusters = clusters
        self.isMain = isMain
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
