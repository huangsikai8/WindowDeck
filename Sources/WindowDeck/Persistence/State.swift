import Foundation

private extension KeyedDecodingContainer {
    /// Decodes without ever throwing.
    ///
    /// `decodeIfPresent` returns nil only when a key is *absent*; a key whose
    /// value shape has changed throws, and that throw propagates until the whole
    /// state file fails to decode and every group is silently replaced by
    /// defaults. Changing a persisted field's type once did exactly that. One
    /// unreadable field must degrade to its default, never take the file down.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

/// A cluster as written to disk — members by app + title, since window IDs do
/// not survive a relaunch.
struct PersistedCluster: Codable {
    var id: String
    var members: [MemberRef]
    var customName: String?

    init(id: String, members: [MemberRef], customName: String?) {
        self.id = id
        self.members = members
        self.customName = customName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lenient(String.self, .id) ?? UUID().uuidString
        members = container.lenient([MemberRef].self, .members) ?? []
        customName = container.lenient(String.self, .customName)
    }
}

/// A group as written to disk. Window IDs are absent by design — they are
/// reassigned on every launch, so members and arrangement store app + title
/// instead, which is what lets a group find its windows again after a restart.
struct PersistedGroup: Codable {
    var id: String
    var name: String
    var colorIndex: Int
    /// A colour picked outside the preset palette, as "rrggbb".
    var customColorHex: String?
    /// Folded into the overflow cluster in All's pill view.
    var isCollapsed: Bool = false
    var members: [MemberRef]
    /// The manual left-to-right arrangement — windows and pinned apps share it.
    var order: [OrderRef]
    var clusters: [PersistedCluster]
    var pinnedAppBundleIDs: [String]
    /// Applications collapsed behind one icon in this group.
    ///
    /// Bundle ids and nothing else. Unlike `clusters`, which must carry an
    /// `(app, title)` snapshot because window ids do not survive a relaunch,
    /// a stack is a rule about an application — and "Chrome is stacked here"
    /// means exactly the same thing after a relaunch as before one.
    var stackedAppBundleIDs: [String]

