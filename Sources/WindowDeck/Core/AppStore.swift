import AppKit
import Observation
import SwiftUI

/// Single source of truth shared by the strip and the settings window.
@MainActor
@Observable
final class AppStore {

    var isTrusted: Bool = Permissions.isTrusted

    /// Every open window on the current Space, refreshed by `WindowEngine`.
    var windows: [WindowInfo] = []

    /// The window currently in front, so the strip can say what you're in.
    var focusedWindowID: CGWindowID? {
        didSet { noteFocusForMRU(focusedWindowID, previous: oldValue) }
    }

    /// Most-recently-used window order, newest first. This is what makes a
    /// single tap of the cycle key flip to the window you were just in.
    @ObservationIgnored private(set) var mruOrder: [CGWindowID] = []

    var shortcuts: [ShortcutAction: Shortcut] = [:] { didSet { scheduleSave() } }
    /// Which batches of default shortcuts this install has already been offered.
    /// Written straight back out so the offer is not repeated.
    @ObservationIgnored private var shortcutSeedVersion = 0
    /// True while a genuinely fullscreen window is frontmost.
    var isFullscreen = false

    /// Index 0 is always the built-in "All" group.
    var groups: [DeckGroup]

    var activeGroupID: UUID {
        didSet {
            guard activeGroupID != oldValue else { return }
            // Explicit direction wins. Comparing indices alone gets the wrap
            // wrong: stepping forward from the last group to the first looks
            // like a jump backwards, and the strip would slide the wrong way at
            // exactly the moment the movement is least obvious.
            if let pending = pendingSwitchDirection {
                switchedForward = pending == .next
            } else if let from = groups.firstIndex(where: { $0.id == oldValue }),
                      let to = groups.firstIndex(where: { $0.id == activeGroupID }) {
                switchedForward = to > from
            }
            pendingSwitchDirection = nil
        }
    }

    /// Which way the last group change moved, so the strip can slide with it.
    private(set) var switchedForward = true
    @ObservationIgnored private var pendingSwitchDirection: GroupCycleDirection?


    // Settings
    var currentSpaceOnly: Bool = true { didSet { onSettingsChanged?(); scheduleSave() } }
    var showTitles: Bool = true { didSet { scheduleSave() } }
    var previewMode: PreviewMode = .thumbnailAndPeek { didSet { scheduleSave() } }
    /// New windows join whichever group is active when they open.
    var autoAddNewWindows: Bool = true { didSet { scheduleSave() } }
    /// Show the focused window as a faded entry when it isn't in this group.
    var showOffGroupWindow: Bool = true { didSet { scheduleSave() } }
    /// In All, split windows belonging to no group off to the right.
    var showUngroupedSeparately: Bool = true { didSet { scheduleSave() } }
    /// Stop zoomed windows extending under the strip.
    var clampZoomedWindows: Bool = true { didSet { onSettingsChanged?(); scheduleSave() } }
    /// Hide the strip while an app is genuinely fullscreen.
    var hideInFullscreen: Bool = true { didSet { scheduleSave() } }
    /// How long a cycle shortcut must be held before the switcher is drawn.
    /// Below this, a tap-and-release just switches with no interface at all.
    var switcherHoldDelay: TimeInterval = 0.18 { didSet { scheduleSave() } }
    /// Horizontal swipe over the strip switches groups. No permission needed.
    var swipeOverStrip: Bool = true { didSet { onGestureSettingsChanged?(); scheduleSave() } }
    /// Trackpad swipe anywhere switches groups. Requires Input Monitoring.
    var globalSwipeGesture: Bool = false { didSet { onGestureSettingsChanged?(); scheduleSave() } }
    /// Finger counts the global gesture accepts. Both by default.
    var swipeFingerCounts: Set<Int> = [3, 4] { didSet { onGestureSettingsChanged?(); scheduleSave() } }
    /// 0 = long deliberate sweep, 1 = light flick. Feeds both swipe paths, which
    /// are measured in different units but should agree about how eager they are.
    var swipeSensitivity: Double = 0.5 { didSet { onGestureSettingsChanged?(); scheduleSave() } }
    /// Slide the strip when the group changes.
    var animateGroupChanges: Bool = true { didSet { scheduleSave() } }

    /// Points of horizontal travel over the strip before it switches.
    var stripSwipeThreshold: CGFloat { 80 - CGFloat(swipeSensitivity) * 66 }
    /// Fraction of the trackpad's width the fingers must cover for a global swipe.
    var globalSwipeTravel: CGFloat { 0.20 - CGFloat(swipeSensitivity) * 0.15 }

    /// Fires when a gesture setting changes, so the tap can be started, stopped
    /// or reconfigured without restarting the app.
    @ObservationIgnored var onGestureSettingsChanged: (() -> Void)?

    /// Colour used to mark the focused window. `All` has no colour of its own,
    /// so it borrows the system accent.
    var focusTint: Color {
        let group = activeGroup
        return group.isAll ? Color.accentColor : group.color.color
    }
    var hoverTimings: HoverTimings = .defaults { didSet { scheduleSave() } }

    /// Fires when a setting the engine cares about changes.
    @ObservationIgnored var onSettingsChanged: (() -> Void)?

    @ObservationIgnored private var saveTimer: Timer?
    @ObservationIgnored private var restoreDeadline: Date?
    /// True when the state file was written during this same boot, so the window
    /// ids it carries still name the same windows.
    @ObservationIgnored private var windowIDsTrustworthy = false

