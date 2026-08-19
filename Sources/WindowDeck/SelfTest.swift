import AppKit
import SwiftUI

/// Exercises the logic that has no other way of being checked.
///
/// There is no test target: the app is a single SwiftPM executable, and the
/// pieces worth testing need `AppStore`, which is `@MainActor` and reads the
/// state file. Running in-process against a throwaway state directory gets the
/// coverage without either problem.
///
/// Run with `WINDOWDECK_SELFTEST=1`, which also sets a temporary state directory
/// in `build.sh`. It must never run against the real state file.
@MainActor
enum SelfTest {

    private static var failures: [String] = []
    private static var passes = 0

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["WINDOWDECK_SELFTEST"] == "1"
    }

    private static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            passes += 1
        } else {
            failures.append("FAIL  \(name)\(detail().isEmpty ? "" : "  — \(detail())")")
        }
    }

    static func run() -> Never {
        precondition(ProcessInfo.processInfo.environment["WINDOWDECK_STATE_DIR"] != nil,
                     "self-test refuses to run against the real state file")

        persistence()
        ordering()
        matching()
        membership()
        sections()
        layout()
        sectionsWithWindows()
        reopening()
        clustering()
        clusterSurvivesClosing()
        edgeCases()
        runningState()
        menuIconCaching()
        capturing()
        appearedExcludesCreated()
        tabSwitchKeepsItsOwnSlot()
        lateDescribedWindowKeepsIntent()
        arrivalWithNothingVacated()
        reorderingInsideAFoldedGroup()
        allGroupsRowOrdering()
        pruning()
        restoring()
        cyclingByRecency()
        cyclingByStripOrder()
        cyclingStartIndex()
        cyclingAppScope()
        cyclingAcrossTwoGroups()
        cyclingWithinPill()
        cyclingPillTieBreak()
        cyclingPersistence()
        appStacks()
        appStackOpensItsOwnWindows()
        appStackOrdering()
        appStackInteractions()
        appStackPersistence()
        appStackHover()
        tracing()

        print("\n=== self-test: \(passes) passed, \(failures.count) failed ===")
        for line in failures { print(line) }
        exit(failures.isEmpty ? 0 : 1)
    }

    // MARK: - Persistence

    private static func persistence() {
        // A file written before a field existed must still load.
        let legacy = """
        {"groups":[{"id":"A","name":"Old","colorIndex":1,"members":[{"bundleID":"x","title":"t"}]}]}
        """
        let decoded = try? JSONDecoder().decode(PersistedState.self, from: Data(legacy.utf8))
        check("legacy file decodes", decoded != nil)
        check("legacy group survives", decoded?.groups.first?.name == "Old")
        check("legacy member survives", decoded?.groups.first?.members.count == 1)
        check("absent field takes its default", decoded?.showRunningApps == true)

        // A field whose *type* changed must degrade to its default, not fail the
        // file — this is the shape that once wiped every group.
        let wrongType = """
        {"groups":[{"id":"A","name":"Keep","colorIndex":1,"members":[]}],"showTitles":"yes","swipeSensitivity":[1,2]}
        """
        let salvaged = try? JSONDecoder().decode(PersistedState.self, from: Data(wrongType.utf8))
        check("changed field type does not fail the file", salvaged != nil)
        check("groups survive a bad sibling field", salvaged?.groups.first?.name == "Keep")
        check("bad field falls back to default", salvaged?.showTitles == true)

        // Round trip.
        var state = PersistedState()
        state.groups = [PersistedGroup(id: "G", name: "Round", colorIndex: 2,
                                       customColorHex: "FF8800",
                                       members: [MemberRef(bundleID: "b", title: "t", windowID: 42)])]
        state.pillView = true
        let data = try? JSONEncoder().encode(state)
        let back = data.flatMap { try? JSONDecoder().decode(PersistedState.self, from: $0) }
        check("round trip keeps custom colour", back?.groups.first?.customColorHex == "FF8800")
        check("round trip keeps window id", back?.groups.first?.members.first?.windowID == 42)
        check("round trip keeps pill view", back?.pillView == true)

        check("hex parses", Color(hex: "FF8800") != nil)
        check("bad hex is rejected", Color(hex: "nope") == nil)
    }

    // MARK: - Ordering

    private static func ordering() {
        let store = AppStore()
        let group = store.groups.first { !$0.isAll }
        guard let group else { return check("a group exists to order", false) }

        store.setOrder(["w1", "w2", "w3", "w4"], in: group.id)

        // The bug that made the last position unreachable.
        store.moveItem("w1", before: "w4", in: group.id)
        check("drag to the far right lands last",
              store.order(in: group.id) == ["w2", "w3", "w4", "w1"],
              "\(store.order(in: group.id))")

        store.moveItem("w1", before: "w2", in: group.id)
        check("drag leftward lands before the target",
              store.order(in: group.id) == ["w1", "w2", "w3", "w4"],
              "\(store.order(in: group.id))")

        store.moveItem("w3", before: "w2", in: group.id)
        check("short leftward move",
              store.order(in: group.id) == ["w1", "w3", "w2", "w4"],
              "\(store.order(in: group.id))")
    }

    // MARK: - Restore matching

    private static func matching() {
        let exact = MemberRef(bundleID: "com.x", title: "Report.docx", windowID: 7)
        let window = WindowInfo.testInstance(id: 99, bundleID: "com.x", title: "Report.docx")
        check("exact title matches", exact.matches(window))

        let renamed = WindowInfo.testInstance(id: 99, bundleID: "com.x", title: "Merging: Report.docx")
        check("exact match rejects a changed title", !exact.matches(renamed))
        check("loose match survives a prefix", exact.looselyMatches(renamed))

        let otherApp = WindowInfo.testInstance(id: 99, bundleID: "com.y", title: "Report.docx")
        check("loose match never crosses apps", !exact.looselyMatches(otherApp))

        let short = MemberRef(bundleID: "com.x", title: "Inbox", windowID: 1)
        let alsoShort = WindowInfo.testInstance(id: 2, bundleID: "com.x", title: "Inbox — Work")
        check("loose match ignores short titles", !short.looselyMatches(alsoShort))
    }

    // MARK: - Membership

    private static func membership() {
        let store = AppStore()
        guard store.groups.count >= 3 else { return check("two groups exist", false) }
        let a = store.groups[1].id, b = store.groups[2].id

        store.add(5, to: a)
        check("added to a group", store.isMember(5, of: a))

        store.moveItem("w5", from: a, to: b)
        check("move joins the target", store.isMember(5, of: b))
        check("move leaves the source", !store.isMember(5, of: a))

        // Dropping into the unfiled capsule: no target, so only a removal.
        store.moveItem("w5", from: b, to: nil)
        check("drop on unfiled removes the source membership", !store.isMember(5, of: b))

        store.pinApp(bundleID: "com.apple.finder", in: a)
        check("pinned to a group", store.pinnedApps(in: a).contains { $0.bundleID == "com.apple.finder" })
        store.moveItem("pcom.apple.finder", from: a, to: b)
        check("pin moves to the target", store.pinnedApps(in: b).contains { $0.bundleID == "com.apple.finder" })
        check("pin leaves the source", !store.pinnedApps(in: a).contains { $0.bundleID == "com.apple.finder" })
    }

    // MARK: - Sections

    private static func sections() {
        let store = AppStore()
        store.pillView = false
        check("flat view is a single section", store.sections.count == 1)
        check("flat section carries no capsule", store.sections.first?.color == nil)

        store.pillView = true
        store.selectGroup(store.groups[0].id)   // All
        // With no windows, every group is empty and must be omitted.
        check("empty groups are omitted", store.sections.allSatisfy { !$0.isPill })
    }

    // MARK: - Sections with real windows

    private static func sectionsWithWindows() {
        let store = AppStore()
        guard store.groups.count >= 3 else { return check("two groups exist", false) }
        let a = store.groups[1].id, b = store.groups[2].id

        // A real bundle id: `pinApp` resolves the application on disk and does
        // nothing for one that does not exist, which would make the pin check
        // below pass vacuously.
        let shared = WindowInfo.testInstance(id: 10, bundleID: "com.apple.finder", title: "Shared")
        let onlyA = WindowInfo.testInstance(id: 11, bundleID: "com.y", title: "OnlyA")
        let loose = WindowInfo.testInstance(id: 12, bundleID: "com.z", title: "Loose")
        store.windows = [shared, onlyA, loose]
        store.add(10, to: a); store.add(10, to: b); store.add(11, to: a)

        store.pillView = true
        store.selectGroup(store.groups[0].id)
        let sections = store.sections

        let pills = sections.filter(\.isPill)
        check("one capsule per non-empty group, plus unfiled", pills.count == 3, "\(pills.count)")

        let inA = sections.first { $0.groupID == a }?.items.compactMap { $0.windows.first?.id } ?? []
        let inB = sections.first { $0.groupID == b }?.items.compactMap { $0.windows.first?.id } ?? []
        check("window in two groups appears in both", inA.contains(10) && inB.contains(10))
        check("window in one group appears once", inA.contains(11) && !inB.contains(11))

        let unfiled = sections.first { $0.id == "ungrouped" }
        check("unfiled capsule exists", unfiled != nil)
        check("unfiled holds only the loose window",
              unfiled?.items.compactMap { $0.windows.first?.id } == [12])
        check("unfiled comes last", sections.last?.id == "ungrouped")
        check("unfiled is preceded by a divider", unfiled?.dividerBefore == true)

        // A launcher must stand aside while its app has a window on show —
        // otherwise the same icon appears twice, which is the duplicate the
        // whole pin-hiding rule exists to prevent.
        store.pinApp(bundleID: "com.apple.finder", in: nil)
        check("the pin was actually created",
              store.pinnedApps(in: DeckGroup.allGroupID).contains { $0.bundleID == "com.apple.finder" })
        let leading = store.sections.first { $0.id == "leading" }
        let leadingPins = leading?.items.compactMap { item -> String? in
            if case .pinned(let app) = item { return app.bundleID }
            return nil
        } ?? []
        check("a pin hides while its app has a window",
              !leadingPins.contains("com.apple.finder"), "\(leadingPins)")

        // The same rule has to hold inside a group capsule, not just the leading
        // launchers: a group pinned to an app whose window is in that very
        // capsule would otherwise draw the icon twice.
        store.pinApp(bundleID: "com.apple.finder", in: a)
        let pillA = store.sections.first { $0.groupID == a }
        let pinsInA = pillA?.items.compactMap { item -> String? in
            if case .pinned(let app) = item { return app.bundleID }
            return nil
        } ?? []
        check("a group pin hides while its app has a window here",
              !pinsInA.contains("com.apple.finder"), "\(pinsInA)")

        // Duplicated windows must not share a slot identity.
        let ids = sections.flatMap { section in
            section.items.map { "\(section.id)/\($0.id)" }
        }
        check("slot identities are unique across capsules", Set(ids).count == ids.count)
    }

    // MARK: - Clusters

    private static func clustering() {
        let store = AppStore()
        guard store.groups.count >= 2 else { return check("a group exists", false) }
        let group = store.groups[1].id

        let a = WindowInfo.testInstance(id: 60, bundleID: "com.f", title: "A")
        let b = WindowInfo.testInstance(id: 61, bundleID: "com.f", title: "B")
        store.windows = [a, b]
        store.noteWindowRefs([a, b])
        store.add(60, to: group); store.add(61, to: group)

        // Pill view: All is active while the drag happens inside a group capsule.
        store.pillView = true
        store.selectGroup(store.groups[0].id)
        check("All is the active group", store.activeGroup.isAll)

        store.combine(60, into: 61, in: group)

        let owner = store.groups.first { $0.id == group }
        check("the cluster is built in the capsule's group",
              owner?.clusters.count == 1, "\(owner?.clusters.count ?? -1)")
        check("All did not receive the cluster",
              store.groups.first { $0.isAll }?.clusters.isEmpty == true)
        check("the cluster holds both windows",
              owner?.clusters.first?.memberIDs.sorted() == [60, 61])

        // It must actually appear in that capsule.
        let section = store.sections.first { $0.groupID == group }
        check("the capsule draws the cluster",
              section?.items.contains { $0.isCluster } == true)

        // The "Group with" list must lead with what you are most likely to want.
        let c = WindowInfo.testInstance(id: 62, bundleID: "com.other", title: "Elsewhere")
        let d = WindowInfo.testInstance(id: 63, bundleID: "com.f", title: "C")
        let e = WindowInfo.testInstance(id: 64, bundleID: "com.f", title: "D")
        store.windows = [a, b, c, d, e]
        store.noteWindowRefs([a, b, c, d, e])
        store.add(62, to: group); store.add(63, to: group); store.add(64, to: group)

        // Everything is listed, including where you are standing — the menu is in
        // strip order, and a gap makes that order harder to read. What you cannot
        // do is group a window with itself, so those entries are marked.
        let fromInside = store.groupWithTargets(for: 60, in: group)
        check("a window's own cluster is shown", fromInside.contains { $0.isCluster })
        check("but it is not selectable",
              fromInside.first { $0.isCluster }?.isSelf == true)

        let targets = store.groupWithTargets(for: 63, in: group)
        check("the window itself is listed", targets.contains { $0.windowID == 63 })
        check("the window itself is not selectable",
              targets.first { $0.windowID == 63 }?.isSelf == true)
        check("every other entry is selectable",
              targets.filter { $0.windowID != 63 && !$0.isCluster }.allSatisfy { !$0.isSelf })
        check("the cluster is offered", targets.contains { $0.isCluster })
        check("windows already in a cluster are not offered separately",
              !targets.contains { !$0.isCluster && $0.windowID == 61 })

        // And dissolving finds it without being told which group owns it.
        if let clusterID = owner?.clusters.first?.id {
            store.dissolveCluster(clusterID)
            check("dissolve finds the owning group",
                  store.groups.first { $0.id == group }?.clusters.isEmpty == true)
        }
    }

    /// A cluster must survive its windows being closed and reopened, exactly as
    /// group membership does.
    ///
    /// Reported as "at first my finder in actelligent window group were grouped
    /// together (5), now i open but its ungrouped". Membership was intact on
    /// disk; every group's `clusters` array was empty. `pruneClusters` evicted a
    /// member id the moment its window left the visible list, so the cluster fell
    /// below two members and deleted itself — and nothing put a reopened window
    /// back into a cluster even when it did survive.
    private static func clusterSurvivesClosing() {
        let store = AppStore()
        guard store.groups.count >= 2 else { return check("a group exists", false) }
        let group = store.groups[1].id

        // The retention rule is "the application is still running", so the
        // fixture has to name an app that genuinely is or the test asserts
        // nothing — the same trap the pin test fell into.
        store.sampleRunningApps(windowOwnerPIDs: [], force: true)
        check("the fixture's app really is running",
              store.runningApps.all.contains("com.apple.finder"))

        func cluster() -> WindowCluster? {
            store.groups.first { $0.id == group }?.clusters.first
        }

        let a = WindowInfo.testInstance(id: 300, bundleID: "com.apple.finder", title: "docs")
        let b = WindowInfo.testInstance(id: 301, bundleID: "com.apple.finder", title: "build")
        let c = WindowInfo.testInstance(id: 302, bundleID: "com.apple.finder", title: "src")
        store.windows = [a, b, c]
        store.noteWindowRefs([a, b, c])
        for id: CGWindowID in [300, 301, 302] { store.add(id, to: group) }
        store.combine(301, into: 300, in: group)
        store.combine(302, into: 300, in: group)
        check("three windows are clustered",
              cluster()?.memberIDs.sorted() == [300, 301, 302],
              "\(cluster()?.memberIDs.sorted() ?? [])")

        // Two of them closed. A dead id is a slot, not rubbish: it is what a
        // reopened window reclaims.
        store.windows = [a]
        store.pruneClusters()
        check("closing members does not dissolve the cluster",
              cluster()?.memberIDs.sorted() == [300, 301, 302],
              "\(cluster()?.memberIDs.sorted() ?? [])")

        // And the dead slots must reach disk as `(app, title)` refs, or the
        // cluster comes back a member short after a relaunch. `persisted(_:)`
        // reads them out of `knownRefs`, so retaining the id is only half of it.
        store.saveNow()
        let onDisk = StateStore.load().groups
            .first { $0.id == group.uuidString }?.clusters.first
        check("the closed members are still persisted",
              onDisk?.members.count == 3, "\(onDisk?.members.count ?? -1)")

        // Reopened under new ids, which is what the red button produces.
        let b2 = WindowInfo.testInstance(id: 311, bundleID: "com.apple.finder", title: "build")
        store.windows = [a, b2]
        store.noteWindowRefs([a, b2])
        store.rebindReopenedWindows([311])
        check("a reopened window rejoins the group", store.isMember(311, of: group))
        check("and rejoins its cluster", cluster()?.contains(311) == true,
              "\(cluster()?.memberIDs.sorted() ?? [])")
        check("the dead slot is released from the cluster",
              cluster()?.contains(301) == false)

        // Two live members again, so the strip draws it as a cluster once more.
        store.selectGroup(group)
        check("the strip folds them back into one tile",
              store.visibleItems.contains { $0.isCluster },
              "\(store.visibleItems.count) items")

        // Growth is still bounded: once the application is gone the slot goes.
        let orphan = AppStore()
        let orphanGroup = orphan.groups[1].id
        let x = WindowInfo.testInstance(id: 320, bundleID: "com.nonexistent.app", title: "X")
        let y = WindowInfo.testInstance(id: 321, bundleID: "com.nonexistent.app", title: "Y")
        orphan.windows = [x, y]
        orphan.noteWindowRefs([x, y])
        orphan.add(320, to: orphanGroup); orphan.add(321, to: orphanGroup)
        orphan.combine(321, into: 320, in: orphanGroup)
        orphan.windows = []
        orphan.sampleRunningApps(windowOwnerPIDs: [], force: true)
        check("the orphan's app really is absent",
              !orphan.runningApps.all.contains("com.nonexistent.app"))
        orphan.pruneClusters()
        // Asserted on this cluster, not on the array: every AppStore here loads
        // the same throwaway state file, so the group can already carry a
        // restored cluster from the checks above.
        check("a cluster of a quit application is dropped",
              orphan.groups.first { $0.id == orphanGroup }?
                  .clusters.contains { $0.contains(320) || $0.contains(321) } == false)
    }

    // MARK: - Close and reopen

    private static func reopening() {
        let store = AppStore()
        guard store.groups.count >= 2 else { return check("a group exists", false) }
        let group = store.groups[1].id

        let original = WindowInfo.testInstance(id: 20, bundleID: "com.app", title: "Doc")
        store.windows = [original]
        store.noteWindowRefs([original])
        store.add(20, to: group)
        store.setOrder(["w20", "w99"], in: group)

        // Closed, then reopened under a new id — what the red button does.
        let reopened = WindowInfo.testInstance(id: 21, bundleID: "com.app", title: "Doc")
        store.windows = [reopened]
        store.noteWindowRefs([reopened])
        let claimed = store.rebindReopenedWindows([21])

        check("a reopened window is claimed", claimed.contains(21))
        check("it inherits the membership", store.isMember(21, of: group))
        check("the dead id is released", !store.isMember(20, of: group))
        check("it inherits the arrangement slot",
              store.order(in: group).first == "w21", "\(store.order(in: group))")

        // A *new* window of the same app must not seize a vacant slot: opening a
        // browser window while working in one group had it claimed by a
        // long-closed member of another.
        let fresh = AppStore()
        guard fresh.groups.count >= 3 else { return check("two groups exist", false) }
        let owner = fresh.groups[1].id
        let old = WindowInfo.testInstance(id: 70, bundleID: "com.browser", title: "Old Tab")
        fresh.windows = [old]; fresh.noteWindowRefs([old])
        fresh.add(70, to: owner)
        fresh.windows = []                       // closed
        let unrelated = WindowInfo.testInstance(id: 71, bundleID: "com.browser", title: "Something Else")
        fresh.windows = [unrelated]; fresh.noteWindowRefs([unrelated])
        check("a differently titled window does not seize the slot",
              !fresh.rebindReopenedWindows([71]).contains(71))
        check("and does not join that group", !fresh.isMember(71, of: owner))

        // A slot whose window vanished long ago must not claim a new one, even
        // when the app and title line up exactly — browsers reuse titles.
        let stale = AppStore()
        let staleGroup = stale.groups[1].id
        let ancient = WindowInfo.testInstance(id: 80, bundleID: "com.browser", title: "New Tab")
        stale.windows = [ancient]
        stale.noteWindowRefs([ancient])
        stale.add(80, to: staleGroup)
        stale.forgetLastSeenForTesting(80)          // as if it closed long ago
        stale.windows = []
        let brandNew = WindowInfo.testInstance(id: 81, bundleID: "com.browser", title: "New Tab")
        stale.windows = [brandNew]; stale.noteWindowRefs([brandNew])
        check("a long-dead slot does not claim a new window",
              !stale.rebindReopenedWindows([81]).contains(81))
        check("so the new window is free to be captured elsewhere",
              !stale.isMember(81, of: staleGroup))

        // Where you are working beats a slot another group is holding.
        let contest = AppStore()
        let holder = contest.groups[1].id      // the group with a stale slot
        let intended = contest.groups[2].id    // where you are actually working
        let dead = WindowInfo.testInstance(id: 90, bundleID: "com.browser", title: "New Tab")
        contest.windows = [dead]; contest.noteWindowRefs([dead])
        contest.add(90, to: holder)
        contest.windows = []
        let opened = WindowInfo.testInstance(id: 91, bundleID: "com.browser", title: "New Tab")
        contest.windows = [opened]; contest.noteWindowRefs([opened])

        check("without an intent, the slot is reclaimed as before",
              contest.rebindReopenedWindows([91]).contains(91))

        let second = AppStore()
        let holder2 = second.groups[1].id, intended2 = second.groups[2].id
        let dead2 = WindowInfo.testInstance(id: 92, bundleID: "com.browser", title: "New Tab")
        second.windows = [dead2]; second.noteWindowRefs([dead2])
        second.add(92, to: holder2)
        second.windows = []
        let opened2 = WindowInfo.testInstance(id: 93, bundleID: "com.browser", title: "New Tab")
        second.windows = [opened2]; second.noteWindowRefs([opened2])
        check("a stated intent stops another group claiming it",
              !second.rebindReopenedWindows([93], preferring: [intended2]).contains(93))
        check("and it does not join the holding group",
              !second.isMember(93, of: holder2))

        // Switching a macOS tab swaps which window id is on screen. The outgoing
        // and incoming tabs share a frame to the pixel, which is the only thing
        // tying them together — titles differ, since each tab is a document.
        let tabs = AppStore()
        let tabGroup = tabs.groups[1].id
        let box = CGRect(x: 100, y: 100, width: 757, height: 559)
        let firstTab = WindowInfo.testInstance(id: 110, bundleID: "com.apple.TextEdit",
                                               title: "Notes", frame: box)
        tabs.windows = [firstTab]; tabs.noteWindowRefs([firstTab])
        tabs.add(110, to: tabGroup)

        let secondTab = WindowInfo.testInstance(id: 111, bundleID: "com.apple.TextEdit",
                                                title: "Shopping list", frame: box)
        tabs.windows = [secondTab]; tabs.noteWindowRefs([secondTab])
        check("switching tabs keeps the group",
              tabs.rebindReopenedWindows([111]).contains(111))
        check("the shown tab is the member now", tabs.isMember(111, of: tabGroup))

        // The path that actually runs on a tab switch: nothing is *created*, a
        // window simply becomes visible while its sibling stops being visible.
        let live = AppStore()
        let liveGroup = live.groups[1].id
        let tabA = WindowInfo.testInstance(id: 120, bundleID: "com.apple.TextEdit",
                                           title: "First", frame: box)
        live.windows = [tabA]; live.noteWindowRefs([tabA])
        live.add(120, to: liveGroup)
        live.rebindAppearedWindows()                    // establishes what is on show

        let tabB = WindowInfo.testInstance(id: 121, bundleID: "com.apple.TextEdit",
                                           title: "Second", frame: box)
        live.windows = [tabB]; live.noteWindowRefs([tabB])
        let switched = live.rebindAppearedWindows()
        check("a tab that comes into view is claimed", switched.contains(121))
        check("membership follows the visible tab", live.isMember(121, of: liveGroup))
        check("and leaves the tab that went away", !live.isMember(120, of: liveGroup))

        // A tab switch must not be refused because you were last working in some
        // other group — that filter is for new windows only.
        let across = AppStore()
        let home = across.groups[1].id
        let box2 = CGRect(x: 10, y: 10, width: 700, height: 500)
        let t1 = WindowInfo.testInstance(id: 130, bundleID: "com.apple.TextEdit", title: "A", frame: box2)
        across.windows = [t1]; across.noteWindowRefs([t1])
        across.add(130, to: home)
        across.rebindAppearedWindows()
        let t2 = WindowInfo.testInstance(id: 131, bundleID: "com.apple.TextEdit", title: "B", frame: box2)
        across.windows = [t2]; across.noteWindowRefs([t2])
        check("a tab switch is not blocked by where you were working",
              across.rebindAppearedWindows().contains(131))
        check("the arriving tab is filed", across.isMember(131, of: home))

        // A different window of the same app, at a different size, is not a tab.
        let separate = AppStore()
        let sepGroup = separate.groups[1].id
        let doc = WindowInfo.testInstance(id: 112, bundleID: "com.apple.TextEdit",
                                          title: "Doc", frame: box)
        separate.windows = [doc]; separate.noteWindowRefs([doc])
        separate.add(112, to: sepGroup)
        let elsewhere = WindowInfo.testInstance(id: 113, bundleID: "com.apple.TextEdit",
                                                title: "Other", frame: CGRect(x: 400, y: 80, width: 500, height: 400))
        separate.windows = [elsewhere]; separate.noteWindowRefs([elsewhere])
        check("a differently placed window is not treated as a tab",
              !separate.rebindReopenedWindows([113]).contains(113))

        // A window of an unrelated app must not steal the slot.
        let other = AppStore()
        let held = WindowInfo.testInstance(id: 30, bundleID: "com.one", title: "A")
        other.windows = [held]; other.noteWindowRefs([held])
        other.add(30, to: other.groups[1].id)
        other.windows = []
        let stranger = WindowInfo.testInstance(id: 31, bundleID: "com.two", title: "B")
        other.windows = [stranger]; other.noteWindowRefs([stranger])
        check("a different app does not claim the slot",
              !other.rebindReopenedWindows([31]).contains(31))
    }

    // MARK: - Edges

    private static func edgeCases() {
        let store = AppStore()
        guard let group = store.groups.first(where: { !$0.isAll })?.id else { return }

        // Dragging something that has no place in the order yet.
        store.setOrder([], in: group)
        store.moveItem("w1", before: "w2", in: group)
        check("dragging with no arrangement does not crash", true)

        // A key that appears twice must not survive a move.
        store.setOrder(["w1", "w2", "w1"], in: group)
        store.moveItem("w1", before: "w2", in: group)
        check("a duplicated key is collapsed by a move",
              store.order(in: group).filter { $0 == "w1" }.count == 1,
              "\(store.order(in: group))")

        // Moving onto itself is a no-op, not a corruption.
        store.setOrder(["w1", "w2"], in: group)
        store.moveItem("w1", before: "w1", in: group)
        check("moving onto itself changes nothing", store.order(in: group) == ["w1", "w2"])

        // An empty layout must still produce a usable width.
        let empty = DeckLayout.compute(items: [], pinnedCount: 0, titlesEnabled: true, maxWidth: 1240)
        check("empty layout has no slots", empty.slots.isEmpty)
        check("empty layout still has a width", empty.totalWidth > 0)

        // A single window on a tiny display must not produce a negative width.
        let tiny = DeckLayout.compute(items: [.window(WindowInfo.testInstance(id: 1, bundleID: "a", title: "t"))],
                                      pinnedCount: 0, titlesEnabled: true, maxWidth: 200)
        check("tiny display yields positive widths", tiny.slots.allSatisfy { $0.width > 0 })
    }

    // MARK: - Running-app state

    private static func runningState() {
        let store = AppStore()
        check("running apps start empty", store.runningApps.all.isEmpty)

        store.sampleRunningApps(windowOwnerPIDs: [], force: true)
        check("sampling finds running applications", !store.runningApps.all.isEmpty)
        check("sampling finds Dock-worthy applications", !store.runningApps.dockApps.isEmpty)
        check("this very process is running", store.runningApps.all.contains(Bundle.main.bundleIdentifier ?? "?")
              || store.runningApps.all.contains("com.apple.finder"))

        // Windows are attributed to their owning application.
        let finder = NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == "com.apple.finder" }
        if let finder {
            store.sampleRunningApps(windowOwnerPIDs: [finder.processIdentifier], force: true)
            check("an app owning a window is marked as having one",
                  store.runningApps.withWindows.contains("com.apple.finder"))
        }
    }

    // MARK: - Cycling

    /// Builds a group holding four windows across two apps, focused on the
    /// second, with a known manual arrangement and a known focus history.
    private static func cyclingFixture() -> (AppStore, UUID, [WindowInfo])? {
        let store = AppStore()
        guard store.groups.count >= 2 else { check("a group exists", false); return nil }
        let group = store.groups[1].id

        let a = WindowInfo.testInstance(id: 10, bundleID: "com.browser", title: "A", pid: 1)
        let b = WindowInfo.testInstance(id: 11, bundleID: "com.browser", title: "B", pid: 1)
        let c = WindowInfo.testInstance(id: 12, bundleID: "com.browser", title: "C", pid: 1)
        let d = WindowInfo.testInstance(id: 13, bundleID: "com.editor", title: "D", pid: 2)
        store.windows = [a, b, c, d]
        store.noteWindowRefs([a, b, c, d])
        for id in [10, 11, 12, 13] { store.add(CGWindowID(id), to: group) }
        store.selectGroup(group)
        store.setOrder(["w10", "w11", "w12", "w13"], in: group)
        // Pinned explicitly. Every `AppStore()` reads the state file the previous
        // test saved, so `pillView` leaks between cases — and pill scoping only
        // applies in pill view, so a test that did not say would silently be
        // exercising whichever mode ran last.
        store.pillView = false

        // Focus history: 12 first, then 10, then 11 — so most-recently-used is
        // 11, 10, 12 and is deliberately *not* the strip order.
        store.focusedWindowID = 12
        store.focusedWindowID = 10
        store.focusedWindowID = 11
        return (store, group, [a, b, c, d])
    }

    /// Most-recently-used order, which is what the switcher has always done.
    /// Pinned here because it had no coverage at all before the fixed-order
    /// setting was added, and a change to one mode must not quietly alter the
    /// other.
    private static func cyclingByRecency() {
        guard let (store, _, _) = cyclingFixture() else { return }
        store.cycleOrder = .recentlyUsed

        let candidates = store.cycleCandidates(appOnly: false)
        check("recency lists every window in the group", candidates.count == 4)
        check("the current window leads", candidates.first?.id == 11, "\(candidates.map(\.id))")
        check("then the rest by recency",
              candidates.map(\.id) == [11, 10, 12, 13], "\(candidates.map(\.id))")

        check("a tap lands on the second entry",
              store.cycleStartIndex(candidates, reversed: false) == 1)
        check("shift-tap lands on the last",
              store.cycleStartIndex(candidates, reversed: true) == 3)
        check("a lone candidate has nowhere to go",
              store.cycleStartIndex([candidates[0]], reversed: false) == 0)
    }

    /// Strip order: positions must not move between opens, which is the whole
    /// request.
    private static func cyclingByStripOrder() {
        guard let (store, group, _) = cyclingFixture() else { return }
        store.cycleOrder = .stripOrder

        let first = store.cycleCandidates(appOnly: false)
        check("strip order follows the manual arrangement",
              first.map(\.id) == [10, 11, 12, 13], "\(first.map(\.id))")

        // The property that matters: focus moves, the list does not. In
        // most-recently-used order this same sequence reorders the array.
        store.focusedWindowID = 13
        let second = store.cycleCandidates(appOnly: false)
        check("the order is unchanged after focus moves",
              second.map(\.id) == first.map(\.id), "\(second.map(\.id))")

        // Rearranging the strip rearranges the switcher — the answer to "I should
        // be able to rearrange it" without any new interface.
        store.moveItem("w12", before: "w10", in: group)
        check("dragging a tile in the strip reorders the switcher",
              store.cycleCandidates(appOnly: false).map(\.id) == [12, 10, 11, 13],
              "\(store.cycleCandidates(appOnly: false).map(\.id))")
    }

    /// Where the first tap lands in a fixed order: the neighbour of where you
    /// stand, not a fixed index.
    private static func cyclingStartIndex() {
        guard let (store, _, _) = cyclingFixture() else { return }
        store.cycleOrder = .stripOrder
        let candidates = store.cycleCandidates(appOnly: false)   // [10, 11, 12, 13]

        store.focusedWindowID = 11
        check("a tap moves one along from where you are",
              store.cycleStartIndex(candidates, reversed: false) == 2)
        check("shift-tap moves one back",
              store.cycleStartIndex(candidates, reversed: true) == 0)

        // Wrapping, at both ends.
        store.focusedWindowID = 13
        check("a tap from the last entry wraps to the first",
              store.cycleStartIndex(candidates, reversed: false) == 0)
        store.focusedWindowID = 10
        check("shift-tap from the first wraps to the last",
              store.cycleStartIndex(candidates, reversed: true) == 3)

        // Cycling *into* a group you are not standing in has no current position.
        store.focusedWindowID = 999
        check("with no position in the list it starts at the near end",
              store.cycleStartIndex(candidates, reversed: false) == 0)
    }

    /// App-scoped cycling and whether it leaves the group.
    ///
    /// Both sides are asserted: a test that only covered the new mode would pass
    /// with the old branch deleted, which is the mistake the frame-matching test
    /// made once already.
    private static func cyclingAppScope() {
        guard let (store, group, _) = cyclingFixture() else { return }
        store.cycleOrder = .stripOrder

        // Standing inside the group: its windows of this app, either way.
        store.focusedWindowID = 11
        store.appCycleStaysInGroup = true
        check("in the group, app cycling is the group's windows of that app",
              store.cycleCandidates(appOnly: true).map(\.id) == [10, 11, 12],
              "\(store.cycleCandidates(appOnly: true).map(\.id))")

        // A window of the same app that is not a member of the group.
        let outside = WindowInfo.testInstance(id: 14, bundleID: "com.browser",
                                              title: "Outside", pid: 1)
        store.windows = store.windows + [outside]
        store.noteWindowRefs(store.windows)
        store.focusedWindowID = 14

        store.appCycleStaysInGroup = true
        check("staying in the group excludes the outside window",
              store.cycleCandidates(appOnly: true).map(\.id) == [10, 11, 12],
              "\(store.cycleCandidates(appOnly: true).map(\.id))")

        store.appCycleStaysInGroup = false
        check("otherwise it falls back to every window of the app",
              store.cycleCandidates(appOnly: true).map(\.id).sorted() == [10, 11, 12, 14],
              "\(store.cycleCandidates(appOnly: true).map(\.id))")

        // A group with nothing of that app must be empty, not a crash. The
        // switcher already guards on an empty list.
        store.appCycleStaysInGroup = true
        let lonely = WindowInfo.testInstance(id: 15, bundleID: "com.other", title: "L", pid: 9)
        store.windows = store.windows + [lonely]
        store.noteWindowRefs(store.windows)
        store.focusedWindowID = 15
        check("a group with none of that app yields nothing",
              store.cycleCandidates(appOnly: true).isEmpty,
              "\(store.cycleCandidates(appOnly: true).map(\.id))")
    }

    /// The reported scenario, exactly: one application's windows split across two
    /// groups, cycling from inside one of them.
    ///
    /// Distinct from `cyclingAppScope`, where the windows outside the group
    /// belonged to no group at all. Here the other four are filed in a *different*
    /// group, which is the arrangement the whole app exists for — and the one
    /// place a scoping mistake would be least visible, since every candidate is a
    /// legitimate window of the right application.
    private static func cyclingAcrossTwoGroups() {
        let store = AppStore()
        guard store.groups.count >= 3 else { return check("two groups exist", false) }
        let main = store.groups[1].id
        let other = store.groups[2].id

        // Four VS Code windows in Main, three in the other group, plus one window
        // of a different app in Main so "everything in Main" is not the answer.
        var all: [WindowInfo] = []
        for id in 20...23 { all.append(.testInstance(id: CGWindowID(id), bundleID: "com.vscode",
                                                     title: "Main \(id)", pid: 5)) }
        for id in 30...32 { all.append(.testInstance(id: CGWindowID(id), bundleID: "com.vscode",
                                                     title: "Other \(id)", pid: 5)) }
        all.append(.testInstance(id: 40, bundleID: "com.terminal", title: "Term", pid: 6))
        store.windows = all
        store.noteWindowRefs(all)
        for id in 20...23 { store.add(CGWindowID(id), to: main) }
        for id in 30...32 { store.add(CGWindowID(id), to: other) }
        store.add(40, to: main)

        store.selectGroup(main)
        store.focusedWindowID = 21
        store.cycleOrder = .stripOrder
        // Flat view: this case is about group scope, not capsule scope. Left
        // inherited, it picked up pill view from an earlier test and the All
        // assertion below measured pill scoping instead.
        store.pillView = false

        let candidates = store.cycleCandidates(appOnly: true)
        check("cycling this app in Main offers only Main's four windows",
              candidates.map(\.id) == [20, 21, 22, 23], "\(candidates.map(\.id))")
        check("the other group's windows of the same app are excluded",
              !candidates.contains { (30...32).contains(Int($0.id)) })
        check("and another app in the same group is excluded",
              !candidates.contains { $0.id == 40 })

        // Standing in the other group, the same key offers that group's three.
        store.selectGroup(other)
        store.focusedWindowID = 31
        check("standing in the other group offers its three instead",
              store.cycleCandidates(appOnly: true).map(\.id) == [30, 31, 32],
              "\(store.cycleCandidates(appOnly: true).map(\.id))")

        // In All there is no group to be limited to, so every window qualifies —
        // "All" meaning all is the one case where the scope is deliberately wide.
        store.selectGroup(store.groups[0].id)
        check("All cycles every window of the app",
              store.cycleCandidates(appOnly: true).map(\.id).sorted()
                == [20, 21, 22, 23, 30, 31, 32],
              "\(store.cycleCandidates(appOnly: true).map(\.id))")
    }

    /// Cycling scoped to the capsule you are working in, while All is active.
    ///
    /// The case the whole feature is for: All is the active group, so the old
    /// scope was "every window on the bar" — but in pill view the windows are
    /// bucketed and only one capsule is the one being worked in.
    private static func cyclingWithinPill() {
        let store = AppStore()
        guard store.groups.count >= 3 else { return check("two groups exist", false) }
        let main = store.groups[1].id
        let other = store.groups[2].id

        var all: [WindowInfo] = []
        for id in 50...52 { all.append(.testInstance(id: CGWindowID(id), bundleID: "com.vscode",
                                                     title: "Main \(id)", pid: 5)) }
        all.append(.testInstance(id: 53, bundleID: "com.terminal", title: "Term", pid: 6))
        for id in 60...61 { all.append(.testInstance(id: CGWindowID(id), bundleID: "com.vscode",
                                                     title: "Other \(id)", pid: 5)) }
        let loose = WindowInfo.testInstance(id: 70, bundleID: "com.notes", title: "Loose", pid: 7)
        let loose2 = WindowInfo.testInstance(id: 71, bundleID: "com.notes", title: "Loose2", pid: 7)
        all += [loose, loose2]
        store.windows = all
        store.noteWindowRefs(all)
        for id in 50...53 { store.add(CGWindowID(id), to: main) }
        for id in 60...61 { store.add(CGWindowID(id), to: other) }

        store.pillView = true
        store.selectGroup(store.groups[0].id)          // All is active
        check("All is the active group", store.activeGroup.isAll)
        store.cycleOrder = .stripOrder
        store.cycleWithinPill = true
        store.focusedWindowID = 51

        // ⌃`: every window in the capsule, across apps.
        check("cycling all windows is scoped to the focused capsule",
              store.cycleCandidates(appOnly: false).map(\.id) == [50, 51, 52, 53],
              "\(store.cycleCandidates(appOnly: false).map(\.id))")
        // ⌘`: the capsule, then the app within it.
        check("cycling this app is scoped to the capsule too",
              store.cycleCandidates(appOnly: true).map(\.id) == [50, 51, 52],
              "\(store.cycleCandidates(appOnly: true).map(\.id))")

        // Standing in the other capsule scopes to that one instead.
        store.focusedWindowID = 60
        check("a different capsule scopes to itself",
              store.cycleCandidates(appOnly: false).map(\.id) == [60, 61],
              "\(store.cycleCandidates(appOnly: false).map(\.id))")

        // The unfiled capsule is a pill like any other.
        store.focusedWindowID = 70
        check("an unfiled window cycles the unfiled capsule",
              store.cycleCandidates(appOnly: false).map(\.id) == [70, 71],
              "\(store.cycleCandidates(appOnly: false).map(\.id))")

        // Off, All means all again — asserting both sides, or the test would pass
        // with the scoping deleted.
        store.cycleWithinPill = false
        store.focusedWindowID = 51
        check("with the setting off, All cycles everything",
              store.cycleCandidates(appOnly: false).count == all.count,
              "\(store.cycleCandidates(appOnly: false).map(\.id))")

        // Flat view has no capsules on screen, so nothing would explain a
        // narrowed list — the scoping must not apply there.
        store.cycleWithinPill = true
        store.pillView = false
        check("flat All is not scoped to a pill",
              store.cycleCandidates(appOnly: false).count == all.count,
              "\(store.cycleCandidates(appOnly: false).map(\.id))")
    }

    /// A window in several groups is drawn in several capsules, so the tie has to
    /// break somewhere predictable.
    private static func cyclingPillTieBreak() {
        let store = AppStore()
        guard store.groups.count >= 3 else { return check("two groups exist", false) }
        let first = store.groups[1].id
        let second = store.groups[2].id

        let shared = WindowInfo.testInstance(id: 80, bundleID: "com.a", title: "Shared", pid: 1)
        let onlyFirst = WindowInfo.testInstance(id: 81, bundleID: "com.a", title: "First", pid: 1)
        let onlySecond = WindowInfo.testInstance(id: 82, bundleID: "com.a", title: "Second", pid: 1)
        store.windows = [shared, onlyFirst, onlySecond]
        store.noteWindowRefs(store.windows)
        store.add(80, to: first); store.add(81, to: first)
        store.add(80, to: second); store.add(82, to: second)

        store.pillView = true
        store.selectGroup(store.groups[0].id)
        store.cycleOrder = .stripOrder
        store.cycleWithinPill = true
        store.focusedWindowID = 80

        check("a window in two groups uses the leftmost capsule",
              store.cycleCandidates(appOnly: false).map(\.id) == [80, 81],
              "\(store.cycleCandidates(appOnly: false).map(\.id))")

        // Reordering the groups moves which capsule is leftmost, which is the
        // control the tie-break rests on — so it has to actually follow.
        store.moveGroups(from: IndexSet(integer: 1), to: 3)
        check("reordering the groups changes which capsule wins",
              store.cycleCandidates(appOnly: false).map(\.id) == [80, 82],
              "\(store.cycleCandidates(appOnly: false).map(\.id))")
    }

    /// Both new settings persist, and a file written before them still loads.
    private static func cyclingPersistence() {
        var state = PersistedState()
        state.cycleOrder = .stripOrder
        state.appCycleStaysInGroup = false
        state.cycleWithinPill = false
        guard let data = try? JSONEncoder().encode(state),
              let back = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return check("cycling settings round-trip", false) }
        check("cycle order round-trips", back.cycleOrder == .stripOrder)
        check("app cycle scope round-trips", back.appCycleStaysInGroup == false)
        check("pill scoping round-trips", back.cycleWithinPill == false)

        let legacy = """
        {"groups":[{"id":"A","name":"Old","colorIndex":1,
          "members":[{"bundleID":"x","title":"t"}]}]}
        """
        guard let old = try? JSONDecoder().decode(PersistedState.self, from: Data(legacy.utf8))
        else { return check("a file predating the cycling settings decodes", false) }
        check("a file predating the cycling settings decodes", old.groups.count == 1)
        check("its group survives", old.groups.first?.members.count == 1)
        check("cycle order defaults to recency", old.cycleOrder == .recentlyUsed)
        check("app cycling defaults to staying in the group", old.appCycleStaysInGroup)
        check("pill scoping defaults on", old.cycleWithinPill)

        // An unknown raw value must fall back, not fail the file — the shape that
        // once wiped every group.
        let future = """
        {"groups":[{"id":"A","name":"Keep","colorIndex":1,"members":[]}],"cycleOrder":"someLaterMode"}
        """
        let salvaged = try? JSONDecoder().decode(PersistedState.self, from: Data(future.utf8))
        check("an unknown cycle order does not fail the file", salvaged != nil)
        check("groups survive it", salvaged?.groups.first?.name == "Keep")
        check("and it falls back to the default", salvaged?.cycleOrder == .recentlyUsed)
    }

    // MARK: - App stacks

    /// Collapsing one application's windows behind one icon.
    ///
    /// The distinction from clusters is the thing worth protecting: a stack is a
    /// *rule* about an application, so it has to survive its windows closing and
    /// pick up windows opened later without anything being told.
    private static func appStacks() {
        let store = AppStore()
        guard store.groups.count >= 2 else { return check("a group exists", false) }
        let group = store.groups[1].id

        let a = WindowInfo.testInstance(id: 700, bundleID: "com.browser", title: "A")
        let b = WindowInfo.testInstance(id: 701, bundleID: "com.browser", title: "B")
        let c = WindowInfo.testInstance(id: 702, bundleID: "com.browser", title: "C")
        let other = WindowInfo.testInstance(id: 710, bundleID: "com.editor", title: "Editor")
        store.windows = [a, b, c, other]
        store.noteWindowRefs([a, b, c, other])
        for id in [700, 701, 702, 710] { store.add(CGWindowID(id), to: group) }
        store.selectGroup(group)

        check("four loose windows before stacking",
              store.visibleItems.filter { if case .window = $0 { true } else { false } }.count == 4)

        store.stackApp(bundleID: "com.browser", in: group)

        let items = store.visibleItems
        let stacks = items.filter(\.isStack)
        check("the app collapses to one stack", stacks.count == 1, "\(stacks.count)")
        check("the stack holds all three of its windows",
              stacks.first?.windows.count == 3, "\(stacks.first?.windows.count ?? -1)")
        // The other app must be untouched — a stack is scoped to one bundle id.
        check("a different app is not swallowed",
              items.contains { if case .window(let w) = $0 { w.id == 710 } else { false } })

        // A window opened later joins with nothing being told, which is the whole
        // reason this is a rule rather than a list of window ids.
        let d = WindowInfo.testInstance(id: 703, bundleID: "com.browser", title: "D")
        store.windows = [a, b, c, d, other]
        store.noteWindowRefs([a, b, c, d, other])
        store.add(703, to: group)
        check("a window opened later joins the stack automatically",
              store.visibleItems.first(where: \.isStack)?.windows.count == 4)

        // Down to one window it is indistinguishable from an ordinary entry, so
        // it renders as one — but the *rule* survives, or closing windows would
        // silently destroy the stack the way it once destroyed clusters.
        store.windows = [a, other]
        check("a stack of one renders as a plain window",
              !store.visibleItems.contains(where: \.isStack))
        check("but the rule is not destroyed by window churn",
              store.isStacked("com.browser", in: group))
        store.windows = [a, b, c, d, other]
        check("and it re-forms when the windows come back",
              store.visibleItems.contains(where: \.isStack))

        // A clustered window is hand-picked; a stack is a blanket rule. The
        // specific arrangement has to win, or clustering would be undone by
        // stacking the same app.
        store.combine(700, into: 701, in: group)
        let withCluster = store.visibleItems
        check("a cluster survives its app being stacked",
              withCluster.contains(where: \.isCluster))
        check("the stack takes only the windows the cluster left",
              withCluster.first(where: \.isStack)?.windows.count == 2,
              "\(withCluster.first(where: \.isStack)?.windows.count ?? -1)")

        store.unstackApp(bundleID: "com.browser", in: group)
        check("unstacking puts the windows back",
              !store.visibleItems.contains(where: \.isStack))
        check("and clears the rule", !store.isStacked("com.browser", in: group))
    }

    /// What a stack opens, and what its list contains.
    ///
    /// The reported bug: a stack of five Chrome windows in Main opened a Chrome
    /// window that was not in Main at all. The ordering helper re-derived its
    /// members from the bundle id against *every* window, so the badge counted
    /// the group's windows while the click, the hover list and the menu were
    /// working from a different set entirely.
    private static func appStackOpensItsOwnWindows() {
        let store = AppStore()
        guard store.groups.count >= 3 else { return check("two groups exist", false) }
        let main = store.groups[1].id
        let elsewhere = store.groups[2].id

        let inMain = (1...3).map { i in
            WindowInfo.testInstance(id: CGWindowID(900 + i), bundleID: "com.browser",
                                    title: "Main \(i)", pid: 3)
        }
        let outside = WindowInfo.testInstance(id: 950, bundleID: "com.browser",
                                              title: "Elsewhere", pid: 3)
        store.windows = inMain + [outside]
        store.noteWindowRefs(store.windows)
        for w in inMain { store.add(w.id, to: main) }
        store.add(950, to: elsewhere)
        store.selectGroup(main)
        store.pillView = false
        store.stackApp(bundleID: "com.browser", in: main)

        guard let stack = store.visibleItems.first(where: \.isStack) else {
            return check("the stack forms", false)
        }
        check("the stack holds only the group's windows",
              stack.windows.map(\.id).sorted() == [901, 902, 903],
              "\(stack.windows.map(\.id))")

        // The window outside the group is the most recently focused, so a helper
        // that ignored the group would put it first — and clicking the tile would
        // open it.
        store.focusedWindowID = 901
        store.focusedWindowID = 950

        let ordered = store.stackWindowsByRecency(stack.windows)
        check("the stack's order never leaves the group",
              !ordered.contains { $0.id == 950 }, "\(ordered.map(\.id))")
        check("and it opens one of its own windows",
              ordered.first.map { [901, 902, 903].contains(Int($0.id)) } == true,
              "\(ordered.first?.id ?? 0)")
        check("with the most recent of them leading",
              ordered.first?.id == 901, "\(ordered.map(\.id))")
        check("every member is offered", ordered.count == 3, "\(ordered.count)")
    }

    /// Stacking must not shove the icon to the end of the row.
    ///
    /// `applyManualOrder` sends any key it does not rank to the end, so a
    /// brand-new `s<bundle>` key would drop the stack to the far right the
    /// instant it was made — the same trap that would have condemned hidden pins
    /// to the end of the row on the first drag.
    private static func appStackOrdering() {
        let store = AppStore()
        guard store.groups.count >= 2 else { return check("a group exists", false) }
        let group = store.groups[1].id

        let first = WindowInfo.testInstance(id: 800, bundleID: "com.editor", title: "Editor")
        let a = WindowInfo.testInstance(id: 801, bundleID: "com.browser", title: "A")
        let b = WindowInfo.testInstance(id: 802, bundleID: "com.browser", title: "B")
        let last = WindowInfo.testInstance(id: 803, bundleID: "com.mail", title: "Mail")
        store.windows = [first, a, b, last]
        store.noteWindowRefs([first, a, b, last])
        for id in [800, 801, 802, 803] { store.add(CGWindowID(id), to: group) }
        store.selectGroup(group)
        store.setOrder(["w800", "w801", "w802", "w803"], in: group)

        // The state file carries over from the previous case, which stacks this
        // same bundle id in this same group — and `stackApp` returns early when
        // the rule is already there, so the arrangement below would never be
        // seeded and this test would fail for a reason that is not its subject.
        // Assert the precondition rather than assume it: a stack test once
        // passed while stacking nothing at all.
        store.unstackApp(bundleID: "com.browser", in: group)
        check("this case starts unstacked", !store.isStacked("com.browser", in: group))

        store.stackApp(bundleID: "com.browser", in: group)
        check("the stack takes its leftmost member's place",
              store.order(in: group) == ["w800", "scom.browser", "w803"],
              "\(store.order(in: group))")
        check("and draws in that position",
              store.visibleItems.map(\.orderKey) == ["w800", "scom.browser", "w803"],
              "\(store.visibleItems.map(\.orderKey))")

        store.unstackApp(bundleID: "com.browser", in: group)
        check("unstacking restores the members to that position",
              store.order(in: group) == ["w800", "w801", "w802", "w803"],
              "\(store.order(in: group))")

        // A window of the same app that is *not* a member of this group must not
        // get a key in this group's arrangement. It never renders, so the damage
        // is silent: the dead keys simply accumulate in the persisted order, one
        // more on every unstack.
        let outsider = WindowInfo.testInstance(id: 804, bundleID: "com.browser", title: "Outside")
        store.windows = [first, a, b, last, outsider]
        store.noteWindowRefs([first, a, b, last, outsider])
        store.stackApp(bundleID: "com.browser", in: group)
        store.unstackApp(bundleID: "com.browser", in: group)
        check("a non-member window of the same app stays out of the arrangement",
              !store.order(in: group).contains("w804"),
              "\(store.order(in: group))")
    }

    /// A stacked app's launcher must still stand aside, and its windows must stop
    /// competing for titles.
    private static func appStackInteractions() {
        let store = AppStore()
        guard store.groups.count >= 2 else { return check("a group exists", false) }
        let group = store.groups[1].id

        let a = WindowInfo.testInstance(id: 900, bundleID: "com.browser", title: "A")
        let b = WindowInfo.testInstance(id: 901, bundleID: "com.browser", title: "B")
        store.windows = [a, b]
        store.noteWindowRefs([a, b])
        store.add(900, to: group); store.add(901, to: group)
        store.selectGroup(group)
        store.stackApp(bundleID: "com.browser", in: group)

        // `pins(alongside:)` hides a launcher whose app has a window here. A
        // stack reports its windows precisely so that rule keeps working — a
        // launcher drawn beside the very windows it would have opened is the
        // duplicate that rule exists to prevent.
        store.pinApp(bundleID: "com.browser", in: group)
        let items = store.visibleItems
        check("a stacked app's launcher still stands aside",
              !items.contains { if case .pinned = $0 { true } else { false } })

        // Titles disambiguate *loose* windows of one app. Stacked windows are
        // already behind one icon, so they must stop inflating that count.
        let layout = DeckLayout.compute(
            items: items, pinnedCount: 0, titlesEnabled: true,
            maxWidth: 1280, pillCount: 0, sectionCount: 1
        )
        check("stacked windows do not force titles",
              !layout.slots.contains { $0.showsTitle })
    }

    /// Adding a field is the safe kind of persistence change — but "safe" has
    /// been wrong before, so assert both directions: the new key round-trips, and
    /// a file written before it existed still decodes with everything intact.
    private static func appStackPersistence() {
        var state = PersistedState()
        state.groups = [PersistedGroup(id: UUID().uuidString, name: "Main",
                                       colorIndex: 0, members: [],
                                       stackedAppBundleIDs: ["com.browser", "com.editor"])]
        state.allGroupStackedBundleIDs = ["com.mail"]
        guard let data = try? JSONEncoder().encode(state),
              let back = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return check("app stacks round-trip", false) }

        check("a group's stacks round-trip",
              back.groups.first?.stackedAppBundleIDs.sorted() == ["com.browser", "com.editor"])
        check("All's stacks round-trip", back.allGroupStackedBundleIDs == ["com.mail"])

        // A file from before the feature. The groups in it are the thing that
        // must not be lost — a strict decode of one unknown-shaped field is what
        // wiped a full session of them once.
        let legacy = """
        {"groups":[{"id":"\(UUID().uuidString)","name":"Old","colorIndex":1,
          "members":[{"bundleID":"com.a","title":"T"}],"order":[],"clusters":[],
          "pinnedAppBundleIDs":["com.pinned"]}]}
        """
        guard let old = try? JSONDecoder().decode(PersistedState.self, from: Data(legacy.utf8))
        else { return check("a file predating app stacks still decodes", false) }
        check("a file predating app stacks still decodes", old.groups.count == 1)
        check("its group survives intact", old.groups.first?.members.count == 1)
        check("its pins survive", old.groups.first?.pinnedAppBundleIDs == ["com.pinned"])
        check("and stacks default to empty rather than failing the file",
              old.groups.first?.stackedAppBundleIDs.isEmpty == true)
    }

    // MARK: - App stack hover

    /// Leaving a stacked tile before the panel appears must cancel it.
    ///
    /// The reported bug: hover the stack briefly, move to another tile, and the
    /// list pops up anyway with the pointer somewhere else. The exit path
    /// recognised its own stack by `model.bundleID`, which is only set once the
    /// panel is *presented* — so during the delay it matched nothing, returned
    /// early, and never cancelled the pending show.
    ///
    /// The timer itself cannot be exercised here: `SelfTest.run` exits before the
    /// run loop turns, so nothing scheduled with `asyncAfter` ever fires. What is
    /// checkable, and is exactly where the bug was, is whether the work item is
    /// still live after the pointer leaves.
    private static func appStackHover() {
        let panel = AppStackPanel()
        let a = WindowInfo.testInstance(id: 1, bundleID: "com.a", title: "A")

        panel.hover(bundleID: "com.a", name: "A", windows: [a],
                    anchor: .zero, entering: true, timings: .defaults)
        check("hovering a stack schedules the panel", panel.hasPendingShowForTesting)

        panel.hover(bundleID: "com.a", name: "A", windows: [a],
                    anchor: .zero, entering: false, timings: .defaults)
        check("leaving before it appears cancels it", !panel.hasPendingShowForTesting)

        // Sliding from one stack straight onto another: SwiftUI delivers the new
        // tile's enter before the old tile's exit, so the stale exit must not
        // cancel the work just scheduled for the new one. Over-cancelling here
        // would make the second stack never open — the mirror of the bug above,
        // and the reason the guard cannot simply be removed.
        panel.hover(bundleID: "com.a", name: "A", windows: [a],
                    anchor: .zero, entering: true, timings: .defaults)
        panel.hover(bundleID: "com.b", name: "B", windows: [a],
                    anchor: .zero, entering: true, timings: .defaults)
        panel.hover(bundleID: "com.a", name: "A", windows: [a],
                    anchor: .zero, entering: false, timings: .defaults)
        check("a stale exit leaves the newer stack's panel scheduled",
              panel.hasPendingShowForTesting)

        panel.hide()
        check("hiding clears anything pending", !panel.hasPendingShowForTesting)

        // Warmth is shared with the window preview, because it describes the
        // strip and not one panel. Sliding along the bar is instant tile after
        // tile; arriving at a stacked app used to stall for the full delay,
        // which reads as the stack being broken rather than as a deliberate wait.
        StripWarmth.shared.hold("selftest")
        check("the strip reports itself warm", StripWarmth.shared.isWarm)
        panel.hover(bundleID: "com.c", name: "C", windows: [a],
                    anchor: .zero, entering: true, timings: .defaults)
        check("a warm strip shows a stack with no wait", !panel.hasPendingShowForTesting)
        check("and it is actually on screen", panel.isVisible)

        panel.hide()
        StripWarmth.shared.release("selftest", staying: 0)
        check("released warmth goes cold", !StripWarmth.shared.isWarm)

        // Cold again: the delay is back, or a pointer merely crossing the bar
        // would fire a panel at every stacked app it passed.
        panel.hover(bundleID: "com.d", name: "D", windows: [a],
                    anchor: .zero, entering: true, timings: .defaults)
        check("a cold strip waits before showing", panel.hasPendingShowForTesting)
        panel.hide()

        // A zero linger is the setting that exposed the seam between the two
        // panels: warmth has to last as long as something is actually on
        // screen, whatever the linger is set to. Releasing when the pointer
        // left the tile — while the list was still up for its grace period —
        // handed the answer to that setting, and the next tile waited the full
        // delay with a panel visibly in front of it.
        var noLinger = HoverTimings.defaults
        noLinger.warmWindow = 0
        StripWarmth.shared.hold("selftest")
        panel.hover(bundleID: "com.e", name: "E", windows: [a],
                    anchor: .zero, entering: true, timings: noLinger)
        check("a warm strip shows it at once with no linger set", panel.isVisible)
        StripWarmth.shared.release("selftest", staying: 0)
        check("the visible stack is itself what keeps the strip warm",
              StripWarmth.shared.isWarm)
        panel.hover(bundleID: "com.e", name: "E", windows: [a],
                    anchor: .zero, entering: false, timings: noLinger)
        check("leaving the tile stays warm while the panel is still on screen",
              StripWarmth.shared.isWarm)
        panel.hide()
        check("warmth ends with the panel when nothing lingers",
              !StripWarmth.shared.isWarm)

        // Resting on a row peeks that window full size, which is the stage the
        // list was missing: a stacked app's windows are the ones a thumbnail
        // serves worst, since they share an application and often a title.
        let b = WindowInfo.testInstance(id: 2, bundleID: "com.a", title: "B")
        let hidden = WindowInfo.testInstance(id: 3, bundleID: "com.a", title: "C",
                                             isMinimized: true)
        panel.mode = .thumbnailAndPeek
        panel.rowHoverForTesting(a, entering: true)
        check("resting on a row schedules a peek", panel.hasPendingPeekForTesting)

        // Sliding to the next row: SwiftUI delivers the new row's enter first,
        // so the stale exit must leave the newer row's peek alone — the same
        // ordering that governs the tiles on the strip.
        panel.rowHoverForTesting(b, entering: true)
        panel.rowHoverForTesting(a, entering: false)
        check("a stale row exit leaves the newer row's peek scheduled",
              panel.hasPendingPeekForTesting)
        panel.rowHoverForTesting(b, entering: false)
        check("leaving the row it was scheduled for cancels the peek",
              !panel.hasPendingPeekForTesting)

        // A minimised window has no rectangle on screen to draw over, so there
        // is nothing the illusion could be placed at.
        panel.rowHoverForTesting(hidden, entering: true)
        check("a minimised row schedules nothing", !panel.hasPendingPeekForTesting)

        // Off means off: the peek stage is a permission-hungry escalation and
        // the setting has to reach this panel too, not just the window preview.
        panel.mode = .thumbnail
        panel.rowHoverForTesting(a, entering: true)
        check("the peek stage honours the preview mode", !panel.hasPendingPeekForTesting)
        panel.mode = .thumbnailAndPeek
        panel.hide()
    }

    // MARK: - Diagnostics log

    /// The log has the same containment requirement as the state file: a
    /// self-test that wrote into the real log directory would interleave
    /// fabricated lines with a live session's, and the log's whole value is
    /// being trustworthy after the fact.
    private static func tracing() {
        let expected = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WINDOWDECK_STATE_DIR"]!)
            .appendingPathComponent("logs")
        check("log directory follows WINDOWDECK_STATE_DIR",
              Trace.directory.standardizedFileURL == expected.standardizedFileURL,
              Trace.directory.path)
        check("log is not in the real Application Support directory",
              !Trace.directory.path.contains("Application Support/WindowDeck"))

        // Level gating is what keeps `.debug` — which includes a line per rebind
        // decision — from being written during ordinary use. Assert both sides:
        // a test that only proved the kept line survives would pass with the
        // gate removed entirely.
        let marker = "selftest-marker-\(UUID().uuidString)"
        Trace.minimumLevel = .info
        Trace.log(.app, "kept \(marker)")
        Trace.debug(.app, "dropped \(marker)")
        Trace.flushForTesting()

        let contents = (try? String(contentsOf: Trace.logURL, encoding: .utf8)) ?? ""
        check("an info line reaches the file", contents.contains("kept \(marker)"))
        check("a debug line is dropped below its level", !contents.contains("dropped \(marker)"))

        Trace.minimumLevel = .debug
        Trace.debug(.app, "verbose \(marker)")
        Trace.flushForTesting()
        let after = (try? String(contentsOf: Trace.logURL, encoding: .utf8)) ?? ""
        check("raising the level admits debug lines", after.contains("verbose \(marker)"))
        Trace.minimumLevel = .info
    }

    // MARK: - Menu icon memoisation

    /// `NSImage.menuSized` rasterises a fresh bitmap every access, and
    /// `groupWithTargets` asks for one per candidate window per tile per redraw
    /// — N-squared, and once measured at 46% of the app's idle CPU. The cache is
    /// what stops that, so assert it actually returns the *same* instance rather
    /// than merely an equal-looking image.
    private static func menuIconCaching() {
        let finder = NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == "com.apple.finder" }
        // A green test that asserted nothing has happened here before: without a
        // real running app there is no icon to cache and every check below would
        // pass vacuously.
        guard let pid = finder?.processIdentifier else {
            return check("Finder is running, so there is an icon to cache", false)
        }
        IconCache.forget(pid: pid)

        guard let first = IconCache.menuIcon(pid: pid) else {
            return check("a running app yields a menu icon", false)
        }
        check("menu icon is scaled to 16pt", first.size == NSSize(width: 16, height: 16))

        let second = IconCache.menuIcon(pid: pid)
        check("menu icon is memoised, not re-rasterised", second === first)

        IconCache.forget(pid: pid)
        let third = IconCache.menuIcon(pid: pid)
        check("forgetting a pid drops its menu icon too", third !== first)
    }

    // MARK: - Where a new window lands

    private static func capturing() {
        let store = AppStore()
        guard store.groups.count >= 3 else { return check("two groups exist", false) }
        let working = store.groups[1].id     // where you are actually working
        let other = store.groups[2].id       // an app's window living elsewhere

        let mine = WindowInfo.testInstance(id: 100, bundleID: "com.editor", title: "Working here")
        let theirs = WindowInfo.testInstance(id: 101, bundleID: "com.sheets", title: "Elsewhere")
        store.windows = [mine, theirs]
        store.noteWindowRefs([mine, theirs])
        store.add(100, to: working)
        store.add(101, to: other)

        // Viewing a named group is unambiguous: it wins outright.
        store.selectGroup(working)
        check("a named group on screen decides it",
              store.captureTargets(focusHint: 101) == [working])

        // In All, focus decides — and focus that only just changed is treated as
        // the app being activated rather than as where you were working.
        store.selectGroup(store.groups[0].id)
        store.focusedWindowID = 100                 // settled: you were here
        store.settleFocusForTesting(100)
        store.focusedWindowID = 101                 // just now raised by a launch
        check("a window that just took focus is not trusted",
              store.captureTargets(focusHint: 101) == [working],
              "\(store.captureTargets(focusHint: 101))")

        // But a window you have genuinely been using is.
        store.settleFocusForTesting(101)
        check("a settled window is trusted",
              store.captureTargets(focusHint: 101) == [other])

        // A settled window that belongs to nothing means "no target", not "keep
        // looking". The walk used to continue past it into `mruOrder`, which
        // holds the whole session, so a new window was filed by arbitrarily old
        // history and nothing was ever left unfiled.
        let loose = WindowInfo.testInstance(id: 102, bundleID: "com.reader", title: "Unfiled")
        store.windows = [mine, theirs, loose]
        store.noteWindowRefs([mine, theirs, loose])
        store.focusedWindowID = 102
        store.settleFocusForTesting(102)
        check("a settled but ungrouped window stops the walk",
              store.captureTargets(focusHint: 102).isEmpty,
              "\(store.captureTargets(focusHint: 102))")
    }

    /// A window the server reports as *created* must not be re-claimed by the
    /// appeared path, which carries no capture intent. The created path refuses
    /// a foreign group's stale slot; without the exclusion the very next call
    /// handed the window over anyway.
    ///
    /// The frames matter: `sharesFrame` is what makes the claim possible, and an
    /// earlier version of this test left them nil, so it passed while proving
    /// nothing — the claim could never have happened either way.
    private static func appearedExcludesCreated() {
        let rect = CGRect(x: 100, y: 100, width: 757, height: 559)

        func scenario(excludeCreated: Bool) -> AppStore {
            let store = AppStore()
            guard store.groups.count >= 3 else { return store }
            let relic = store.groups[2].id

            let dead = WindowInfo.testInstance(id: 200, bundleID: "com.browser",
                                               title: "Old tab", frame: rect)
            let here = WindowInfo.testInstance(id: 201, bundleID: "com.editor",
                                               title: "Working here", frame: rect)
            store.windows = [dead, here]
            store.noteWindowRefs([dead, here])
            store.add(200, to: relic)

            store.rebindAppearedWindows()          // baseline of what is visible
            store.windows = [here]                 // the relic's window closes
            store.rebindAppearedWindows()

            // A brand-new window of the same app, same size, arrives.
            let fresh = WindowInfo.testInstance(id: 202, bundleID: "com.browser",
                                                title: "New tab", frame: rect)
            store.windows = [here, fresh]
            store.noteWindowRefs([here, fresh])
            store.rebindAppearedWindows(excluding: excludeCreated ? [202] : [])
            return store
        }

        // The control: without the exclusion the seizure really does happen, so
        // the assertion below is testing something.
        let unguarded = scenario(excludeCreated: false)
        guard unguarded.groups.count >= 3 else { return check("two groups exist", false) }
        check("the seizure is reachable without the exclusion",
              unguarded.isMember(202, of: unguarded.groups[2].id))

        let guarded = scenario(excludeCreated: true)
        check("a created window is not claimed by the appeared path",
              !guarded.isMember(202, of: guarded.groups[2].id))
    }

    /// Switching a tab must only ever reclaim the slot that tab *just* vacated.
    /// Two TextEdit windows of equal size made every other dead same-app slot a
    /// valid match, because `sharesFrame` compares geometry alone — so a tab
    /// switch in one window moved it into whichever group held a stale slot for
    /// the other, sometimes into several groups at once.
    private static func tabSwitchKeepsItsOwnSlot() {
        let store = AppStore()
        guard store.groups.count >= 3 else { return check("two groups exist", false) }
        let mine = store.groups[1].id      // where the tabbed window lives
        let other = store.groups[2].id     // holds a stale slot for the *other* window

        // Both TextEdit windows are exactly the same size — the normal case.
        let rect = CGRect(x: 0, y: 0, width: 757, height: 559)
        let tabA = WindowInfo.testInstance(id: 300, bundleID: "com.textedit",
                                           title: "Notes", frame: rect)
        let windowB = WindowInfo.testInstance(id: 301, bundleID: "com.textedit",
                                              title: "Draft", frame: rect)
        store.windows = [tabA, windowB]
        store.noteWindowRefs([tabA, windowB])
        store.add(300, to: mine)
        store.add(301, to: other)
        store.rebindAppearedWindows()

        // Window B closes, leaving a stale slot in `other`. Then a tab switch in
        // the first window: 300 goes off screen, 302 comes on at the same rect.
        //
        // `noteWindowRefs` on each pass because that is what the app does — it
        // was moved outside the equality guard precisely so every tick refreshes
        // `lastSeenAt` and `lastFrameOf`. Without it here both dead slots carry
        // the same timestamp and the most-recently-seen tiebreak has nothing to
        // work with, which is a defect in the fixture, not in the rule.
        store.windows = [tabA]
        store.noteWindowRefs([tabA])
        store.rebindAppearedWindows()

        let tabB = WindowInfo.testInstance(id: 302, bundleID: "com.textedit",
                                           title: "Shopping list", frame: rect)
        store.windows = [tabB]
        store.noteWindowRefs([tabB])
        store.rebindAppearedWindows()

        check("the arriving tab keeps its own group", store.isMember(302, of: mine))
        check("the arriving tab does not join the other window's group",
              !store.isMember(302, of: other),
              "302 is in \(store.groupsContaining(302).count) group(s)")
    }

    /// A new window is usually *not* in `windows` on the tick it is reported
    /// created — Accessibility describes it a beat later. It therefore appears on
    /// the following tick, when `created` is empty, and the appeared path (which
    /// carries no capture intent) claimed it for whatever group held a stale slot.
    private static func lateDescribedWindowKeepsIntent() {
        let store = AppStore()
        guard store.groups.count >= 3 else { return check("two groups exist", false) }
        let relic = store.groups[2].id
        let rect = CGRect(x: 40, y: 40, width: 757, height: 559)

        let dead = WindowInfo.testInstance(id: 600, bundleID: "com.browser",
                                           title: "New Tab", frame: rect)
        let here = WindowInfo.testInstance(id: 601, bundleID: "com.editor",
                                           title: "Working here", frame: rect)
        store.windows = [dead, here]
        store.noteWindowRefs([dead, here])
        store.add(600, to: relic)
        store.rebindAppearedWindows()

        store.windows = [here]                  // the relic's window closes
        store.rebindAppearedWindows()

        // Tick N: the server reports 602 created, but AX has not described it yet
        // so it is absent from `windows`.
        store.rebindAppearedWindows(excluding: [602])

        // Tick N+1: it is described, and `created` is empty this time.
        let fresh = WindowInfo.testInstance(id: 602, bundleID: "com.browser",
                                            title: "New Tab", frame: rect)
        store.windows = [here, fresh]
        store.noteWindowRefs([here, fresh])
        store.rebindAppearedWindows()

        check("a late-described new window is not seized by a relic group",
              !store.isMember(602, of: relic),
              "602 is in \(store.groupsContaining(602).count) group(s)")
    }

    /// A window coming into view with nothing recently vacated has no slot to
    /// inherit. The restriction used to be inferred from `vanished` being empty,
    /// which silently meant "any dead slot, in every group" — reachable just by
    /// returning from a fullscreen app.
    ///
    /// Pins the behaviour, not one mechanism: two things now enforce it (the
    /// early-out in `rebindAppearedWindows` and the candidate pool in
    /// `rebindReopenedWindows`), so removing either alone leaves this passing.
    /// Measured, not assumed.
    private static func arrivalWithNothingVacated() {
        let store = AppStore()
        guard store.groups.count >= 3 else { return check("two groups exist", false) }
        let a = store.groups[1].id
        let b = store.groups[2].id
        let rect = CGRect(x: 10, y: 10, width: 900, height: 600)

        let ghostA = WindowInfo.testInstance(id: 700, bundleID: "com.app", title: "Doc", frame: rect)
        let anchor = WindowInfo.testInstance(id: 701, bundleID: "com.other", title: "Anchor", frame: rect)
        store.windows = [ghostA, anchor]
        store.noteWindowRefs([ghostA, anchor])
        store.add(700, to: a)
        store.add(700, to: b)
        store.rebindAppearedWindows()

        // 700 closes and its disappearance ages out of the grace window.
        store.windows = [anchor]
        store.rebindAppearedWindows()
        store.forgetArrivalsForTesting()

        // Now a window appears with nothing having vanished alongside it.
        let arriving = WindowInfo.testInstance(id: 702, bundleID: "com.app", title: "Doc", frame: rect)
        store.windows = [anchor, arriving]
        store.noteWindowRefs([anchor, arriving])
        store.rebindAppearedWindows()

        check("an arrival with nothing vacated claims nothing",
              store.groupsContaining(702).isEmpty,
              "702 is in \(store.groupsContaining(702).count) group(s)")
    }

    /// A folded group is absent from `sections`, so seeding a fresh arrangement
    /// from there gave it an empty row and the first drag did nothing visible
    /// while persisting a one-entry order.
    private static func reorderingInsideAFoldedGroup() {
        let store = AppStore()
        guard store.groups.count >= 2 else { return check("a group exists", false) }
        let group = store.groups[1].id

        let one = WindowInfo.testInstance(id: 800, bundleID: "com.a", title: "One")
        let two = WindowInfo.testInstance(id: 801, bundleID: "com.b", title: "Two")
        let three = WindowInfo.testInstance(id: 802, bundleID: "com.c", title: "Three")
        store.windows = [one, two, three]
        store.noteWindowRefs([one, two, three])
        for w in [one, two, three] { store.add(w.id, to: group) }
        store.setCollapsed(true, for: group)

        store.moveItem("w800", before: "w802", in: group)
        let order = store.order(in: group)
        check("a folded group seeds a full arrangement", order.count >= 3, "\(order)")
        check("the drag actually moved the item",
              order.firstIndex(of: "w800") ?? 0 > (order.firstIndex(of: "w801") ?? 0),
              "\(order)")
    }

    // MARK: - The all-groups panel

    /// The panel lists a group's windows in that group's own arrangement, so a
    /// drag there means the same thing as a drag in the strip.
    private static func allGroupsRowOrdering() {
        let a = WindowInfo.testInstance(id: 1, bundleID: "com.a", title: "A")
        let b = WindowInfo.testInstance(id: 2, bundleID: "com.b", title: "B")
        let c = WindowInfo.testInstance(id: 3, bundleID: "com.c", title: "C")

        let arranged = AllGroupsModel.ordered([a, b, c], by: ["w3", "w1", "w2"])
        check("the group's arrangement decides the row",
              arranged.map(\.id) == [3, 1, 2],
              "\(arranged.map(\.id))")

        // A group with no arrangement yet must keep the order it was given.
        //
        // Be clear about what this does and does not prove: `sorted(by:)` is not
        // *documented* as stable, which is why `ordered` carries an index
        // tiebreak — but the current implementation is stable in practice, at 3
        // elements and at 40. Deleting the tiebreak does not make this check
        // fail on this toolchain. It is kept as a guard against a future sort
        // that honours the documented contract, and this check pins the
        // behaviour we need rather than the mechanism that provides it.
        let many = (1...40).map {
            WindowInfo.testInstance(id: CGWindowID($0), bundleID: "com.many", title: "W\($0)")
        }
        let unarranged = AllGroupsModel.ordered(many, by: [])
        check("no arrangement keeps the input order",
              unarranged.map(\.id) == many.map(\.id),
              "\(unarranged.prefix(6).map(\.id))…")

        // A window the arrangement does not mention sorts last, and ties among
        // such windows keep their relative order.
        let partial = AllGroupsModel.ordered([a, b, c], by: ["w3"])
        check("unarranged windows follow, in order",
              partial.map(\.id) == [3, 1, 2],
              "\(partial.map(\.id))")
    }

    // MARK: - Pruning

    private static func pruning() {
        let store = AppStore()
        guard store.groups.count >= 2 else { return check("a group exists", false) }
        let group = store.groups[1].id

        // One member of an app that is genuinely running, one of an app that is
        // not. Only the second may be dropped.
        let realBundle = "com.apple.finder"
        let live = WindowInfo.testInstance(id: 40, bundleID: realBundle, title: "Live")
        let ghostReal = WindowInfo.testInstance(id: 41, bundleID: realBundle, title: "Closed")
        let ghostGone = WindowInfo.testInstance(id: 42, bundleID: "com.nonexistent.app", title: "Gone")
        store.windows = [live, ghostReal, ghostGone]
        store.noteWindowRefs([live, ghostReal, ghostGone])
        store.add(40, to: group); store.add(41, to: group); store.add(42, to: group)

        // Only the first is still open.
        store.windows = [live]
        store.sampleRunningApps(windowOwnerPIDs: [], force: true)
        store.forcePruneForTesting()

        check("a live member is never pruned", store.isMember(40, of: group))
        check("a closed window of a running app is kept", store.isMember(41, of: group))
        check("a closed window of a quit app is dropped", !store.isMember(42, of: group))

        // Duplicated restore references collapse; distinct ones do not.
        let index = store.groups.firstIndex { $0.id == group }!
        store.groups[index].savedMembers = [
            MemberRef(bundleID: "com.a", title: "Same", windowID: 1),
            MemberRef(bundleID: "com.a", title: "Same", windowID: 2),
            MemberRef(bundleID: "com.a", title: "Same", windowID: 3),
            MemberRef(bundleID: "com.a", title: "Different", windowID: 4)
        ]
        store.forcePruneForTesting()
        let saved = store.groups[index].savedMembers
        check("identical references collapse to one",
              saved.filter { $0.title == "Same" }.count == 1, "\(saved.count)")
        check("a different document is kept",
              saved.contains { $0.title == "Different" })
    }

    // MARK: - Restoring

    private static func restoring() {
        let store = AppStore()
        guard store.groups.count >= 2 else { return check("a group exists", false) }
        let index = store.groups.firstIndex { !$0.isAll }!
        let group = store.groups[index].id

        store.groups[index].savedMembers = [
            MemberRef(bundleID: "com.x", title: "Exact", windowID: 500),
            MemberRef(bundleID: "com.y", title: "Report.docx", windowID: nil),
            MemberRef(bundleID: "com.z", title: "Never comes back", windowID: nil)
        ]

        // Same id, different title — the id must win.
        let byID = WindowInfo.testInstance(id: 500, bundleID: "com.x", title: "Title has changed")
        // Different id, title decorated — loose matching must catch it.
        let byLoose = WindowInfo.testInstance(id: 501, bundleID: "com.y", title: "Merging: Report.docx")
        let windows = [byID, byLoose]
        store.windows = windows
        store.noteWindowRefs(windows)

        let claimed = store.restorePass(against: windows)
        check("window id beats a changed title", store.isMember(500, of: group))
        check("loose title match recovers a decorated title", store.isMember(501, of: group))
        check("restore reports what it claimed", claimed.contains(500) && claimed.contains(501))
        check("an absent window stays queued",
              store.groups[index].savedMembers.contains { $0.title == "Never comes back" })
        check("a matched reference is consumed",
              !store.groups[index].savedMembers.contains { $0.title == "Exact" })
    }

    // MARK: - Layout

    private static func layout() {
        let windows = (1...40).map { WindowInfo.testInstance(id: CGWindowID($0), bundleID: "com.x", title: "W\($0)") }
        let items = windows.map { DeckItem.window($0) }
        let result = DeckLayout.compute(items: items, pinnedCount: 0,
                                        titlesEnabled: true, maxWidth: 1240)
        check("layout never exceeds the display", result.totalWidth <= 1240,
              "\(result.totalWidth)")
        let content = result.slots.reduce(0) { $0 + $1.width }
            + CGFloat(max(result.slots.count - 1, 0)) * result.spacing
        check("content fits inside the panel", content <= 1240, "\(content)")
        check("every window gets a slot", result.slots.count == items.count)

        let pilled = DeckLayout.compute(items: items, pinnedCount: 0,
                                        titlesEnabled: true, maxWidth: 1240, pillCount: 5)
        check("capsules are charged to the budget", pilled.totalWidth <= 1240)
    }
}