    init(
        id: String,
        name: String,
        colorIndex: Int,
        customColorHex: String? = nil,
        isCollapsed: Bool = false,
        members: [MemberRef],
        order: [OrderRef] = [],
        clusters: [PersistedCluster] = [],
        pinnedAppBundleIDs: [String] = [],
        stackedAppBundleIDs: [String] = []
    ) {
        self.pinnedAppBundleIDs = pinnedAppBundleIDs
        self.stackedAppBundleIDs = stackedAppBundleIDs
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.customColorHex = customColorHex
        self.isCollapsed = isCollapsed
        self.members = members
        self.order = order
        self.clusters = clusters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Older files predate stable ids; minting one on read is fine because
        // nothing referenced it before.
        id = container.lenient(String.self, .id) ?? UUID().uuidString
        // Lenient like the rest: the last throwing decode in this path would
        // have failed the whole groups array, and with it every other group.
        name = container.lenient(String.self, .name) ?? "Group"
        colorIndex = container.lenient(Int.self, .colorIndex)
            ?? GroupColor.blue.rawValue
        customColorHex = container.lenient(String.self, .customColorHex)
        isCollapsed = container.lenient(Bool.self, .isCollapsed) ?? false
        members = container.lenient([MemberRef].self, .members) ?? []
        if let refs = container.lenient([OrderRef].self, .order) {
            order = refs
        } else if let legacy = container.lenient([MemberRef].self, .order) {
            // Retired shape: order used to hold windows only.
            order = legacy.map { OrderRef.window($0) }
        } else {
            order = []
        }
        clusters = container.lenient([PersistedCluster].self, .clusters) ?? []
        pinnedAppBundleIDs = container.lenient([String].self, .pinnedAppBundleIDs) ?? []
        stackedAppBundleIDs = container.lenient([String].self, .stackedAppBundleIDs) ?? []
    }
}

/// What survives a relaunch.
struct PersistedState: Codable {
    var groups: [PersistedGroup] = [
        PersistedGroup(id: UUID().uuidString, name: "Work",
                       colorIndex: GroupColor.blue.rawValue, members: []),
        PersistedGroup(id: UUID().uuidString, name: "Study",
                       colorIndex: GroupColor.green.rawValue, members: [])
    ]
    /// Arrangement and clusters for the built-in All group, which has no entry
    /// in `groups`.
    var allGroupOrder: [OrderRef] = []
    var allGroupClusters: [PersistedCluster] = []
    /// The built-in All group has no entry in `groups`, so its launchers live
    /// here — same shape as its order and clusters.
    var allGroupPinnedBundleIDs: [String] = []
    /// All's stacked applications, for the same reason as the line above.
    var allGroupStackedBundleIDs: [String] = []
    var activeGroupID: String?
    var pinnedAppBundleIDs: [String] = []
    var currentSpaceOnly: Bool = true
    var showTitles: Bool = true
    var previewMode: PreviewMode = .thumbnailAndPeek
    var hoverTimings: HoverTimings = .defaults
    var autoAddNewWindows: Bool = true
    var showOffGroupWindow: Bool = true
    var showUngroupedSeparately: Bool = true
    var clampZoomedWindows: Bool = true
    var hideInFullscreen: Bool = true
    var switcherHoldDelay: TimeInterval = 0.18
    /// What order the window switcher lists candidates in.
    var cycleOrder: CycleOrder = .recentlyUsed
    /// Keep app cycling inside the active group even when the focused window is
    /// not a member of it.
    var appCycleStaysInGroup: Bool = true
    /// In All's pill view, scope cycling to the capsule the focused window is in.
    var cycleWithinPill: Bool = true
    /// Horizontal swipe over the strip switches groups. Free — the events reach
    /// our own window without any permission.
    var swipeOverStrip: Bool = true
    /// Trackpad swipe anywhere switches groups. Off by default: it needs Input
    /// Monitoring, which is more invasive than anything else the app asks for.
    var globalSwipeGesture: Bool = false
    /// Finger counts the global gesture accepts.
    var swipeFingerCounts: [Int] = [3, 4]
    /// 0 = long deliberate sweep, 1 = light flick.
    /// Keep an entry for a running app after its last window closes.
    var showRunningApps: Bool = true
    /// In All, bucket windows into a capsule per group instead of one flat row.
    var pillView: Bool = false
    var swipeSensitivity: Double = 0.5
    var animateGroupChanges: Bool = true
    /// Keyed by `ShortcutAction.storageKey`, since the action isn't a plain
    /// string and JSON keys must be.
    var shortcuts: [String: Shortcut] = [:]
    /// How many rounds of default shortcuts this file has been offered.
    ///
    /// Defaults can only be applied to a file that has none at all, so an action
    /// added later would stay unbound forever. Seeding on every launch instead
    /// would resurrect a binding the user deliberately cleared, since a cleared
    /// binding is simply an absent key. This counter makes each new batch a
    /// one-time offer: seeded once, then never again.
    var shortcutSeedVersion: Int = 0
    /// System boot time when this file was written, as seconds since the epoch.
    ///
    /// `CGWindowID`s are only meaningful within one boot. Comparing this against
    /// the current boot time is what makes it safe to restore membership by id:
    /// same boot, the ids still name the same windows; different boot, they are
    /// meaningless and only titles are trusted.
    var bootTime: Double = 0

    init() {}

