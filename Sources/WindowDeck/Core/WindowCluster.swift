import AppKit

/// Several windows collapsed into one icon in the strip.
///
/// Member order is significant: the **first** member is the one focused when the
/// cluster is clicked, so "which window do I end up in" is a property the user
/// controls rather than whatever the window server raised last.
///
/// Like group membership, this carries both live IDs and a `(bundleID, title)`
/// snapshot — IDs are immune to a window being renamed mid-session, the snapshot
/// is the only thing that survives a relaunch.
struct WindowCluster: Identifiable, Hashable {
    let id: UUID
    /// Ordered. `first` is the member that ends up focused.
    var memberIDs: [CGWindowID]
    var savedMembers: [MemberRef]
    var customName: String?

    init(
        id: UUID = UUID(),
        memberIDs: [CGWindowID],
        savedMembers: [MemberRef] = [],
        customName: String? = nil
    ) {
        self.id = id
        self.memberIDs = memberIDs
        self.savedMembers = savedMembers
        self.customName = customName
    }

    /// A cluster of one is pointless — it renders and behaves exactly like a
    /// plain entry, so it dissolves instead.
    var isViable: Bool { memberIDs.count >= 2 }

    func contains(_ windowID: CGWindowID) -> Bool {
        memberIDs.contains(windowID)
    }

    func displayName(resolving windows: [WindowInfo]) -> String {
        if let customName, !customName.isEmpty { return customName }
        return "\(memberIDs.count) windows"
    }
}
