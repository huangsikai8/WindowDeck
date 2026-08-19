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
    /// Folded out of the strip into the overflow control.
    var isCollapsed: Bool = false
    /// The fallback group. Exactly one group carries this, it always sorts
    /// first, and it cannot be deleted — every window no other group claims is
    /// drawn in it. Persisted rather than derived from position so that
    /// reordering the strip can never change which group is the fallback.
    var isMain: Bool = false
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
        isMain: Bool = false,
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
        self.isMain = isMain
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
        isMain = container.lenient(Bool.self, .isMain) ?? false
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
        PersistedGroup(id: UUID().uuidString, name: "Main",
                       colorIndex: GroupColor.blue.rawValue, isMain: true, members: [])
    ]
    var currentSpaceOnly: Bool = true
    var showTitles: Bool = true
    var previewMode: PreviewMode = .thumbnailAndPeek
    var hoverTimings: HoverTimings = .defaults
    /// A newly opened window joins the group holding the focused window.
    var autoAddNewWindows: Bool = true
    var clampZoomedWindows: Bool = true
    var hideInFullscreen: Bool = true
    var switcherHoldDelay: TimeInterval = 0.18
    /// What order the window switcher lists candidates in.
    var cycleOrder: CycleOrder = .recentlyUsed
    /// Keep app cycling inside the capsule the focused window is in, even when
    /// the app has other windows elsewhere on the strip.
    var appCycleStaysInGroup: Bool = true
    /// Keep an entry for a running app after its last window closes.
    var showRunningApps: Bool = true
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
        currentSpaceOnly: Bool,
        showTitles: Bool,
        previewMode: PreviewMode,
        hoverTimings: HoverTimings,
        autoAddNewWindows: Bool,
        clampZoomedWindows: Bool,
        hideInFullscreen: Bool,
        switcherHoldDelay: TimeInterval,
        cycleOrder: CycleOrder = .recentlyUsed,
        appCycleStaysInGroup: Bool = true,
        shortcuts: [String: Shortcut],
        shortcutSeedVersion: Int,
        showRunningApps: Bool,
        bootTime: Double
    ) {
        self.showRunningApps = showRunningApps
        self.bootTime = bootTime
        self.switcherHoldDelay = switcherHoldDelay
        self.cycleOrder = cycleOrder
        self.appCycleStaysInGroup = appCycleStaysInGroup
        self.clampZoomedWindows = clampZoomedWindows
        self.hideInFullscreen = hideInFullscreen
        self.shortcuts = shortcuts
        self.shortcutSeedVersion = shortcutSeedVersion
        self.groups = groups
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

        var groups: [PersistedGroup]
        if let decoded = container.lenient([PersistedGroup].self, .groups) {
            groups = decoded
        } else if let names = container.lenient([String].self, .userGroupNames) {
            // Oldest format stored bare names. Migrate rather than discard, and
            // hand out distinct colours on the way through.
            groups = names.enumerated().map { index, name in
                PersistedGroup(
                    id: UUID().uuidString,
                    name: name,
                    colorIndex: GroupColor.suggested(forGroupCount: index).rawValue,
                    members: []
                )
            }
        } else {
            groups = fallback.groups
        }

        // The retired built-in "All" group, which had no entry in `groups` and
        // kept its arrangement, launchers, clusters and stacks out here. Its
        // contents belong to Main now: All held the whole strip, and the strip
        // is Main plus the other capsules.
        var legacyOrder: [OrderRef] = []
        if let refs = container.lenient([OrderRef].self, .allGroupOrder) {
            legacyOrder = refs
        } else if let legacy = container.lenient([MemberRef].self, .allGroupOrder) {
            legacyOrder = legacy.map { OrderRef.window($0) }
        }
        let legacyClusters = container.lenient([PersistedCluster].self, .allGroupClusters) ?? []
        // Pins were a single global list before they belonged to All, so both
        // retired keys are read — either one skipped means every pin silently
        // disappears on upgrade.
        let legacyPins = container.lenient([String].self, .allGroupPinnedBundleIDs)
            ?? (container.lenient([String].self, .pinnedAppBundleIDs) ?? [])
        let legacyStacks = container.lenient([String].self, .allGroupStackedBundleIDs) ?? []

        self.groups = Self.migrate(groups,
                                   legacyOrder: legacyOrder,
                                   legacyClusters: legacyClusters,
                                   legacyPins: legacyPins,
                                   legacyStacks: legacyStacks)

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
        shortcutSeedVersion = container.lenient(Int.self, .shortcutSeedVersion)
            ?? fallback.shortcutSeedVersion
        showRunningApps = container.lenient(Bool.self, .showRunningApps)
            ?? fallback.showRunningApps
        bootTime = container.lenient(Double.self, .bootTime) ?? 0
    }

    /// Brings any file up to the one-capsule-per-window model.
    ///
    /// Three things have to hold afterwards, and each of them is a decision:
    ///
    /// - **Exactly one group is Main.** A file written before Main existed names
    ///   none, so the first group *called* "Main" is adopted — a user who
    ///   already built one means that one — and only failing that does the
    ///   leading group get the job. Main then sorts first.
    /// - **Main loses every tie.** A window filed in both Main and Work is a
    ///   Work window: Main is the catch-all, so taking the first group in strip
    ///   order (which Main is) would empty every specific capsule into it. Among
    ///   two *specific* groups the first in strip order wins, which is the same
    ///   deterministic rule the retired pill cycling used.
    /// - **Main's membership is left alone**, not deleted. It is inert — a window
    ///   is in Main precisely when nothing else claims it, and nothing reads
    ///   Main's list — and the first save drops it. Deleting it here instead
    ///   would throw away the membership of a group that was adopted *as* Main
    ///   because the file had none, which is exactly the kind of quiet loss the
    ///   persistence contract exists to prevent.
    private static func migrate(_ groups: [PersistedGroup],
                                legacyOrder: [OrderRef],
                                legacyClusters: [PersistedCluster],
                                legacyPins: [String],
                                legacyStacks: [String]) -> [PersistedGroup] {
        var groups = groups
        guard !groups.isEmpty else {
            return [PersistedGroup(id: UUID().uuidString, name: "Main",
                                   colorIndex: GroupColor.blue.rawValue,
                                   isMain: true, members: [],
                                   order: legacyOrder, clusters: legacyClusters,
                                   pinnedAppBundleIDs: legacyPins,
                                   stackedAppBundleIDs: legacyStacks)]
        }

        var mainIndex = groups.firstIndex { $0.isMain }
            ?? groups.firstIndex { $0.name.lowercased() == "main" }
            ?? 0
        groups[mainIndex].isMain = true
        for index in groups.indices where index != mainIndex { groups[index].isMain = false }
        if mainIndex != 0 {
            let main = groups.remove(at: mainIndex)
            groups.insert(main, at: 0)
            mainIndex = 0
        }

        // All's leftovers join Main, appended rather than prepended: Main's own
        // arrangement is the one that was drawn in its capsule, and All's held
        // the launchers and the unfiled tail that now belong there too.
        groups[mainIndex].order += legacyOrder.filter { !groups[mainIndex].order.contains($0) }
        groups[mainIndex].clusters += legacyClusters
        groups[mainIndex].pinnedAppBundleIDs += legacyPins
            .filter { !groups[mainIndex].pinnedAppBundleIDs.contains($0) }
        groups[mainIndex].stackedAppBundleIDs += legacyStacks
            .filter { !groups[mainIndex].stackedAppBundleIDs.contains($0) }

        var claimed: Set<MemberRef> = []
        for index in groups.indices where index != mainIndex {
            groups[index].members = groups[index].members.filter { claimed.insert($0).inserted }
        }
        return groups
    }

    /// Written explicitly because `userGroupNames` is read-only legacy — it has
    /// no stored property, which blocks synthesised encoding, and it must not be
    /// written back out. The retired All-group keys are in the same position:
    /// read for migration, never written again.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(groups, forKey: .groups)
        try container.encode(currentSpaceOnly, forKey: .currentSpaceOnly)
        try container.encode(showTitles, forKey: .showTitles)
        try container.encode(previewMode, forKey: .previewMode)
        try container.encode(hoverTimings, forKey: .hoverTimings)
        try container.encode(autoAddNewWindows, forKey: .autoAddNewWindows)
        try container.encode(clampZoomedWindows, forKey: .clampZoomedWindows)
        try container.encode(hideInFullscreen, forKey: .hideInFullscreen)
        try container.encode(shortcuts, forKey: .shortcuts)
        try container.encode(switcherHoldDelay, forKey: .switcherHoldDelay)
        try container.encode(cycleOrder, forKey: .cycleOrder)
        try container.encode(appCycleStaysInGroup, forKey: .appCycleStaysInGroup)
        try container.encode(shortcutSeedVersion, forKey: .shortcutSeedVersion)
        try container.encode(showRunningApps, forKey: .showRunningApps)
        try container.encode(bootTime, forKey: .bootTime)
    }

    private enum CodingKeys: String, CodingKey {
        case groups
        case currentSpaceOnly, showTitles, previewMode, hoverTimings
        case autoAddNewWindows, clampZoomedWindows, hideInFullscreen
        case shortcuts, switcherHoldDelay, shortcutSeedVersion
        case cycleOrder, appCycleStaysInGroup
        case bootTime, showRunningApps
        /// Retired in favour of `groups`; still read so existing files migrate.
        case userGroupNames
        /// The retired built-in All group. Read once, folded into Main, never
        /// written again — see `migrate`.
        case allGroupOrder, allGroupClusters, allGroupPinnedBundleIDs
        case allGroupStackedBundleIDs, pinnedAppBundleIDs
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