    // Declaring init(from:) suppresses the synthesised memberwise initialiser.
    init(
        groups: [PersistedGroup],
        allGroupOrder: [OrderRef],
        allGroupClusters: [PersistedCluster],
        allGroupPinnedBundleIDs: [String],
        allGroupStackedBundleIDs: [String] = [],
        activeGroupID: String?,
        pinnedAppBundleIDs: [String],
        currentSpaceOnly: Bool,
        showTitles: Bool,
        previewMode: PreviewMode,
        hoverTimings: HoverTimings,
        autoAddNewWindows: Bool,
        showOffGroupWindow: Bool,
        showUngroupedSeparately: Bool,
        clampZoomedWindows: Bool,
        hideInFullscreen: Bool,
        switcherHoldDelay: TimeInterval,
        cycleOrder: CycleOrder = .recentlyUsed,
        appCycleStaysInGroup: Bool = true,
        cycleWithinPill: Bool = true,
        shortcuts: [String: Shortcut],
        shortcutSeedVersion: Int,
        swipeOverStrip: Bool,
        globalSwipeGesture: Bool,
        swipeFingerCounts: [Int],
        showRunningApps: Bool,
        pillView: Bool,
        swipeSensitivity: Double,
        animateGroupChanges: Bool,
        bootTime: Double
    ) {
        self.showRunningApps = showRunningApps
        self.pillView = pillView
        self.bootTime = bootTime
        self.swipeSensitivity = swipeSensitivity
        self.animateGroupChanges = animateGroupChanges
        self.swipeOverStrip = swipeOverStrip
        self.globalSwipeGesture = globalSwipeGesture
        self.swipeFingerCounts = swipeFingerCounts
        self.switcherHoldDelay = switcherHoldDelay
        self.cycleOrder = cycleOrder
        self.appCycleStaysInGroup = appCycleStaysInGroup
        self.cycleWithinPill = cycleWithinPill
        self.showOffGroupWindow = showOffGroupWindow
        self.showUngroupedSeparately = showUngroupedSeparately
        self.clampZoomedWindows = clampZoomedWindows
        self.hideInFullscreen = hideInFullscreen
        self.shortcuts = shortcuts
        self.shortcutSeedVersion = shortcutSeedVersion
        self.groups = groups
        self.allGroupOrder = allGroupOrder
        self.allGroupClusters = allGroupClusters
        self.allGroupPinnedBundleIDs = allGroupPinnedBundleIDs
        self.allGroupStackedBundleIDs = allGroupStackedBundleIDs
        self.activeGroupID = activeGroupID
        self.pinnedAppBundleIDs = pinnedAppBundleIDs
        self.currentSpaceOnly = currentSpaceOnly
        self.showTitles = showTitles
        self.previewMode = previewMode
        self.hoverTimings = hoverTimings
        self.autoAddNewWindows = autoAddNewWindows
    }

    /// Every field is optional on read. Synthesised `Decodable` throws when a key
    /// is absent, which would mean any newly added setting wipes an existing
    /// state file — taking the user's groups and pinned apps with it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = PersistedState()

        if let groups = container.lenient([PersistedGroup].self, .groups) {
            self.groups = groups
        } else if let names = container.lenient([String].self, .userGroupNames) {
            // Oldest format stored bare names. Migrate rather than discard, and
            // hand out distinct colours on the way through.
            self.groups = names.enumerated().map { index, name in
                PersistedGroup(
                    id: UUID().uuidString,
                    name: name,
                    colorIndex: GroupColor.suggested(forGroupCount: index).rawValue,
                    members: []
                )
            }
        } else {
            self.groups = fallback.groups
        }