    /// Seconds since the epoch at which the system booted. Stable for the life
    /// of the boot, which is exactly the lifetime of a `CGWindowID`.
    static var systemBootTime: Double {
        var mib = [CTL_KERN, KERN_BOOTTIME]
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return 0 }
        return Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000
    }
    /// Last known app + title for every window seen this session, so a member can
    /// still be described after it leaves the visible list.
    @ObservationIgnored private var knownRefs: [CGWindowID: MemberRef] = [:]

    /// How long after launch to keep trying to rematch saved members. Generous,
    /// because a reboot reopens applications gradually.
    private static let restoreWindow: TimeInterval = 300
    /// Extension granted when a new application launches, so a late starter is
    /// still caught after the initial window lapses.
    private static let restoreExtension: TimeInterval = 60

    init() {
        let all = DeckGroup.allGroup()
        groups = [all]
        activeGroupID = all.id
        loadPersisted()
    }

    // MARK: - Derived

    var activeGroup: DeckGroup {
        groups.first { $0.id == activeGroupID } ?? groups[0]
    }

    /// What the strip renders. The intersection with `windows` is what makes
    /// membership live — a closed window simply stops appearing.
    var visibleWindows: [WindowInfo] {
        let group = activeGroup
        return group.isAll ? windows : windows.filter { group.memberIDs.contains($0.id) }
    }

    /// Items the user has dragged into place lead, in that order; anything else
    /// keeps the default sort and trails behind. Operates on item keys so a
    /// pinned app and a window can sit next to each other in one arrangement.
    private func applyManualOrder(_ items: [DeckItem], order: [String]) -> [DeckItem] {
        guard !order.isEmpty else { return items }
        var rank: [String: Int] = [:]
        for (index, key) in order.enumerated() { rank[key] = index }

        return items.enumerated().sorted { lhs, rhs in
            switch (rank[lhs.element.orderKey], rank[rhs.element.orderKey]) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// Moves one item to sit where another currently is, within the active
    /// group. Keys rather than window ids, so a pin can be dragged among windows.
    func moveItem(_ key: String, before target: String) {
        guard key != target,
              let index = groups.firstIndex(where: { $0.id == activeGroupID })
        else { return }

        // Seed from what's on screen right now, so the first drag nudges one
        // entry instead of reshuffling the whole strip. Launchers currently
        // hidden behind an open window of the same app are seeded too, in the
        // pins-first position they default to — without that, the first drag in
        // a group would silently condemn them to the end of the row when they
        // came back.
        var order = groups[index].order
        if order.isEmpty {
            let pinKeys = groups[index].pinnedApps.map { "p\($0.bundleID)" }
            order = pinKeys + visibleItems.map(\.orderKey).filter { !pinKeys.contains($0) }
        }

        order.removeAll { $0 == key }
        if let targetIndex = order.firstIndex(of: target) {
            order.insert(key, at: targetIndex)
        } else {
            order.append(key)
        }
        groups[index].order = order
        // Debounced rather than immediate: this fires repeatedly as a drag
        // passes over each neighbour.
        scheduleSave()
    }

    /// What the strip actually draws: loose windows, with clustered ones folded
    /// into a single item at the position of their first surviving member.
    var visibleItems: [DeckItem] {
        let group = activeGroup
        let windows = visibleWindows
        // Note the ghost is appended on *both* paths. Returning early here
        // without it meant the off-group signal never appeared for any group
        // that had no clusters — which is most of them.
        // Both paths must run the same post-processing. Returning early with
        // only part of it is exactly how the off-group signal silently never
        // appeared for groups without clusters — which is most of them.
        guard !group.clusters.isEmpty else {
            return finishItems(windows.map { .window($0) })
        }

        var consumed: Set<CGWindowID> = []
        var items: [DeckItem] = []

        for window in windows where !consumed.contains(window.id) {
            guard let cluster = group.clusters.first(where: { $0.contains(window.id) }) else {
                items.append(.window(window))
                consumed.insert(window.id)
                continue
            }

            // Members in the cluster's own order, restricted to those still open.
            let members = cluster.memberIDs.compactMap { id in windows.first { $0.id == id } }
            guard members.count >= 2 else {
                // A cluster down to one live window is just an entry again.
                items.append(.window(window))
                consumed.insert(window.id)
                continue
            }

            items.append(.cluster(cluster, members))
            consumed.formUnion(members.map(\.id))
        }

        return finishItems(items)
    }

    /// Shared tail for both paths: fold in the pinned launchers, apply the
    /// manual arrangement over the combined list, then split off the ungrouped
    /// windows and the off-group ghost.
    ///
    /// Both paths must run all of it — returning early with only part of it is
    /// how the off-group signal silently never appeared for groups without
    /// clusters.
    private func finishItems(_ items: [DeckItem]) -> [DeckItem] {
        let ordered = applyManualOrder(pins(alongside: items) + items, order: activeGroup.order)
        return appendGhostIfNeeded(to: partitionUngrouped(ordered))
    }

    /// The group's launchers, minus any whose app already has a window here.
    ///
    /// A launcher's whole job is "open this". Once a window of that app is on
    /// screen in this group, the window entry does that job, and showing both
    /// put two identical icons side by side with no way to tell which was
    /// which. The pin keeps its place in the manual arrangement while hidden,
    /// so it returns where you put it once the last such window closes or
    /// leaves the group.
    ///
    /// Deliberately compared against `items` rather than the finished list: the
    /// ghost is the focused window when it is *not* a member, so an app present
    /// only as a ghost still deserves its launcher.
    private func pins(alongside items: [DeckItem]) -> [DeckItem] {
        let present = Set(items.flatMap { $0.windows.compactMap(\.bundleID) })
        return activeGroup.pinnedApps
            .filter { !present.contains($0.bundleID) }
            .map { DeckItem.pinned($0) }
    }

    /// In All, moves windows belonging to no group to the end, marked so the
    /// view can separate them. That is the only place the distinction means
    /// anything — inside a named group, everything shown is a member.
    ///
    /// Clusters stay on the left regardless: a cluster is something arranged
    /// deliberately, so it is not "unfiled" even if its members have no group.
    private func partitionUngrouped(_ items: [DeckItem]) -> [DeckItem] {
        guard activeGroup.isAll, showUngroupedSeparately else { return items }
        guard groups.contains(where: { !$0.isAll && !$0.memberIDs.isEmpty }) else { return items }

        var grouped: [DeckItem] = []
        var ungrouped: [DeckItem] = []

        for item in items {
            // Pins and clusters are deliberate arrangements, not unfiled windows.
            guard case .window(let window) = item else {
                grouped.append(item)
                continue
            }
            if groups.contains(where: { !$0.isAll && $0.memberIDs.contains(window.id) }) {
                grouped.append(item)
            } else {
                ungrouped.append(.ungrouped(window))
            }
        }

        return grouped + ungrouped
    }

    /// If the focused window isn't among the items on show, tack it on the end
    /// as a ghost. Without this the strip silently claims you're in a group you
    /// have actually navigated away from.
    private func appendGhostIfNeeded(to items: [DeckItem]) -> [DeckItem] {
        guard showOffGroupWindow,
              let focusedWindowID,
              let focused = windows.first(where: { $0.id == focusedWindowID }),
              !items.contains(where: { $0.windows.contains { $0.id == focusedWindowID } })
        else { return items }

        return items + [.ghost(focused)]
    }

    /// Fired with the window that just *stopped* being focused. That instant is
    /// when its content is final, and it is exactly the state a switcher should
    /// show later — so it is the right moment to snapshot it, and it costs one
    /// capture per switch rather than a polling loop.
    @ObservationIgnored var onWindowLostFocus: ((WindowInfo) -> Void)?

    private func noteFocusForMRU(_ id: CGWindowID?, previous: CGWindowID?) {
        guard let id, id != previous else { return }
        mruOrder.removeAll { $0 == id }
        mruOrder.insert(id, at: 0)
        // Bounded: without this it accumulates every window ever focused.
        if mruOrder.count > 200 { mruOrder.removeLast(mruOrder.count - 200) }

        if let previous, let window = windows.first(where: { $0.id == previous }) {
            onWindowLostFocus?(window)
        }
    }

    /// Cycling candidates for the active group, most recently used first.
    ///
    /// Anything never focused this session still appears, after the windows that
    /// have been — so a freshly opened group is navigable rather than empty.
    func cycleCandidates(appOnly: Bool) -> [WindowInfo] {
        var pool = visibleWindows

        if appOnly {
            // Resolved against every tracked window, not the group's. Looking it
            // up in the group made the shortcut a silent no-op whenever the
            // window you were in wasn't a member of the group on show — which is
            // most of the time once you have groups.
            guard let focusedWindowID,
                  let current = windows.first(where: { $0.id == focusedWindowID })
            else { return [] }

            let withinGroup = pool.filter { $0.pid == current.pid }
            // Prefer the group's windows, but only when the current window is
            // actually among them; otherwise "cycle this app's windows" would
            // mean cycling a set you aren't in.
            pool = withinGroup.contains { $0.id == current.id }
                ? withinGroup
                : windows.filter { $0.pid == current.pid }
        }

        var rank: [CGWindowID: Int] = [:]
        for (index, id) in mruOrder.enumerated() { rank[id] = index }

        let ordered = pool.enumerated().sorted { lhs, rhs in
            switch (rank[lhs.element.id], rank[rhs.element.id]) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)

        // Put the current window first *explicitly* rather than trusting it to
        // be `mruOrder[0]`. That only holds if focus was recorded before the
        // press, and the switcher opening a fraction too early is exactly what
        // made it lead with the wrong window.
        guard let focusedWindowID,
              let currentIndex = ordered.firstIndex(where: { $0.id == focusedWindowID })
        else { return ordered }

        var result = ordered
        let current = result.remove(at: currentIndex)
        result.insert(current, at: 0)
        return result
    }


    /// Groups a window can be added to — everything except "All", which is
    /// automatic.
    var assignableGroups: [DeckGroup] {
        groups.filter { !$0.isAll }
    }

    /// Each group carries its own launchers.
    var visiblePinnedApps: [PinnedApp] {
        activeGroup.pinnedApps
    }

    func groupsContaining(_ windowID: CGWindowID) -> Set<UUID> {
        Set(groups.filter { !$0.isAll && $0.memberIDs.contains(windowID) }.map(\.id))
    }

    /// Group colours for a window, in group order — the dots under a strip entry
    /// and the badges in Settings.
    func colors(containing windowID: CGWindowID) -> [GroupColor] {
        groups.filter { !$0.isAll && $0.memberIDs.contains(windowID) }.map(\.color)
    }

    /// Groups a window belongs to, in order, for labelled badges.
    func memberGroups(of windowID: CGWindowID) -> [DeckGroup] {
        groups.filter { !$0.isAll && $0.memberIDs.contains(windowID) }
    }

    /// Position in the list drives the ⌃1/⌃2/⌃3 binding, so it's shown in the UI.
    func shortcutLabel(for groupID: UUID) -> String? {
        guard let index = groups.firstIndex(where: { $0.id == groupID }), index < 9 else { return nil }
        return "⌃\(index + 1)"
    }

    /// Whether that shortcut actually registered. Populated by HotKeyManager;
    /// macOS wins ⌃1–⌃9 whenever multiple Spaces exist. Observed, so Settings
    /// redraws when registrations change — adding a group re-registers the whole
    /// set.
    var registeredActions: Set<ShortcutAction> = []

    func shortcutWorks(for groupID: UUID) -> Bool {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return false }
        return registeredActions.contains(.selectGroup(index + 1))
    }

    func setShortcut(_ shortcut: Shortcut?, for action: ShortcutAction) {
        if let shortcut {
            // A combination can only drive one action, or registration order
            // would silently decide which of them wins.
            for (existing, value) in shortcuts where value == shortcut && existing != action {
                shortcuts.removeValue(forKey: existing)
            }
            shortcuts[action] = shortcut
        } else {
            shortcuts.removeValue(forKey: action)
        }
        onShortcutsChanged?()
    }

    func resetShortcuts() {
        shortcuts = Self.defaultShortcuts()
        onShortcutsChanged?()
    }

    @ObservationIgnored var onShortcutsChanged: (() -> Void)?

    /// App-window cycling ships unbound on purpose: ⌘` already belongs to macOS
    /// and F1 is a brightness key unless that has been changed, so any default
    /// would silently fail to register.
    static func defaultShortcuts() -> [ShortcutAction: Shortcut] {
        var defaults: [ShortcutAction: Shortcut] = [
            .cycleGroupWindows: .defaultGroupCycle,
            .cycleGroups(.previous): .defaultGroupsCycle(.previous),
            .cycleGroups(.next): .defaultGroupsCycle(.next)
        ]
        for position in 1...9 {
            if let shortcut = Shortcut.groupSelect(position: position) {
                defaults[.selectGroup(position)] = shortcut
            }
        }
        return defaults
    }

    // MARK: - Membership

    // Membership changes save immediately rather than on the debounce. They are
    // infrequent, they are the thing most expensive to lose, and the app is
    // routinely killed rather than quit during development.

    func add(_ windowID: CGWindowID, to groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }), !groups[index].isAll else { return }
        groups[index].memberIDs.insert(windowID)
        saveNow()
    }

    func remove(_ windowID: CGWindowID, from groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].memberIDs.remove(windowID)
        saveNow()
    }

    func toggle(_ windowID: CGWindowID, in groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }), !groups[index].isAll else { return }
        if groups[index].memberIDs.contains(windowID) {
            groups[index].memberIDs.remove(windowID)
        } else {
            groups[index].memberIDs.insert(windowID)
        }
        saveNow()
    }

    func isMember(_ windowID: CGWindowID, of groupID: UUID) -> Bool {
        groups.first { $0.id == groupID }?.memberIDs.contains(windowID) ?? false
    }

    // MARK: - Group management

    @discardableResult
    func addGroup(named name: String) -> DeckGroup {
        // Cycle the palette so a run of new groups is visually distinguishable
        // without the user having to pick colours.
        let group = DeckGroup(
            name: name,
            colorIndex: GroupColor.suggested(forGroupCount: groups.count - 1).rawValue
        )
        groups.append(group)
        scheduleSave()
        return group
    }

    func setColor(_ color: GroupColor, for groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }), !groups[index].isAll else { return }
        groups[index].colorIndex = color.rawValue
        scheduleSave()
    }

    func color(for groupID: UUID) -> GroupColor {
        groups.first { $0.id == groupID }?.color ?? .neutral
    }

    func rename(_ groupID: UUID, to name: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }), !groups[index].isAll else { return }
        groups[index].name = name
        scheduleSave()
    }

    func deleteGroup(_ groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }), !groups[index].isAll else { return }
        groups.remove(at: index)
        if activeGroupID == groupID { activeGroupID = groups[0].id }
        scheduleSave()
    }

    /// "All" is pinned to index 0; user groups reorder freely below it.
    func moveGroups(from source: IndexSet, to destination: Int) {
        var reordered = groups
        reordered.move(fromOffsets: source, toOffset: destination)
        if let allIndex = reordered.firstIndex(where: { $0.isAll }), allIndex != 0 {
            let all = reordered.remove(at: allIndex)
            reordered.insert(all, at: 0)
        }
        groups = reordered
        scheduleSave()
    }

    /// `direction` is supplied by the paths that know which way they went —
    /// cycling and swiping. Picking from the menu has no direction, so the
    /// animation falls back to comparing positions.
    func selectGroup(_ groupID: UUID, direction: GroupCycleDirection? = nil) {
        guard groups.contains(where: { $0.id == groupID }) else { return }
        pendingSwitchDirection = direction
        activeGroupID = groupID
    }

    /// Cycles to the group at a 1-based position, for the ⌃N shortcuts.
    func selectGroup(atPosition position: Int) {
        guard position >= 1, position <= groups.count else { return }
        activeGroupID = groups[position - 1].id
    }

    /// Index of the active group in strip order — where a group cycle starts
    /// from. Falls back to All rather than nothing, so the cycle still works if
    /// the active id ever goes stale.
    var activeGroupIndex: Int {
        groups.firstIndex { $0.id == activeGroupID } ?? 0
    }

    /// Steps `delta` places through the groups, wrapping at both ends. Wrapping
    /// rather than stopping because the list is short and circular movement is
    /// what every other cycle in the app does.
    func groupIndex(steppedBy delta: Int, from index: Int) -> Int {
        guard !groups.isEmpty else { return 0 }
        return ((index + delta) % groups.count + groups.count) % groups.count
    }

    // MARK: - Pinned apps

    func pin(_ app: PinnedApp, in groupID: UUID? = nil) {
        let target = groupID ?? activeGroupID
        guard let index = groups.firstIndex(where: { $0.id == target }) else { return }
        guard !groups[index].pinnedApps.contains(where: { $0.bundleID == app.bundleID }) else { return }
        groups[index].pinnedApps.append(app)
        scheduleSave()
    }

    func unpin(_ bundleID: String, in groupID: UUID? = nil) {
        let target = groupID ?? activeGroupID
        guard let index = groups.firstIndex(where: { $0.id == target }) else { return }
        groups[index].pinnedApps.removeAll { $0.bundleID == bundleID }
        scheduleSave()
    }

    func movePinnedApps(from source: IndexSet, to destination: Int, in groupID: UUID? = nil) {
        let target = groupID ?? activeGroupID
        guard let index = groups.firstIndex(where: { $0.id == target }) else { return }
        groups[index].pinnedApps.move(fromOffsets: source, toOffset: destination)
        scheduleSave()
    }

    func pinnedApps(in groupID: UUID) -> [PinnedApp] {
        groups.first { $0.id == groupID }?.pinnedApps ?? []
    }

    // MARK: - Restore

    /// Rebuilds group membership from saved app+title references.
    ///
    /// Runs on every engine refresh rather than once at launch: after a reboot
    /// macOS reopens applications over tens of seconds, so most windows simply
    /// don't exist yet when WindowDeck starts.
    ///
    /// A matched reference is *consumed*. That is what stops a window the user
    /// deliberately removes from a group being silently re-added on the next
    /// refresh.
    @discardableResult
    /// Finds the window a saved reference refers to, in decreasing order of
    /// confidence.
    ///
    /// The id pass is what makes membership survive a rebuild. Restore used to
    /// begin and end at the exact-title pass, and titles are the least stable
    /// thing about a window: Terminal writes its working directory there, System
    /// Settings the current pane, browsers the page, VS Code prefixes "Merging:"
    /// mid-operation, and Activity Monitor's inspector window title contains
    /// WindowDeck's own pid — which changes on every single rebuild, so that
    /// member could never be recovered at all.
    private func candidate(for ref: MemberRef,
                           in windows: [WindowInfo],
                           excluding taken: Set<CGWindowID>) -> WindowInfo? {
        // 1. Same boot, same id: certain, and covers the rebuild case exactly.
        if windowIDsTrustworthy, let id = ref.windowID, !taken.contains(id),
           let match = windows.first(where: { $0.id == id && $0.bundleID == ref.bundleID }) {
            return match
        }
        // 2. Same app and the very same title.
        if let match = windows.first(where: { ref.matches($0) && !taken.contains($0.id) }) {
            return match
        }
        // 3. Same app and one title contains the other. Last resort, and still
        //    app-scoped — never "any window of this app", which would put the
        //    wrong document in a group after a restart.
        return windows.first { ref.looselyMatches($0) && !taken.contains($0.id) }
    }

    func restorePass(against windows: [WindowInfo]) -> Set<CGWindowID> {
        guard let deadline = restoreDeadline else { return [] }
        guard Date() < deadline else { restoreDeadline = nil; return [] }

        var claimed: Set<CGWindowID> = []

        for index in groups.indices {
            if !groups[index].isAll, !groups[index].savedMembers.isEmpty {
                var members = groups[index].memberIDs
                var stillMissing: [MemberRef] = []

                for ref in groups[index].savedMembers {
                    // Each reference takes at most one window, and never one that
                    // is already a member — two windows of the same document stay
                    // distinct.
                    if let match = candidate(for: ref, in: windows, excluding: members) {
                        members.insert(match.id)
                        claimed.insert(match.id)
                    } else {
                        stillMissing.append(ref)
                    }
                }

                groups[index].memberIDs = members
                groups[index].savedMembers = stillMissing
            }

            // The manual arrangement restores the same way. Applies to All too,
            // which has no membership but can still be hand-ordered.
            if !groups[index].savedOrder.isEmpty {
                var order = groups[index].order
                var stillMissing: [OrderRef] = []

                for ref in groups[index].savedOrder {
                    switch ref {
                    case .pinned(let bundleID):
                        // A pin exists as soon as the group has it — nothing to
                        // wait for, unlike a window that has to reappear.
                        let key = "p\(bundleID)"
                        if !order.contains(key) { order.append(key) }
                    case .window(let member):
                        if let match = windows.first(where: {
                            member.matches($0) && !order.contains("w\($0.id)")
                        }) {
                            order.append("w\(match.id)")
                        } else {
                            stillMissing.append(ref)
                        }
                    }
                }

                groups[index].order = order
                groups[index].savedOrder = stillMissing
            }

            for clusterIndex in groups[index].clusters.indices
            where !groups[index].clusters[clusterIndex].savedMembers.isEmpty {
                var members = groups[index].clusters[clusterIndex].memberIDs
                var stillMissing: [MemberRef] = []

                for ref in groups[index].clusters[clusterIndex].savedMembers {
                    if let match = windows.first(where: { ref.matches($0) && !members.contains($0.id) }) {
                        members.append(match.id)
                    } else {
                        stillMissing.append(ref)
                    }
                }

                groups[index].clusters[clusterIndex].memberIDs = members
                groups[index].clusters[clusterIndex].savedMembers = stillMissing
            }
        }

        return claimed
    }

    // MARK: - Clusters

    /// Combines two entries into one icon, or grows an existing cluster when
    /// either side is already part of one.
    func combine(_ windowID: CGWindowID, into targetID: CGWindowID) {
        guard windowID != targetID,
              let index = groups.firstIndex(where: { $0.id == activeGroupID })
        else { return }

        // Dropping onto a cluster adds to it rather than nesting.
        if let clusterIndex = groups[index].clusters.firstIndex(where: { $0.contains(targetID) }) {
            detach(windowID, in: index)
            groups[index].clusters[clusterIndex].memberIDs.append(windowID)
        } else if let clusterIndex = groups[index].clusters.firstIndex(where: { $0.contains(windowID) }) {
            groups[index].clusters[clusterIndex].memberIDs.append(targetID)
        } else {
            // Target first: it is the one that stays put, so it is the member
            // that ends up focused when the cluster is clicked.
            groups[index].clusters.append(WindowCluster(memberIDs: [targetID, windowID]))
        }

        saveNow()
    }

    func dissolveCluster(_ clusterID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == activeGroupID }) else { return }
        groups[index].clusters.removeAll { $0.id == clusterID }
        saveNow()
    }

    func renameCluster(_ clusterID: UUID, to name: String) {
        guard let index = groups.firstIndex(where: { $0.id == activeGroupID }),
              let clusterIndex = groups[index].clusters.firstIndex(where: { $0.id == clusterID })
        else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        groups[index].clusters[clusterIndex].customName = trimmed.isEmpty ? nil : trimmed
        saveNow()
    }

    func removeFromCluster(_ windowID: CGWindowID) {
        guard let index = groups.firstIndex(where: { $0.id == activeGroupID }) else { return }
        detach(windowID, in: index)
        saveNow()
    }

    private func detach(_ windowID: CGWindowID, in groupIndex: Int) {
        for clusterIndex in groups[groupIndex].clusters.indices {
            groups[groupIndex].clusters[clusterIndex].memberIDs.removeAll { $0 == windowID }
        }
        groups[groupIndex].clusters.removeAll { !$0.isViable && $0.savedMembers.isEmpty }
    }

    /// Drops closed windows out of clusters, and dissolves any left with fewer
    /// than two members. Also evicts stale window descriptions.
    ///
    /// Writes only when something actually changed — this runs on every refresh,
    /// and `groups` is observed, so an unconditional write would redraw the strip
    /// several times a second.
    func pruneClusters() {
        // Runs on every refresh, so it must cost nothing in the common case —
        // no clusters at all. Without this it built a set of every window id
        // several times a second just to iterate empty arrays.
        guard groups.contains(where: { !$0.clusters.isEmpty }) else { return }

        let liveIDs = Set(windows.map(\.id))
        var changed = false
        for index in groups.indices {
            var group = groups[index]
            if group.pruneClusters(liveIDs: liveIDs) {
                groups[index] = group
                changed = true
            }
        }
        if changed { scheduleSave() }
        pruneKnownRefs(liveIDs: liveIDs)
    }

    /// `knownRefs` would otherwise grow for the life of the process, one entry
    /// per window ever seen. Descriptions are kept only while the window is live
    /// or something still refers to it.
    private func pruneKnownRefs(liveIDs: Set<CGWindowID>) {
        guard knownRefs.count > 400 else { return }
        var needed = liveIDs
        for group in groups {
            needed.formUnion(group.memberIDs)
            // Order holds mixed keys now; only the window ones name a window.
            for key in group.order where key.hasPrefix("w") {
                if let id = CGWindowID(key.dropFirst()) { needed.insert(id) }
            }
            for cluster in group.clusters { needed.formUnion(cluster.memberIDs) }
        }
        knownRefs = knownRefs.filter { needed.contains($0.key) }
    }

    /// Adds freshly-opened windows to whichever group is active, so working
    /// inside a group keeps new documents in it without any manual step.
    ///
    /// Two guards, both learned from the failure modes rather than guessed:
    ///
    /// - Nothing happens while `All` is active; it already contains everything.
    /// - Nothing happens while a restore is still pending. After a reboot,
    ///   applications reopen over tens of seconds and every one of those windows
    ///   is genuinely new — without this, switching to a group during that
    ///   window would sweep dozens of unrelated windows into it.
    func captureNewWindows(_ created: Set<CGWindowID>, claimedByRestore: Set<CGWindowID> = []) {
        let now = Date()

        // Queue rather than act immediately. A window reaches the window server
        // before the Accessibility API reports it with a usable subrole and
        // size, so a brand-new window frequently isn't in `windows` on the tick
        // it is first seen. It is only ever "new" for that one tick, so acting
        // there and then loses it for good — which is why opening windows
        // quickly would sometimes silently skip one.
        //
        // The group is recorded per window, so a window opened in Main still
        // joins Main even if the active group changes while it settles.
        if autoAddNewWindows, !activeGroup.isAll, now >= launchGraceEnds {
            for id in created.subtracting(claimedByRestore) {
                pendingCaptures[id] = PendingCapture(groupID: activeGroupID, seen: now)
            }
        }

        // Nothing queued is the overwhelmingly common case; bail before doing any
        // work, rather than rebuilding an empty dictionary on every refresh.
        guard !pendingCaptures.isEmpty else { return }

        for id in claimedByRestore { pendingCaptures.removeValue(forKey: id) }
        // Anything that never becomes trackable — transient dialogs, panels —
        // is dropped rather than queued forever.
        pendingCaptures = pendingCaptures.filter { now.timeIntervalSince($0.value.seen) < 5 }

        guard autoAddNewWindows, !pendingCaptures.isEmpty else { return }
        flushPendingCaptures()
    }

    /// Adds queued windows to the group that was active when they appeared, once
    /// the Accessibility API catches up and starts reporting them.
    private func flushPendingCaptures() {
        let live = Set(windows.map(\.id))
        let ready = pendingCaptures.filter { live.contains($0.key) }
        guard !ready.isEmpty else { return }

        var changed = false
        for (windowID, pending) in ready {
            pendingCaptures.removeValue(forKey: windowID)
            guard let index = groups.firstIndex(where: { $0.id == pending.groupID }),
                  !groups[index].isAll,
                  !groups[index].memberIDs.contains(windowID)
            else { continue }
            groups[index].memberIDs.insert(windowID)
            changed = true
        }

        if changed { saveNow() }
    }


    /// Auto-capture is paused until this moment. Fixed at launch and never
    /// extended. A brief grace covers the reboot storm, when applications reopen
    /// over tens of seconds and every window is technically new.
    @ObservationIgnored private let launchGraceEnds = Date().addingTimeInterval(20)

    /// A window seen by the window server but not yet reported by the
    /// Accessibility API, along with the group it should join once it is.
    private struct PendingCapture {
        let groupID: UUID
        let seen: Date
    }

    @ObservationIgnored private var pendingCaptures: [CGWindowID: PendingCapture] = [:]

    /// Called when an application launches, so windows arriving late still get
    /// matched.
    func extendRestoreWindow() {
        guard groups.contains(where: { !$0.savedMembers.isEmpty }) else { return }
        let extended = Date().addingTimeInterval(Self.restoreExtension)
        restoreDeadline = max(restoreDeadline ?? extended, extended)
    }

    func refreshTrust() {
        isTrusted = Permissions.isTrusted
    }

    // MARK: - Persistence

    private func loadPersisted() {
        let state = StateStore.load()

        groups = [
            DeckGroup.allGroup(
                savedOrder: state.allGroupOrder,
                clusters: state.allGroupClusters.map(Self.cluster(from:)),
                pinnedApps: Self.pinnedApps(from: state.allGroupPinnedBundleIDs)
            )
        ] + state.groups.map { saved in
            DeckGroup(
                // Stable ids across launches — the active-group setting names one.
                id: UUID(uuidString: saved.id) ?? UUID(),
                name: saved.name,
                colorIndex: saved.colorIndex,
                savedMembers: saved.members,
                savedOrder: saved.order,
                clusters: saved.clusters.map(Self.cluster(from:)),
                pinnedApps: Self.pinnedApps(from: saved.pinnedAppBundleIDs)
            )
        }

        activeGroupID = state.activeGroupID
            .flatMap { UUID(uuidString: $0) }
            .flatMap { id in groups.contains { $0.id == id } ? id : nil }
            ?? groups[0].id
        // Windows come back over tens of seconds after a reboot, so restore has
        // to keep trying rather than run once at launch.
        restoreDeadline = Date().addingTimeInterval(Self.restoreWindow)
        currentSpaceOnly = state.currentSpaceOnly
        showTitles = state.showTitles
        previewMode = state.previewMode
        hoverTimings = state.hoverTimings
        autoAddNewWindows = state.autoAddNewWindows
        showOffGroupWindow = state.showOffGroupWindow
        showUngroupedSeparately = state.showUngroupedSeparately
        clampZoomedWindows = state.clampZoomedWindows
        hideInFullscreen = state.hideInFullscreen
        switcherHoldDelay = state.switcherHoldDelay
        swipeOverStrip = state.swipeOverStrip
        globalSwipeGesture = state.globalSwipeGesture
        swipeFingerCounts = Set(state.swipeFingerCounts)
        swipeSensitivity = state.swipeSensitivity
        animateGroupChanges = state.animateGroupChanges
        // Within a tolerance: the recorded boot time can wobble by a hair across
        // reads, and an exact comparison of two floats would throw away a
        // perfectly valid restore.
        windowIDsTrustworthy = state.bootTime > 0
            && abs(state.bootTime - Self.systemBootTime) < 2

        if state.shortcuts.isEmpty {
            shortcuts = Self.defaultShortcuts()
        } else {
            var loaded = state.shortcuts.reduce(into: [ShortcutAction: Shortcut]()) { result, entry in
                guard let action = ShortcutAction.from(storageKey: entry.key) else { return }
                result[action] = entry.value
            }
            // Actions introduced after this file was written are absent from it,
            // and the defaults above are only consulted when there are no saved
            // shortcuts at all — which is never true again after first launch.
            // So each batch is offered exactly once, tracked by the seed version:
            // seeding unconditionally would keep restoring a binding the user
            // deliberately cleared, because a cleared binding is just an absent
            // key and looks identical to one that never existed.
            //
            // Note the guard rather than a `where` on the loop: `a...b` traps
            // when a > b, and it is built before any clause is consulted.
            if state.shortcutSeedVersion < Self.shortcutSeedVersion {
                let defaults = Self.defaultShortcuts()
                for version in (state.shortcutSeedVersion + 1)...Self.shortcutSeedVersion {
                    for action in Self.shortcutsIntroduced(inSeedVersion: version) {
                        guard loaded[action] == nil,
                              let shortcut = defaults[action],
                              // Never steal a combination already bound elsewhere.
                              !loaded.values.contains(shortcut)
                        else { continue }
                        loaded[action] = shortcut
                    }
                }
            }
            shortcuts = loaded
        }
        shortcutSeedVersion = Self.shortcutSeedVersion
    }

    /// Bumped whenever a release adds actions that existing state files should
    /// be offered defaults for.
    static let shortcutSeedVersion = 1

    private static func shortcutsIntroduced(inSeedVersion version: Int) -> [ShortcutAction] {
        switch version {
        case 1: [.cycleGroups(.previous), .cycleGroups(.next)]
        default: []
        }
    }

    /// Coalesced so typing in a rename field doesn't hit disk per keystroke.
    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    /// Bundle ids that no longer resolve to an installed app are dropped.
    private static func pinnedApps(from bundleIDs: [String]) -> [PinnedApp] {
        bundleIDs.compactMap { bundleID in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
            return PinnedApp(url: url)
        }
    }

    private static func cluster(from saved: PersistedCluster) -> WindowCluster {
        WindowCluster(
            id: UUID(uuidString: saved.id) ?? UUID(),
            memberIDs: [],
            savedMembers: saved.members,
            customName: saved.customName
        )
    }

    private func persisted(_ cluster: WindowCluster) -> PersistedCluster {
        PersistedCluster(
            id: cluster.id.uuidString,
            members: cluster.memberIDs.compactMap { knownRefs[$0] } + cluster.savedMembers,
            customName: cluster.customName
        )
    }

    func saveNow() {
        let allGroup = groups.first { $0.isAll }

        StateStore.save(PersistedState(
            groups: groups.filter { !$0.isAll }.map {
                PersistedGroup(
                    id: $0.id.uuidString,
                    name: $0.name,
                    colorIndex: $0.colorIndex,
                    members: snapshot(of: $0),
                    order: orderSnapshot(of: $0),
                    clusters: $0.clusters.map(persisted),
                    pinnedAppBundleIDs: $0.pinnedApps.map(\.bundleID)
                )
            },
            allGroupOrder: allGroup.map(orderSnapshot(of:)) ?? [],
            allGroupClusters: allGroup?.clusters.map(persisted) ?? [],
            allGroupPinnedBundleIDs: allGroup?.pinnedApps.map(\.bundleID) ?? [],
            activeGroupID: activeGroupID.uuidString,
            pinnedAppBundleIDs: [],
            currentSpaceOnly: currentSpaceOnly,
            showTitles: showTitles,
            previewMode: previewMode,
            hoverTimings: hoverTimings,
            autoAddNewWindows: autoAddNewWindows,
            showOffGroupWindow: showOffGroupWindow,
            showUngroupedSeparately: showUngroupedSeparately,
            clampZoomedWindows: clampZoomedWindows,
            hideInFullscreen: hideInFullscreen,
            switcherHoldDelay: switcherHoldDelay,
            shortcuts: shortcuts.reduce(into: [:]) { $0[$1.key.storageKey] = $1.value },
            shortcutSeedVersion: shortcutSeedVersion,
            swipeOverStrip: swipeOverStrip,
            globalSwipeGesture: globalSwipeGesture,
            swipeFingerCounts: swipeFingerCounts.sorted(),
            swipeSensitivity: swipeSensitivity,
            animateGroupChanges: animateGroupChanges,
            bootTime: Self.systemBootTime
        ))
    }

    /// What to write for a group: its members described as app + title, plus any
    /// refs still waiting to be matched.
    ///
    /// Members are looked up in `knownRefs` rather than in the currently visible
    /// window list. With current-Space filtering on, a member living on another
    /// Space is absent from `windows` — building the snapshot from that list
    /// would silently drop it, so a window grouped on one desktop would lose its
    /// group the moment you worked on another.
    ///
    /// The pending refs are appended for the matching reason: saving mid-restore,
    /// before every app has reopened, must not discard members that haven't come
    /// back yet.
    private func snapshot(of group: DeckGroup) -> [MemberRef] {
        let live = group.memberIDs.compactMap { knownRefs[$0] }
        return live + group.savedMembers
    }

    /// The manual arrangement, described the same way members are. Trailing
    /// pending entries are kept so an arrangement isn't truncated while windows
    /// are still reappearing after a restart.
    private func orderSnapshot(of group: DeckGroup) -> [OrderRef] {
        let live: [OrderRef] = group.order.compactMap { key in
            if key.hasPrefix("p") { return .pinned(String(key.dropFirst())) }
            guard let id = CGWindowID(key.dropFirst()), let ref = knownRefs[id] else { return nil }
            return .window(ref)
        }
        return live + group.savedOrder
    }

    /// Remembers how to describe each window across restarts. Updated on every
    /// refresh so a member's description is available even once the window is no
    /// longer visible.
    func noteWindowRefs(_ windows: [WindowInfo]) {
        for window in windows {
            guard let bundleID = window.bundleID else { continue }
            knownRefs[window.id] = MemberRef(bundleID: bundleID, title: window.title,
                                             windowID: window.id)
        }
    }
}