        if let refs = container.lenient([OrderRef].self, .allGroupOrder) {
            allGroupOrder = refs
        } else if let legacy = container.lenient([MemberRef].self, .allGroupOrder) {
            allGroupOrder = legacy.map { OrderRef.window($0) }
        } else {
            allGroupOrder = []
        }
        allGroupClusters = container.lenient([PersistedCluster].self, .allGroupClusters) ?? []
        // Migration: pins used to be a single global list, which conceptually
        // belonged to All. Read it when the new key is absent, or every existing
        // pin would silently disappear on upgrade.
        allGroupPinnedBundleIDs = container.lenient([String].self, .allGroupPinnedBundleIDs)
            ?? (container.lenient([String].self, .pinnedAppBundleIDs) ?? [])
        allGroupStackedBundleIDs = container.lenient([String].self, .allGroupStackedBundleIDs) ?? []
        activeGroupID = container.lenient(String.self, .activeGroupID)
        pinnedAppBundleIDs = container.lenient([String].self, .pinnedAppBundleIDs)
            ?? fallback.pinnedAppBundleIDs
        currentSpaceOnly = container.lenient(Bool.self, .currentSpaceOnly)
            ?? fallback.currentSpaceOnly
        showTitles = container.lenient(Bool.self, .showTitles)
            ?? fallback.showTitles
        previewMode = container.lenient(PreviewMode.self, .previewMode)
            ?? fallback.previewMode
        hoverTimings = container.lenient(HoverTimings.self, .hoverTimings)
            ?? fallback.hoverTimings
        autoAddNewWindows = container.lenient(Bool.self, .autoAddNewWindows)
            ?? fallback.autoAddNewWindows
        showOffGroupWindow = container.lenient(Bool.self, .showOffGroupWindow)
            ?? fallback.showOffGroupWindow
        showUngroupedSeparately = container.lenient(Bool.self, .showUngroupedSeparately)
            ?? fallback.showUngroupedSeparately
        clampZoomedWindows = container.lenient(Bool.self, .clampZoomedWindows)
            ?? fallback.clampZoomedWindows
        hideInFullscreen = container.lenient(Bool.self, .hideInFullscreen)
            ?? fallback.hideInFullscreen
        shortcuts = container.lenient([String: Shortcut].self, .shortcuts)
            ?? fallback.shortcuts
        switcherHoldDelay = container.lenient(TimeInterval.self, .switcherHoldDelay)
            ?? fallback.switcherHoldDelay
        cycleOrder = container.lenient(CycleOrder.self, .cycleOrder) ?? fallback.cycleOrder
        appCycleStaysInGroup = container.lenient(Bool.self, .appCycleStaysInGroup)
            ?? fallback.appCycleStaysInGroup
        cycleWithinPill = container.lenient(Bool.self, .cycleWithinPill)
            ?? fallback.cycleWithinPill
        shortcutSeedVersion = container.lenient(Int.self, .shortcutSeedVersion)
            ?? fallback.shortcutSeedVersion
        swipeOverStrip = container.lenient(Bool.self, .swipeOverStrip)
            ?? fallback.swipeOverStrip
        globalSwipeGesture = container.lenient(Bool.self, .globalSwipeGesture)
            ?? fallback.globalSwipeGesture
        swipeFingerCounts = container.lenient([Int].self, .swipeFingerCounts)
            ?? fallback.swipeFingerCounts
        showRunningApps = container.lenient(Bool.self, .showRunningApps)
            ?? fallback.showRunningApps
        pillView = container.lenient(Bool.self, .pillView) ?? fallback.pillView
        swipeSensitivity = container.lenient(Double.self, .swipeSensitivity)
            ?? fallback.swipeSensitivity
        animateGroupChanges = container.lenient(Bool.self, .animateGroupChanges)
            ?? fallback.animateGroupChanges
        bootTime = container.lenient(Double.self, .bootTime) ?? 0
    }

    /// Written explicitly because `userGroupNames` is read-only legacy — it has
    /// no stored property, which blocks synthesised encoding, and it must not be
    /// written back out.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(groups, forKey: .groups)
        try container.encode(allGroupOrder, forKey: .allGroupOrder)
        try container.encode(allGroupClusters, forKey: .allGroupClusters)
        try container.encode(allGroupPinnedBundleIDs, forKey: .allGroupPinnedBundleIDs)
        try container.encode(allGroupStackedBundleIDs, forKey: .allGroupStackedBundleIDs)
        try container.encodeIfPresent(activeGroupID, forKey: .activeGroupID)
        try container.encode(pinnedAppBundleIDs, forKey: .pinnedAppBundleIDs)
        try container.encode(currentSpaceOnly, forKey: .currentSpaceOnly)
        try container.encode(showTitles, forKey: .showTitles)
        try container.encode(previewMode, forKey: .previewMode)
        try container.encode(hoverTimings, forKey: .hoverTimings)
        try container.encode(autoAddNewWindows, forKey: .autoAddNewWindows)
        try container.encode(showOffGroupWindow, forKey: .showOffGroupWindow)
        try container.encode(showUngroupedSeparately, forKey: .showUngroupedSeparately)
        try container.encode(clampZoomedWindows, forKey: .clampZoomedWindows)
        try container.encode(hideInFullscreen, forKey: .hideInFullscreen)
        try container.encode(shortcuts, forKey: .shortcuts)
        try container.encode(switcherHoldDelay, forKey: .switcherHoldDelay)
        try container.encode(cycleOrder, forKey: .cycleOrder)
        try container.encode(appCycleStaysInGroup, forKey: .appCycleStaysInGroup)
        try container.encode(cycleWithinPill, forKey: .cycleWithinPill)
        try container.encode(shortcutSeedVersion, forKey: .shortcutSeedVersion)
        try container.encode(swipeOverStrip, forKey: .swipeOverStrip)
        try container.encode(globalSwipeGesture, forKey: .globalSwipeGesture)
        try container.encode(swipeFingerCounts, forKey: .swipeFingerCounts)
        try container.encode(showRunningApps, forKey: .showRunningApps)
        try container.encode(pillView, forKey: .pillView)
        try container.encode(swipeSensitivity, forKey: .swipeSensitivity)
        try container.encode(animateGroupChanges, forKey: .animateGroupChanges)
        try container.encode(bootTime, forKey: .bootTime)
    }

    private enum CodingKeys: String, CodingKey {
        case groups, allGroupOrder, allGroupClusters, allGroupPinnedBundleIDs
        case allGroupStackedBundleIDs, activeGroupID
        case pinnedAppBundleIDs, currentSpaceOnly, showTitles, previewMode, hoverTimings
        case autoAddNewWindows, showOffGroupWindow, showUngroupedSeparately
        case clampZoomedWindows, hideInFullscreen
        case shortcuts, switcherHoldDelay, shortcutSeedVersion
        case cycleOrder, appCycleStaysInGroup, cycleWithinPill
        case swipeOverStrip, globalSwipeGesture, swipeFingerCounts
        case swipeSensitivity, animateGroupChanges, bootTime, showRunningApps, pillView
        /// Retired in favour of `groups`; still read so existing files migrate.
        case userGroupNames
    }
}

enum StateStore {

    static var fileURL: URL {
        // `WINDOWDECK_STATE_DIR` redirects the whole state file elsewhere. It
        // exists for the self-test, which must never be pointed at the real one:
        // running destructive persistence checks against live state once left
        // fabricated groups in the running app.
        if let override = ProcessInfo.processInfo.environment["WINDOWDECK_STATE_DIR"] {
            return URL(fileURLWithPath: override).appendingPathComponent("state.json")
        }
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WindowDeck", isDirectory: true)
        return base.appendingPathComponent("state.json")
    }

    static var backupURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("state.backup.json")
    }

    /// Loads the state file, falling back to the previous generation before ever
    /// falling back to defaults.
    ///
    /// Returning defaults silently destroys every group, so it must be the last
    /// resort rather than the first. This exists because changing a persisted
    /// field's *type* once made the whole file fail to decode and wiped it — the
    /// decoders are now non-throwing per field, and this is the second line of
    /// defence.
    static func load() -> PersistedState {
        // A file that decodes is authoritative even if it has no groups —
        // deleting every group is a legitimate thing to do, and treating "empty"
        // as "broken" would resurrect groups from the backup after you removed
        // them. Only a genuine decode failure falls through.
        if let data = try? Data(contentsOf: fileURL),
           let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
            Trace.log(.state, "loaded primary: \(data.count) bytes, \(state.groups.count) groups, "
                + "\(state.groups.reduce(0) { $0 + $1.members.count }) members, "
                + "\(state.shortcuts.count) shortcuts")
            return state
        }

        // Worth a warning rather than a note. Reaching the backup means the
        // primary failed to decode, which is the failure mode that once wiped
        // every group — the recovery worked, but something upstream is wrong.
        if let data = try? Data(contentsOf: backupURL),
           let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
            NSLog("WindowDeck: primary state unreadable — recovered from backup")
            Trace.warn(.state, "primary state UNREADABLE — recovered backup: "
                + "\(state.groups.count) groups, \(data.count) bytes")
            return state
        }

        let existed = FileManager.default.fileExists(atPath: fileURL.path)
        Trace.log(.state, "starting from defaults (state file \(existed ? "present but unreadable" : "absent"))",
                  level: existed ? .error : .info)
        return PersistedState()
    }

    static func save(_ state: PersistedState) {
        let url = fileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)

            // Keep the previous generation before overwriting, so a bad write or
            // a decoding regression is recoverable rather than terminal. Only
            // when there is something worth keeping — never back up a default
            // file over a good one.
            if !state.groups.isEmpty,
               let existing = try? Data(contentsOf: url),
               let previous = try? JSONDecoder().decode(PersistedState.self, from: existing),
               !previous.groups.isEmpty {
                try? existing.write(to: backupURL, options: .atomic)
            }

            try data.write(to: url, options: .atomic)
            Trace.debug(.state, "saved \(data.count) bytes, \(state.groups.count) groups, "
                + "\(state.groups.reduce(0) { $0 + $1.members.count }) members")
        } catch {
            NSLog("WindowDeck: failed to save state — \(error.localizedDescription)")
            Trace.error(.state, "SAVE FAILED — \(error.localizedDescription)")
        }
    }
}
