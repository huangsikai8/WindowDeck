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

    /// A store with Main and two named capsules, from an empty state file.
    ///
    /// Cases used to inherit whatever the previous one saved — every `AppStore()`
    /// reads the same file — and that leaked twice in ways that made a case
    /// silently measure something other than what it claimed. Starting each case
    /// from nothing costs one file delete and removes the whole class of bug.
    /// Safe because `run()` refuses to start without `WINDOWDECK_STATE_DIR`.
    private static func freshStore(_ names: [String] = ["Work", "Study"]) -> AppStore {
        try? FileManager.default.removeItem(at: StateStore.fileURL)
        try? FileManager.default.removeItem(at: StateStore.backupURL)
        // Seeded with this boot's time, which is what a live session's file
        // always carries. Restore only trusts a saved window id when the file
        // was written during the same boot — ids mean nothing across one — so a
        // store built from *nothing* cannot exercise id matching at all.
        var seed = PersistedState()
        seed.bootTime = AppStore.systemBootTime
        StateStore.save(seed)
        let store = AppStore()
        for name in names { store.addGroup(named: name) }
        return store
    }

    /// What one capsule draws. The strip is a row of these now, so a case that
    /// used to ask for "the items on screen" names the capsule it means.
    private static func items(_ store: AppStore, in groupID: UUID) -> [DeckItem] {
        store.sections(includingCollapsed: true).first { $0.groupID == groupID }?.items ?? []
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
        newWindowSitsBesideItsApp()
        matching()
        membership()
        sections()
        layout()
        sectionsWithWindows()
        clustering()
        clusterSurvivesClosing()
        edgeCases()
        runningState()
        closedWindowLauncher()
        launcherIsUniqueAndStaysPut()
        launcherRegressions()
        activeCapsuleTracking()
        activationRaiseIsNotIntent()
        newWindowPlacement()
        twoInstancesOfOneApp()
        menuIconCaching()
        capturing()
        aDeadSlotNeverClaimsANewWindow()
        reorderingInsideAFoldedGroup()
        allGroupsRowOrdering()
        pruning()
        restoring()
        cyclingByRecency()
        cyclingByStripOrder()
        cyclingStartIndex()
        cyclingAppScope()
        cyclingAcrossTwoGroups()
        cyclingScopedToCapsule()
        cyclingPersistence()
        appStacks()
        appStackOpensItsOwnWindows()
        appStackOrdering()
        appStackOrderSurvivesRelaunch()
        appStackInteractions()
        appStackPersistence()
        appStackHover()
        switchEntries()
        deckSizing()
        deckSizePersistence()
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
        let data = try? JSONEncoder().encode(state)
        let back = data.flatMap { try? JSONDecoder().decode(PersistedState.self, from: $0) }
        check("round trip keeps custom colour", back?.groups.first?.customColorHex == "FF8800")
        check("round trip keeps window id", back?.groups.first?.members.first?.windowID == 42)

        check("hex parses", Color(hex: "FF8800") != nil)
        check("bad hex is rejected", Color(hex: "nope") == nil)

        migration()
    }

    /// Bringing an old file up to the one-capsule-per-window model.
    ///
    /// Every one of these is a way a user's groups could quietly be lost or
    /// duplicated on the first launch after the change, which is the most
    /// expensive thing this app can do.
    private static func migration() {
        // A file from before Main existed: the retired All group's arrangement,
        // launchers and clusters lived outside `groups`, and a window could be
        // filed in several groups at once.
        let old = """
        {"groups":[
          {"id":"M","name":"Main","colorIndex":1,"members":[
             {"bundleID":"com.a","title":"one"},{"bundleID":"com.b","title":"two"}]},
          {"id":"W","name":"Work","colorIndex":2,"members":[{"bundleID":"com.b","title":"two"}]}],
         "allGroupPinnedBundleIDs":["com.apple.finder"],
         "allGroupStackedBundleIDs":["com.google.Chrome"],
         "activeGroupID":"00000000-0000-0000-0000-0000574E4441",
         "pillView":true}
        """
        let migrated = try? JSONDecoder().decode(PersistedState.self, from: Data(old.utf8))
        check("an old file still decodes", migrated != nil)
        check("exactly one group is Main",
              migrated?.groups.filter(\.isMain).count == 1)
        check("the group already called Main is the one adopted",
              migrated?.groups.first?.name == "Main" && migrated?.groups.first?.isMain == true)
        check("Main sorts first", migrated?.groups.first?.isMain == true)

        // The catch-all must lose ties, or every specific capsule empties into it.
        let work = migrated?.groups.first { $0.name == "Work" }
        check("a window filed in both stays with the specific group",
              work?.members.count == 1 && work?.members.first?.title == "two")
        // Main's own list is left alone — it is inert, and the first save drops
        // it. Deleting it during migration would throw away the membership of a
        // group adopted *as* Main because the file named none.
        check("the adopted group keeps its members on disk",
              migrated?.groups.first?.members.count == 2)

        // All's leftovers belong to Main now — losing them would lose every pin.
        check("All's launchers move to Main",
              migrated?.groups.first?.pinnedAppBundleIDs == ["com.apple.finder"])
        check("All's stacks move to Main",
              migrated?.groups.first?.stackedAppBundleIDs == ["com.google.Chrome"])

        // A file with no group called Main at all: the first one is adopted
        // rather than a second Main being invented beside it.
        let noMain = """
        {"groups":[{"id":"A","name":"Alpha","colorIndex":1,"members":[]},
                   {"id":"B","name":"Beta","colorIndex":2,"members":[]}]}
        """
        let adopted = try? JSONDecoder().decode(PersistedState.self, from: Data(noMain.utf8))
        check("a file with no Main adopts its first group",
              adopted?.groups.first?.name == "Alpha" && adopted?.groups.first?.isMain == true)
        check("no extra group is invented", adopted?.groups.count == 2)

        // And an empty file still ends up with somewhere to draw windows.
        let empty = try? JSONDecoder().decode(PersistedState.self, from: Data("{\"groups\":[]}".utf8))
        check("an empty file still yields a Main",
              empty?.groups.count == 1 && empty?.groups.first?.isMain == true)
    }

    // MARK: - Ordering

    private static func ordering() {
        let store = freshStore()
        let group = store.groups.first { !$0.isMain }
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

    /// Where a newly opened window is drawn inside a capsule that already has an
    /// arrangement.
    ///
    /// Nothing mints an order key for a new window — `captureNewWindows` files it
    /// into membership and stops — so it is unranked, and an unranked item used
    /// to be sent to the end of the row. That put a second Finder window at the
    /// far right of the capsule while the first sat wherever the arrangement had
    /// it, and the app's windows scattered as more opened.
    ///
    /// It hides on a fresh install, which is why it lasted: with an *empty* order
    /// the default sort already groups by application, and the arrangement is
    /// only non-empty once the restore pass has rebuilt it from `savedOrder` —
    /// every session after the first.
    private static func newWindowSitsBesideItsApp() {
        let store = freshStore()
        guard store.groups.count >= 2 else { return check("a group exists", false) }
        let group = store.groups[1].id

        let finder = WindowInfo.testInstance(id: 900, bundleID: "com.finder",
                                             title: "Documents", pid: 1)
        let browser = WindowInfo.testInstance(id: 901, bundleID: "com.browser",
                                              title: "Docs", pid: 2)
        let mail = WindowInfo.testInstance(id: 902, bundleID: "com.mail",
                                           title: "Inbox", pid: 3)
        var live = [finder, browser, mail]
        store.windows = live
        store.noteWindowRefs(live)
        for id in [900, 901, 902] { store.add(CGWindowID(id), to: group) }
        store.setOrder(["w900", "w901", "w902"], in: group)
        check("the arrangement is what it was set to",
              items(store, in: group).map(\.orderKey) == ["w900", "w901", "w902"],
              "\(items(store, in: group).map(\.orderKey))")

        // A second Finder window opens. Nothing gives it a key.
        let second = WindowInfo.testInstance(id: 903, bundleID: "com.finder",
                                             title: "Downloads", pid: 1)
        live.append(second)
        store.windows = live
        store.noteWindowRefs(live)
        store.add(903, to: group)
        check("a new window is drawn beside its own app's",
              items(store, in: group).map(\.orderKey) == ["w900", "w903", "w901", "w902"],
              "\(items(store, in: group).map(\.orderKey))")
        check("and nothing is written to the arrangement",
              store.order(in: group) == ["w900", "w901", "w902"],
              "\(store.order(in: group))")

        // A third queues behind the second rather than landing on the same
        // anchor, which is why the search runs over the growing list.
        let third = WindowInfo.testInstance(id: 904, bundleID: "com.finder",
                                            title: "Desktop", pid: 1)
        live.append(third)
        store.windows = live
        store.noteWindowRefs(live)
        store.add(904, to: group)
        check("several new windows of one app keep their order",
              items(store, in: group).map(\.orderKey) == ["w900", "w903", "w904", "w901", "w902"],
              "\(items(store, in: group).map(\.orderKey))")

        // An app with nothing in this capsule has no anchor, and still trails.
        let stranger = WindowInfo.testInstance(id: 905, bundleID: "com.notes",
                                               title: "Notes", pid: 4)
        live.append(stranger)
        store.windows = live
        store.noteWindowRefs(live)
        store.add(905, to: group)
        check("a window with no sibling here still trails",
              items(store, in: group).map(\.orderKey).last == "w905",
              "\(items(store, in: group).map(\.orderKey))")

        // Dropping it somewhere lands it there: a drag names a position, and the
        // affinity only ever speaks for an item the user has not placed. Note
        // what happens to `w904`, which is still unplaced — it follows its
        // sibling to the new position rather than staying beside `w900`,
        // because the anchor is the *last* window of the app on the row. That
        // is the rule working, not a leak: an unarranged window has no position
        // of its own to keep.
        store.moveItem("w903", before: "w902", in: group)
        check("dragging a newly placed window puts it where it was dropped",
              items(store, in: group).map(\.orderKey)
                  == ["w900", "w901", "w903", "w904", "w902", "w905"],
              "\(items(store, in: group).map(\.orderKey))")

        // And an arrangement the user made outranks the affinity outright: two
        // windows of one app deliberately dragged apart stay apart, since both
        // are ranked and neither is the affinity's business.
        store.windows = [finder, browser, mail, second]
        store.setOrder(["w900", "w901", "w902", "w903"], in: group)
        check("windows deliberately arranged apart are not pulled together",
              items(store, in: group).map(\.orderKey) == ["w900", "w901", "w902", "w903"],
              "\(items(store, in: group).map(\.orderKey))")
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
        let store = freshStore()
        guard store.groups.count >= 3 else { return check("two groups exist", false) }
        let main = store.main.id
        let a = store.groups[1].id, b = store.groups[2].id

        // A window nothing claims is in Main, with nothing written down.
        check("an unclaimed window is in Main", store.isMember(5, of: main))
        check("Main holds no membership list", store.main.memberIDs.isEmpty)

        store.add(5, to: a)
        check("added to a group", store.isMember(5, of: a))
        check("and it left Main", !store.isMember(5, of: main))

        store.moveItem("w5", from: a, to: b)
        check("move joins the target", store.isMember(5, of: b))
        check("move leaves the source", !store.isMember(5, of: a))

        // The invariant the whole model rests on: one capsule, never two.
        check("a window is in exactly one capsule",
              store.groups.filter { $0.memberIDs.contains(5) }.count == 1)

        // Dropping into Main is how a window leaves a group.
        store.moveItem("w5", from: b, to: main)
        check("dropping into Main clears the old membership", !store.isMember(5, of: b))
        check("and Main draws it again", store.isMember(5, of: main))
        check("without writing a member id", store.main.memberIDs.isEmpty)

        store.pinApp(bundleID: "com.apple.finder", in: a)
        check("pinned to a group", store.pinnedApps(in: a).contains { $0.bundleID == "com.apple.finder" })
        store.moveItem("pcom.apple.finder", from: a, to: b)
        check("pin moves to the target", store.pinnedApps(in: b).contains { $0.bundleID == "com.apple.finder" })
        check("pin leaves the source", !store.pinnedApps(in: a).contains { $0.bundleID == "com.apple.finder" })
    }

    // MARK: - Sections

    private static func sections() {
        let store = freshStore()
        // With no windows at all there is nothing to draw — an empty capsule is
        // omitted rather than left as a bare outline.
        check("empty groups are omitted", store.sections.isEmpty, "\(store.sections.count)")

        let window = WindowInfo.testInstance(id: 1, bundleID: "com.a", title: "One")
        store.windows = [window]
        check("an unclaimed window puts Main on the strip",
              store.sections.count == 1 && store.sections.first?.groupID == store.main.id)
        check("every section is a capsule", store.sections.allSatisfy(\.isPill))
    }

    // MARK: - Sections with real windows

    private static func sectionsWithWindows() {
        let store = freshStore()
        guard store.groups.count >= 3 else { return check("two groups exist", false) }
        let main = store.main.id
        let a = store.groups[1].id, b = store.groups[2].id

        // A real bundle id: `pinApp` resolves the application on disk and does
        // nothing for one that does not exist, which would make the pin check
        // below pass vacuously.
        let inWork = WindowInfo.testInstance(id: 10, bundleID: "com.apple.finder", title: "Filed")
        let alsoWork = WindowInfo.testInstance(id: 11, bundleID: "com.y", title: "AlsoFiled")
        let loose = WindowInfo.testInstance(id: 12, bundleID: "com.z", title: "Loose")
        store.windows = [inWork, alsoWork, loose]
        store.add(10, to: a); store.add(11, to: a)

        let sections = store.sections
        check("one capsule per non-empty group", sections.count == 2, "\(sections.count)")
        check("Main leads the strip", sections.first?.groupID == main)

        let inA = sections.first { $0.groupID == a }?.items.compactMap { $0.windows.first?.id } ?? []
        let inMain = sections.first { $0.groupID == main }?.items.compactMap { $0.windows.first?.id } ?? []
        check("a filed window is drawn in its own capsule", inA.sorted() == [10, 11], "\(inA)")
        check("an unclaimed window falls to Main", inMain == [12], "\(inMain)")
        check("and is drawn exactly once",
              sections.flatMap { $0.items.flatMap { $0.windows.map(\.id) } }.filter { $0 == 12 }.count == 1)
        check("an empty group draws nothing", !sections.contains { $0.groupID == b })

        // A launcher must stand aside while its app has a window on show —
        // otherwise the same icon appears twice, which is the duplicate the
        // whole pin-hiding rule exists to prevent.
        store.pinApp(bundleID: "com.apple.finder", in: a)
        check("the pin was actually created",
              store.pinnedApps(in: a).contains { $0.bundleID == "com.apple.finder" })
        let pinsInA = store.sections.first { $0.groupID == a }?.items.compactMap(\.launcherBundleID) ?? []
        check("a pin hides while its app has a window here",
              !pinsInA.contains("com.apple.finder"), "\(pinsInA)")

        // The same pin in Main, whose Finder window lives in Work: nothing is
        // standing aside for it there, so it draws.
        store.pinApp(bundleID: "com.apple.finder", in: main)
        let pinsInMain = store.sections.first { $0.groupID == main }?.items.compactMap(\.launcherBundleID) ?? []
        check("a pin draws where its app has no window",
              pinsInMain.contains("com.apple.finder"), "\(pinsInMain)")

        // Slot identities are section-scoped: the same pin is now in two
        // capsules, and two views sharing one identity corrupted the switcher's
        // rendering once already.
        let ids = store.sections.flatMap { section in
            section.items.map { "\(section.id)/\($0.id)" }
        }
        check("slot identities are unique across capsules", Set(ids).count == ids.count)
    }

    // MARK: - Clusters

    private static func clustering() {
        let store = freshStore()
        guard store.groups.count >= 2 else { return check("a group exists", false) }
        let group = store.groups[1].id

        let a = WindowInfo.testInstance(id: 60, bundleID: "com.f", title: "A")
        let b = WindowInfo.testInstance(id: 61, bundleID: "com.f", title: "B")
        store.windows = [a, b]
        store.noteWindowRefs([a, b])
        store.add(60, to: group); store.add(61, to: group)

        // The drag happens inside Work's capsule while focus is somewhere else
        // entirely — which is the case that used to build the cluster in the
        // wrong group, where nothing looks for it.
        store.focusedWindowID = nil
        store.settleFocusForTesting()
        check("the group being acted on is not the active one",
              store.activeGroup.id != group)

        store.combine(60, into: 61, in: group)

        let owner = store.groups.first { $0.id == group }
        check("the cluster is built in the capsule's group",
              owner?.clusters.count == 1, "\(owner?.clusters.count ?? -1)")
        check("Main did not receive the cluster", store.main.clusters.isEmpty)
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
        let store = freshStore()
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

        // Reopened under new ids, which is what the red button produces — and
        // under the one-capsule model *nothing claims it back*. The slot is
        // retained so the launcher can hold its place, but the returning window
        // is an ordinary new window and joins the capsule being worked in.
        //
        // Asserted rather than left implicit because it is a deliberate loss: a
        // cluster decays as its windows are closed and reopened, and a test that
        // only checked the retention would not say so.
        let b2 = WindowInfo.testInstance(id: 311, bundleID: "com.apple.finder", title: "build")
        store.windows = [a, b2]
        store.noteWindowRefs([a, b2])
        check("a reopened window does not silently rejoin its old cluster",
              cluster()?.contains(311) == false,
              "\(cluster()?.memberIDs.sorted() ?? [])")
        check("and the dead slot is still held for the launcher",
              cluster()?.contains(301) == true,
              "\(cluster()?.memberIDs.sorted() ?? [])")

        // Growth is still bounded: once the application is gone the slot goes.
        let orphan = freshStore()
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


    // MARK: - Edges

    private static func edgeCases() {
        let store = freshStore()
        guard let group = store.groups.first(where: { !$0.isMain })?.id else { return }

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
        let store = freshStore()
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

    /// An application still running after its last window was closed with the red
    /// button must keep an icon on the strip, exactly as the Dock keeps one.
    ///
    /// The bug this exists for was two questions disagreeing about "does this app
    /// have a window". `CGWindowList` keeps listing layer-0 windows for an app
    /// whose windows are all closed — measured on ChatGPT: five of them, one
    /// 1280x668, while Accessibility correctly reported none. So `withWindows`
    /// was built from the window server and said "it has windows", which
    /// suppressed the launcher, while the AX pass said "it has none" and drew no
    /// tile. The application vanished from the strip while the real Dock still
    /// showed it.
    ///
    /// **What this covers and what it does not.** The fix was to source
    /// `windowOwnerPIDs` from the sweep rather than from `server.ownerPIDs`, and
    /// that wiring lives in `WindowEngine` behind a live window server and a real
    /// Accessibility client — neither of which the harness has, so a revert of
    /// that one line would *not* fail here. What this pins down is the store rule
    /// the wiring feeds: a pid set claiming windows suppresses the launcher, and
    /// one that does not claim them draws it. Both directions are asserted,
    /// because the "draws it" half passes on its own with the rule deleted.
    private static func closedWindowLauncher() {
        let store = freshStore()
        let main = store.main.id

        // A real running application, since `runningLaunchers` filters on
        // `activationPolicy == .regular` and cannot be fooled with a fixture.
        guard let finder = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == "com.apple.finder" }) else {
            check("Finder is running to stand in for a closed-window app", false)
            return
        }

        // Preconditions, asserted rather than assumed: a pin test once passed
        // while pinning nothing at all.
        store.windows = []
        store.sampleRunningApps(windowOwnerPIDs: [], force: true)
        check("the stand-in app is Dock-worthy",
              store.runningApps.dockApps.contains("com.apple.finder"))
        check("and the strip is describing none of its windows",
              !store.windows.contains { $0.bundleID == "com.apple.finder" })
        check("running-app launchers are enabled", store.showRunningApps)

        // A launcher is born from a transition, so the strip cannot be asked
        // about one until the transition has been processed.
        store.updateLaunchers()
        func drawnInMain() -> Bool {
            items(store, in: main).contains { $0.launcherBundleID == "com.apple.finder" }
        }
        check("an app whose last window was closed keeps its icon", drawnInMain(),
              "\(items(store, in: main).map(\.id))")

        // Sticky, and this is the rule rather than an oversight: a launcher goes
        // when *its own* capsule gets a real window of that application back, and
        // nothing else takes it away. The window server reporting windows for the
        // pid — which happens for windows on another Space, and for the phantom
        // layer-0 windows an application keeps after its last one is closed — is
        // not that, so the icon stays put.
        store.sampleRunningApps(windowOwnerPIDs: [finder.processIdentifier], force: true)
        store.updateLaunchers()
        check("a pid set claiming windows does not remove it", drawnInMain())

        // What does remove it: a window of that application actually drawn here.
        let real = WindowInfo.testInstance(id: 900, bundleID: "com.apple.finder",
                                           title: "Documents", pid: finder.processIdentifier)
        store.windows = [real]
        store.noteWindowRefs([real])
        store.updateLaunchers()
        check("the capsule reclaiming the app removes its launcher", !drawnInMain(),
              "\(items(store, in: main).map(\.id))")

        // And it comes back once that window closes again, so the difference is
        // the window and nothing else.
        store.windows = []
        store.sampleRunningApps(windowOwnerPIDs: [], force: true)
        store.updateLaunchers()
        check("closing it again brings the icon back", drawnInMain())
    }

    /// Where a newly opened window is drawn inside its capsule.
    ///
    /// Beside its own application if that application is already on this row, and
    /// otherwise at the very end. The second half is the part that was broken:
    /// `applyManualOrder` returns early on an empty `order`, so a capsule with no
    /// saved arrangement fell back to the sweep's own sort — by application name —
    /// and a new TextEdit window landed wherever "TextEdit" happened to sort.
    ///
    /// Both halves are asserted, and the empty-arrangement case is asserted with
    /// the incoming window placed *first* in the window list, which is what the
    /// app-name sort would produce. Without that the fixture would pass with the
    /// fix reverted, exactly as the frame-nil fixture once did.
    private static func newWindowPlacement() {
        let store = freshStore()
        guard store.groups.count >= 2 else { return check("a capsule exists", false) }
        let group = store.groups[1].id
        store.endLaunchGraceForTesting()

        func keys() -> [String] { items(store, in: group).map(\.orderKey) }

        // A capsule with no arrangement at all, holding one window. The arriving
        // window's app sorts *before* it, so an app-name sort would draw it left.
        let zoom = WindowInfo.testInstance(id: 400, bundleID: "com.zoom", title: "Zoom", pid: 1)
        store.windows = [zoom]
        store.noteWindowRefs(store.windows)
        store.add(400, to: group)
        check("the capsule starts with no arrangement", store.order(in: group).isEmpty,
              "\(store.order(in: group))")

        let text = WindowInfo.testInstance(id: 401, bundleID: "com.textedit",
                                           title: "Untitled", pid: 2)
        store.windows = [text, zoom]            // as the app-name sort would give it
        store.noteWindowRefs(store.windows)
        store.focusedWindowID = 400
        store.settleFocusForTesting()
        store.captureNewWindows([401], focusHint: 400)
        check("a new app lands at the end even with no arrangement",
              keys() == ["w400", "w401"], "\(keys())")

        // A second window of an application already here goes beside the first,
        // not at the end.
        let text2 = WindowInfo.testInstance(id: 402, bundleID: "com.textedit",
                                            title: "Notes", pid: 2)
        let mail = WindowInfo.testInstance(id: 403, bundleID: "com.mail", title: "Inbox", pid: 3)
        store.windows = [text, text2, zoom, mail]
        store.noteWindowRefs(store.windows)
        store.settleFocusForTesting()
        store.captureNewWindows([403], focusHint: 400)   // a third app, to the end
        store.settleFocusForTesting()
        store.captureNewWindows([402], focusHint: 400)   // beside its sibling
        check("a second window of a known app lands beside it",
              keys() == ["w400", "w401", "w402", "w403"], "\(keys())")

        // A pinned application is not a new one: its window takes the pin's place
        // rather than the end of the row. This is the "provided not pinned" carve
        // out, and without it a pinned app's window would jump to the far right
        // the first time it opened.
        let pinned = freshStore()
        let pinGroup = pinned.groups[1].id
        pinned.endLaunchGraceForTesting()
        let other = WindowInfo.testInstance(id: 410, bundleID: "com.zoom", title: "Zoom", pid: 1)
        pinned.windows = [other]
        pinned.noteWindowRefs(pinned.windows)
        pinned.add(410, to: pinGroup)
        pinned.setOrder(["pcom.finder", "w410"], in: pinGroup)
        let finderWindow = WindowInfo.testInstance(id: 411, bundleID: "com.finder",
                                                   title: "Documents", pid: 4)
        pinned.windows = [other, finderWindow]
        pinned.noteWindowRefs(pinned.windows)
        pinned.focusedWindowID = 410
        pinned.settleFocusForTesting()
        pinned.captureNewWindows([411], focusHint: 410)
        check("a pinned app's window takes the pin's place, not the end",
              pinned.order(in: pinGroup) == ["pcom.finder", "w411", "w410"],
              "\(pinned.order(in: pinGroup))")
    }

    /// The three launcher rules, and the closing order that decides between them.
    ///
    /// One launcher per application, born in the capsule whose window of it
    /// survived longest, and it does not move afterwards. Closing order is what
    /// picks the capsule — it was the first thing asked about this design and it
    /// is the only thing the rules are sensitive to, so it is asserted directly
    /// rather than inferred from a single path.
    /// The regressions a review caught in the launcher rules. Each of these is a
    /// case the rest of the suite cannot reach, and each was a real defect.
    private static func launcherRegressions() {
        guard let finder = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == "com.apple.finder" }) else {
            return check("Finder is running to stand in for a closed-window app", false)
        }
        let pid = finder.processIdentifier

        // A pinned application must not also draw a launcher. `pins(alongside:)`
        // hides a pin behind a live window of its app, but it knows nothing about
        // launchers — so the capsule drew the pin and the launcher as two
        // identical adjacent icons. Worse in Main, where the launcher has no
        // member slot and falls back to `p<bundleID>`, the pin's own order key.
        let store = freshStore()
        let work = store.groups[1].id
        let window = WindowInfo.testInstance(id: 920, bundleID: "com.apple.finder",
                                             title: "Doc", pid: pid)
        store.windows = [window]
        store.noteWindowRefs(store.windows)
        store.add(920, to: work)
        store.pinApp(bundleID: "com.apple.finder", in: work)
        guard store.isPinned("com.apple.finder", in: work) else {
            return check("the fixture really pinned Finder", false)
        }
        store.windows = []
        store.noteWindowRefs([])
        store.sampleRunningApps(windowOwnerPIDs: [], force: true)
        store.updateLaunchers()
        let icons = items(store, in: work).filter { $0.launcherBundleID == "com.apple.finder" }
        check("a pinned app draws one icon, not a pin and a launcher",
              icons.count == 1, "\(icons.count)")

        // Main's arrangement must be pruned like everyone else's. Main has no
        // membership, so the sweep that drops dead order keys never walked it —
        // and `placeInArrangement` now mints a key for every window captured
        // there, so nothing ever removed them.
        let grow = freshStore()
        grow.endLaunchGraceForTesting()
        let mainID = grow.main.id
        let gone = WindowInfo.testInstance(id: 930, bundleID: "com.nonexistent.app",
                                           title: "Ghost", pid: 4242)
        grow.windows = [gone]
        grow.noteWindowRefs(grow.windows)
        grow.focusedWindowID = 930
        grow.settleFocusForTesting()
        grow.captureNewWindows([930], focusHint: 930)
        check("the window took a key in Main's arrangement",
              grow.order(in: mainID).contains("w930"), "\(grow.order(in: mainID))")
        grow.windows = []
        grow.noteWindowRefs([])
        grow.sampleRunningApps(windowOwnerPIDs: [], force: true)
        grow.forcePruneForTesting()
        check("Main's arrangement drops the key once the app is gone",
              !grow.order(in: mainID).contains("w930"), "\(grow.order(in: mainID))")
    }

    /// A window raised by its own application activating is not a statement about
    /// where the user is working.
    ///
    /// Opening a document activates its application, which brings that
    /// application's *existing* window forward — so for a few tens of
    /// milliseconds the focused window is that one rather than the one being
    /// worked in, and the document was filed into whichever capsule held it.
    /// Measured at 32ms (137 MB file) and 48ms (18 KB): the gap does not grow
    /// with the document, because the window exists before its contents are read.
    private static func activationRaiseIsNotIntent() {
        let store = freshStore()
        guard store.groups.count >= 3 else { return check("two capsules exist", false) }
        let work = store.groups[1].id
        store.endLaunchGraceForTesting()

        let inMain = WindowInfo.testInstance(id: 500, bundleID: "com.reader",
                                             title: "Reading", pid: 1)
        let inWork = WindowInfo.testInstance(id: 501, bundleID: "com.editor",
                                             title: "Spreadsheet", pid: 2)
        store.windows = [inMain, inWork]
        store.noteWindowRefs(store.windows)
        store.add(501, to: work)

        // Working in Main, settled.
        store.focusedWindowID = 500
        store.settleFocusForTesting()
        check("the fixture is working in Main", store.captureTarget(focusHint: 500) == store.main.id)

        // The document's application activates and raises its Work window. No
        // settling: this focus is milliseconds old, which is the whole signal.
        store.focusedWindowID = 501
        check("a just-raised window does not capture the new document",
              store.captureTarget(focusHint: 501) == store.main.id,
              "\(store.groups.first { $0.id == store.captureTarget(focusHint: 501) }?.name ?? "?")")

        // The same focus, once it has stood for a moment, is a real answer —
        // otherwise clicking into a capsule could never take effect.
        store.settleFocusForTesting()
        check("the same window does capture once focus has settled",
              store.captureTarget(focusHint: 501) == work)
    }

    /// The active capsule is a live answer, not one frozen when focus landed.
    private static func activeCapsuleTracking() {
        let store = freshStore()
        guard store.groups.count >= 3 else { return check("two capsules exist", false) }
        let work = store.groups[1].id
        let study = store.groups[2].id

        let window = WindowInfo.testInstance(id: 940, bundleID: "com.editor",
                                             title: "Doc", pid: 7)
        store.windows = [window]
        store.noteWindowRefs(store.windows)
        store.add(940, to: work)
        store.focusedWindowID = 940
        store.settleFocusForTesting()
        check("the capsule of the focused window is active", store.activeGroupID == work)

        // Move it. The stored answer used to be a group id resolved when focus
        // landed, so it still named Work — and clicking the desktop sent the ring,
        // and the next window, back to a capsule the window had left.
        store.add(940, to: study)
        store.windows = []
        store.noteWindowRefs([])
        check("the last capsule worked in follows the window that moved",
              store.activeGroupID == study, "\(store.groups.first { $0.id == store.activeGroupID }?.name ?? "?")")

        // Clicking a launcher inside a capsule makes that capsule active, which is
        // what makes "the window opens in Work" true without an exception in the
        // placement rule.
        store.windows = [window]
        store.noteWindowRefs(store.windows)
        store.focusedWindowID = 940
        store.settleFocusForTesting()
        store.noteWorkingIn(work)
        check("clicking a capsule's launcher makes it active", store.activeGroupID == work)
        check("and a window opened after that click lands there",
              store.captureTarget(focusHint: 940) == work)
    }

    private static func launcherIsUniqueAndStaysPut() {
        let store = freshStore()
        guard store.groups.count >= 3 else { return check("two capsules exist", false) }
        let work = store.groups[1].id
        let study = store.groups[2].id
        let mainID = store.main.id

        // A genuinely running, Dock-worthy application: the candidate list is
        // filtered on `activationPolicy == .regular` and cannot be faked.
        guard let finder = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == "com.apple.finder" }) else {
            check("Finder is running to stand in for a closed-window app", false)
            return
        }
        let pid = finder.processIdentifier

        func launcherCapsules() -> [UUID] {
            store.groups
                .map(\.id)
                .filter { id in
                    items(store, in: id).contains { $0.launcherBundleID == "com.apple.finder" }
                }
        }
        func settle(hasWindows: Bool) {
            store.sampleRunningApps(windowOwnerPIDs: hasWindows ? [pid] : [], force: true)
            store.updateLaunchers()
        }

        let inWork = WindowInfo.testInstance(id: 910, bundleID: "com.apple.finder",
                                             title: "Work doc", pid: pid)
        let inMain = WindowInfo.testInstance(id: 911, bundleID: "com.apple.finder",
                                             title: "Main doc", pid: pid)
        store.windows = [inWork, inMain]
        store.noteWindowRefs(store.windows)
        store.add(910, to: work)
        check("the fixture really is split across two capsules",
              store.isMember(910, of: work) && !store.isMember(911, of: work))
        settle(hasWindows: true)
        check("no launcher while the application still has a window",
              launcherCapsules().isEmpty, "\(launcherCapsules().count)")

        // Close Work's. Main's window survives, so the application is still alive
        // on the strip and *nothing* appears — Work simply has no Finder on it.
        store.windows = [inMain]
        store.noteWindowRefs(store.windows)
        settle(hasWindows: true)
        check("closing one window while another lives creates no launcher",
              launcherCapsules().isEmpty, "\(launcherCapsules().count)")

        // Close the last one. Main held it, so Main gets the launcher — not Work,
        // which held a Finder window earlier and lost it first.
        store.windows = []
        settle(hasWindows: false)
        check("the launcher is born where the last window lived",
              launcherCapsules() == [mainID], "\(launcherCapsules().count) capsule(s)")

        // Sticky: a window opening somewhere else does not retract it.
        let inStudy = WindowInfo.testInstance(id: 912, bundleID: "com.apple.finder",
                                              title: "Study doc", pid: pid)
        store.windows = [inStudy]
        store.noteWindowRefs(store.windows)
        store.add(912, to: study)
        settle(hasWindows: true)
        check("a window opening elsewhere leaves the launcher alone",
              launcherCapsules() == [mainID], "\(launcherCapsules().map { _ in "x" }.count)")

        // Unique: closing that one makes Study the last capsule to hold a window,
        // but Finder already has a launcher, so no second one is created.
        store.windows = []
        settle(hasWindows: false)
        check("no second launcher is ever created",
              launcherCapsules() == [mainID], "\(launcherCapsules().count) capsule(s)")

        // Reclaimed only by its own capsule getting a real window back.
        let backInMain = WindowInfo.testInstance(id: 913, bundleID: "com.apple.finder",
                                                 title: "Main again", pid: pid)
        store.windows = [backInMain]
        store.noteWindowRefs(store.windows)
        settle(hasWindows: true)
        check("the launcher goes when its own capsule gets a window back",
              launcherCapsules().isEmpty, "\(launcherCapsules().count)")
    }

    /// Two copies of one application installed side by side are two Dock icons,
    /// and must be two launchers.
    ///
    /// Measured on this machine: `/Applications/Slack.app` running as pid 98963
    /// and `/Applications/Slack 2.app` as pid 824, both reporting the bundle id
    /// `com.tinyspeck.slackmacgap`. Every launcher was keyed by bundle id — a
    /// `Set<String>` for the candidates and `"r\(bundleID)"` for the item — so the
    /// two collapsed into one, and the copy whose window had been closed was
    /// suppressed by the *other* copy's window. Reported as "2 in the Dock, 1 in
    /// WindowDeck", and isolated by closing one with the red button.
    ///
    /// Identity is the half worth guarding here: two views sharing one id is what
    /// once rendered the switcher rotated with two tiles highlighted at once, so
    /// a bundle id can never be a launcher's identity again.
    ///
    /// The candidate list itself is built from `NSWorkspace` and cannot be
    /// fabricated, so this asserts the rule rather than the sampling.
    private static func twoInstancesOfOneApp() {
        let app = PinnedApp(bundleID: "com.example.twin", name: "Twin")
        let first = AppStore.AppInstance(
            pid: 4242, bundleID: "com.example.twin", name: "Twin",
            url: URL(fileURLWithPath: "/Applications/Twin.app"))
        let second = AppStore.AppInstance(
            pid: 4243, bundleID: "com.example.twin", name: "Twin 2",
            url: URL(fileURLWithPath: "/Applications/Twin 2.app"))

        let a = DeckItem.running(app, placeholderFor: nil, instance: first)
        let b = DeckItem.running(app, placeholderFor: nil, instance: second)
        check("two processes of one application are two identities", a.id != b.id,
              "\(a.id) vs \(b.id)")
        check("and each identity names its own process",
              a.id.contains("4242") && b.id.contains("4243"), "\(a.id) / \(b.id)")

        // The same process twice is the same thing, or the row would grow a
        // duplicate every time the sample was rebuilt.
        let again = DeckItem.running(app, placeholderFor: nil, instance: first)
        check("the same process is one identity", a.id == again.id)

        // Each launcher opens the copy it stands for. Resolving through the
        // bundle id instead hands both to whichever copy LaunchServices prefers.
        check("each instance carries its own copy on disk",
              first.url != second.url
              && second.url?.path.contains("Twin 2") == true)
    }

    // MARK: - Cycling

    /// Builds a group holding four windows across two apps, focused on the
    /// second, with a known manual arrangement and a known focus history.
    private static func cyclingFixture() -> (AppStore, UUID, [WindowInfo])? {
        let store = freshStore()
        guard store.groups.count >= 2 else { check("a group exists", false); return nil }
        let group = store.groups[1].id

        let a = WindowInfo.testInstance(id: 10, bundleID: "com.browser", title: "A", pid: 1)
        let b = WindowInfo.testInstance(id: 11, bundleID: "com.browser", title: "B", pid: 1)
        let c = WindowInfo.testInstance(id: 12, bundleID: "com.browser", title: "C", pid: 1)
        let d = WindowInfo.testInstance(id: 13, bundleID: "com.editor", title: "D", pid: 2)
        store.windows = [a, b, c, d]
        store.noteWindowRefs([a, b, c, d])
        for id in [10, 11, 12, 13] { store.add(CGWindowID(id), to: group) }
        store.setOrder(["w10", "w11", "w12", "w13"], in: group)

        // Focus history: 12 first, then 10, then 11 — so most-recently-used is
        // 11, 10, 12 and is deliberately *not* the strip order.
        store.focusedWindowID = 12
        store.settleFocusForTesting()
        store.focusedWindowID = 10
        store.settleFocusForTesting()
        store.focusedWindowID = 11
        store.settleFocusForTesting()
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
        store.settleFocusForTesting()
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
        store.settleFocusForTesting()
        check("a tap moves one along from where you are",
              store.cycleStartIndex(candidates, reversed: false) == 2)
        check("shift-tap moves one back",
              store.cycleStartIndex(candidates, reversed: true) == 0)

        // Wrapping, at both ends.
        store.focusedWindowID = 13
        store.settleFocusForTesting()
        check("a tap from the last entry wraps to the first",
              store.cycleStartIndex(candidates, reversed: false) == 0)
        store.focusedWindowID = 10
        store.settleFocusForTesting()
        check("shift-tap from the first wraps to the last",
              store.cycleStartIndex(candidates, reversed: true) == 3)

        // Cycling *into* a group you are not standing in has no current position.
        store.focusedWindowID = 999
        store.settleFocusForTesting()
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
        store.settleFocusForTesting()
        store.appCycleStaysInGroup = true
        check("in the group, app cycling is the group's windows of that app",
              store.cycleCandidates(appOnly: true).map(\.id) == [10, 11, 12],
              "\(store.cycleCandidates(appOnly: true).map(\.id))")

        // The same app with a window in Main and nothing else there. The capsule
        // holds exactly one window of it, which is the only case the setting
        // still decides: stay put, or roam to every window the app has open.
        let outside = WindowInfo.testInstance(id: 14, bundleID: "com.browser",
                                              title: "In Main", pid: 1)
        store.windows = store.windows + [outside]
        store.noteWindowRefs(store.windows)
        store.focusedWindowID = 14
        store.settleFocusForTesting()

        store.appCycleStaysInGroup = true
        check("staying put offers only the capsule's one window",
              store.cycleCandidates(appOnly: true).map(\.id) == [14],
              "\(store.cycleCandidates(appOnly: true).map(\.id))")

        store.appCycleStaysInGroup = false
        check("otherwise it falls back to every window of the app",
              store.cycleCandidates(appOnly: true).map(\.id).sorted() == [10, 11, 12, 14],
              "\(store.cycleCandidates(appOnly: true).map(\.id))")

        // With more than one of the app here, the setting must make no
        // difference at all — the capsule is the scope either way.
        store.focusedWindowID = 11
        store.settleFocusForTesting()
        check("a capsule with several of the app ignores the setting",
              store.cycleCandidates(appOnly: true).map(\.id) == [10, 11, 12],
              "\(store.cycleCandidates(appOnly: true).map(\.id))")

        // Standing in a window whose app has nothing else open: one candidate,
        // not a crash and not everything.
        store.appCycleStaysInGroup = true
        let lonely = WindowInfo.testInstance(id: 15, bundleID: "com.other", title: "L", pid: 9)
        store.windows = store.windows + [lonely]
        store.noteWindowRefs(store.windows)
        store.focusedWindowID = 15
        store.settleFocusForTesting()
        check("an app with one window offers just that window",
              store.cycleCandidates(appOnly: true).map(\.id) == [15],
              "\(store.cycleCandidates(appOnly: true).map(\.id))")
    }

    /// The reported scenario, exactly: one application's windows split across two
    /// capsules, cycling from inside one of them.
    ///
    /// Distinct from `cyclingAppScope`, where the windows outside the group
    /// belonged to no group at all. Here the others are filed in a *different*
    /// capsule, which is the arrangement the whole app exists for — and the one
    /// place a scoping mistake would be least visible, since every candidate is a
    /// legitimate window of the right application.
    private static func cyclingAcrossTwoGroups() {
        let store = freshStore()
        guard store.groups.count >= 3 else { return check("two groups exist", false) }
        let work = store.groups[1].id
        let other = store.groups[2].id

        // Four VS Code windows in Work, three in the other capsule, plus one
        // window of a different app in Work so "everything in Work" is not the
        // answer, and two more left in Main.
        var all: [WindowInfo] = []
        for id in 20...23 { all.append(.testInstance(id: CGWindowID(id), bundleID: "com.vscode",
                                                     title: "Work \(id)", pid: 5)) }
        for id in 30...32 { all.append(.testInstance(id: CGWindowID(id), bundleID: "com.vscode",
                                                     title: "Other \(id)", pid: 5)) }
        all.append(.testInstance(id: 40, bundleID: "com.terminal", title: "Term", pid: 6))
        all.append(.testInstance(id: 41, bundleID: "com.vscode", title: "Loose", pid: 5))
        store.windows = all
        store.noteWindowRefs(all)
        for id in 20...23 { store.add(CGWindowID(id), to: work) }
        for id in 30...32 { store.add(CGWindowID(id), to: other) }
        store.add(40, to: work)

        store.focusedWindowID = 21
        store.settleFocusForTesting()
        store.cycleOrder = .stripOrder

        let candidates = store.cycleCandidates(appOnly: true)
        check("cycling this app in Work offers only Work's four windows",
              candidates.map(\.id) == [20, 21, 22, 23], "\(candidates.map(\.id))")
        check("the other capsule's windows of the same app are excluded",
              !candidates.contains { (30...32).contains(Int($0.id)) })
        check("and another app in the same capsule is excluded",
              !candidates.contains { $0.id == 40 })

        // Standing in the other capsule, the same key offers that capsule's three.
        store.focusedWindowID = 31
        store.settleFocusForTesting()
        check("standing in the other capsule offers its three instead",
              store.cycleCandidates(appOnly: true).map(\.id) == [30, 31, 32],
              "\(store.cycleCandidates(appOnly: true).map(\.id))")

        // And from Main, only what Main holds — the catch-all is a capsule like
        // any other, not a view of everything.
        store.focusedWindowID = 41
        store.settleFocusForTesting()
        check("cycling from Main offers only Main's windows",
              store.cycleCandidates(appOnly: true).map(\.id) == [41],
              "\(store.cycleCandidates(appOnly: true).map(\.id))")
    }

    /// The scope is the capsule holding the focused window, always.
    ///
    /// The strip shows every window at once, so an unscoped cycle would offer the
    /// whole bar. There is no setting for this any more: with one capsule per
    /// window there is exactly one answer to "which capsule am I in".
    private static func cyclingScopedToCapsule() {
        let store = freshStore()
        guard store.groups.count >= 3 else { return check("two groups exist", false) }
        let work = store.groups[1].id
        let other = store.groups[2].id

        var all: [WindowInfo] = []
        for id in 50...52 { all.append(.testInstance(id: CGWindowID(id), bundleID: "com.vscode",
                                                     title: "Work \(id)", pid: 5)) }
        all.append(.testInstance(id: 53, bundleID: "com.terminal", title: "Term", pid: 6))
        for id in 60...61 { all.append(.testInstance(id: CGWindowID(id), bundleID: "com.vscode",
                                                     title: "Other \(id)", pid: 5)) }
        all.append(.testInstance(id: 70, bundleID: "com.notes", title: "Loose", pid: 7))
        all.append(.testInstance(id: 71, bundleID: "com.notes", title: "Loose2", pid: 7))
        store.windows = all
        store.noteWindowRefs(all)
        for id in 50...53 { store.add(CGWindowID(id), to: work) }
        for id in 60...61 { store.add(CGWindowID(id), to: other) }

        store.cycleOrder = .stripOrder
        store.focusedWindowID = 51
        store.settleFocusForTesting()

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
        store.settleFocusForTesting()
        check("a different capsule scopes to itself",
              store.cycleCandidates(appOnly: false).map(\.id) == [60, 61],
              "\(store.cycleCandidates(appOnly: false).map(\.id))")

        // Main is a capsule like any other, and the windows nothing claims are
        // exactly the ones it holds.
        store.focusedWindowID = 70
        store.settleFocusForTesting()
        check("an unclaimed window cycles Main",
              store.cycleCandidates(appOnly: false).map(\.id) == [70, 71],
              "\(store.cycleCandidates(appOnly: false).map(\.id))")

        // A folded capsule still owns its windows. Skipping it would widen the
        // cycle to everything the moment a group was collapsed.
        store.setCollapsed(true, for: other)
        store.focusedWindowID = 60
        store.settleFocusForTesting()
        check("a collapsed capsule still scopes the cycle",
              store.cycleCandidates(appOnly: false).map(\.id) == [60, 61],
              "\(store.cycleCandidates(appOnly: false).map(\.id))")
    }

    /// Both new settings persist, and a file written before them still loads.
    private static func cyclingPersistence() {
        var state = PersistedState()
        state.cycleOrder = .stripOrder
        state.appCycleStaysInGroup = false
        guard let data = try? JSONEncoder().encode(state),
              let back = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return check("cycling settings round-trip", false) }
        check("cycle order round-trips", back.cycleOrder == .stripOrder)
        check("app cycle scope round-trips", back.appCycleStaysInGroup == false)

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
        let store = freshStore()
        guard store.groups.count >= 2 else { return check("a group exists", false) }
        let group = store.groups[1].id

        let a = WindowInfo.testInstance(id: 700, bundleID: "com.browser", title: "A")
        let b = WindowInfo.testInstance(id: 701, bundleID: "com.browser", title: "B")
        let c = WindowInfo.testInstance(id: 702, bundleID: "com.browser", title: "C")
        let other = WindowInfo.testInstance(id: 710, bundleID: "com.editor", title: "Editor")
        store.windows = [a, b, c, other]
        store.noteWindowRefs([a, b, c, other])
        for id in [700, 701, 702, 710] { store.add(CGWindowID(id), to: group) }

        check("four loose windows before stacking",
              items(store, in: group).filter { if case .window = $0 { true } else { false } }.count == 4)

        store.stackApp(bundleID: "com.browser", in: group)

        let drawn = items(store, in: group)
        let stacks = drawn.filter(\.isStack)
        check("the app collapses to one stack", stacks.count == 1, "\(stacks.count)")
        check("the stack holds all three of its windows",
              stacks.first?.windows.count == 3, "\(stacks.first?.windows.count ?? -1)")
        // The other app must be untouched — a stack is scoped to one bundle id.
        check("a different app is not swallowed",
              drawn.contains { if case .window(let w) = $0 { w.id == 710 } else { false } })

        // A window opened later joins with nothing being told, which is the whole
        // reason this is a rule rather than a list of window ids.
        let d = WindowInfo.testInstance(id: 703, bundleID: "com.browser", title: "D")
        store.windows = [a, b, c, d, other]
        store.noteWindowRefs([a, b, c, d, other])
        store.add(703, to: group)
        check("a window opened later joins the stack automatically",
              items(store, in: group).first(where: \.isStack)?.windows.count == 4)

        // Down to one window it is indistinguishable from an ordinary entry, so
        // it renders as one — but the *rule* survives, or closing windows would
        // silently destroy the stack the way it once destroyed clusters.
        store.windows = [a, other]
        check("a stack of one renders as a plain window",
              !items(store, in: group).contains(where: \.isStack))
        check("but the rule is not destroyed by window churn",
              store.isStacked("com.browser", in: group))
        store.windows = [a, b, c, d, other]
        check("and it re-forms when the windows come back",
              items(store, in: group).contains(where: \.isStack))

        // A clustered window is hand-picked; a stack is a blanket rule. The
        // specific arrangement has to win, or clustering would be undone by
        // stacking the same app.
        store.combine(700, into: 701, in: group)
        let withCluster = items(store, in: group)
        check("a cluster survives its app being stacked",
              withCluster.contains(where: \.isCluster))
        check("the stack takes only the windows the cluster left",
              withCluster.first(where: \.isStack)?.windows.count == 2,
              "\(withCluster.first(where: \.isStack)?.windows.count ?? -1)")

        store.unstackApp(bundleID: "com.browser", in: group)
        check("unstacking puts the windows back",
              !items(store, in: group).contains(where: \.isStack))
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
        let store = freshStore()
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
        store.stackApp(bundleID: "com.browser", in: main)

        guard let stack = items(store, in: main).first(where: \.isStack) else {
            return check("the stack forms", false)
        }
        check("the stack holds only the group's windows",
              stack.windows.map(\.id).sorted() == [901, 902, 903],
              "\(stack.windows.map(\.id))")

        // The window outside the group is the most recently focused, so a helper
        // that ignored the group would put it first — and clicking the tile would
        // open it.
        store.focusedWindowID = 901
        store.settleFocusForTesting()
        store.focusedWindowID = 950
        store.settleFocusForTesting()

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
    /// `applyManualOrder` can only place an unranked key beside its own app's
    /// windows, and stacking removes exactly those keys — so a brand-new
    /// `s<bundle>` key has no anchor and would drop the stack to the far right
    /// the instant it was made — the same trap that would have condemned hidden pins
    /// to the end of the row on the first drag.
    private static func appStackOrdering() {
        let store = freshStore()
        guard store.groups.count >= 2 else { return check("a group exists", false) }
        let group = store.groups[1].id

        let first = WindowInfo.testInstance(id: 800, bundleID: "com.editor", title: "Editor")
        let a = WindowInfo.testInstance(id: 801, bundleID: "com.browser", title: "A")
        let b = WindowInfo.testInstance(id: 802, bundleID: "com.browser", title: "B")
        let last = WindowInfo.testInstance(id: 803, bundleID: "com.mail", title: "Mail")
        store.windows = [first, a, b, last]
        store.noteWindowRefs([first, a, b, last])
        for id in [800, 801, 802, 803] { store.add(CGWindowID(id), to: group) }
        store.setOrder(["w800", "w801", "w802", "w803"], in: group)

        // `stackApp` returns early when the rule is already there, so a case that
        // inherited a stack would never seed the arrangement it exists to test.
        // `freshStore` rules that out; assert it anyway, because a stack test
        // once passed while stacking nothing at all.
        check("this case starts unstacked", !store.isStacked("com.browser", in: group))

        store.stackApp(bundleID: "com.browser", in: group)
        check("the stack takes its leftmost member's place",
              store.order(in: group) == ["w800", "scom.browser", "w803"],
              "\(store.order(in: group))")
        check("and draws in that position",
              items(store, in: group).map(\.orderKey) == ["w800", "scom.browser", "w803"],
              "\(items(store, in: group).map(\.orderKey))")

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

    /// A stack's *position* must survive a relaunch.
    ///
    /// It did not, and nothing failed: `orderSnapshot` describes each key as an
    /// `OrderRef`, had no case for `s<bundle>`, and `compactMap` dropped it.
    /// `applyManualOrder` then has nowhere to put it but the end, a stack
    /// having no loose window of its own app to sit beside, so every stacked app
    /// came back on the far right of its capsule however it had been arranged — reported as "the relative positions of the apps in
    /// the groups changed after relaunch". Measured on the live file: four
    /// stacks across two groups, and not one `stacked` entry in any saved order.
    private static func appStackOrderSurvivesRelaunch() {
        let store = freshStore()
        guard store.groups.count >= 2 else { return check("a group exists", false) }
        let group = store.groups[1].id

        let first = WindowInfo.testInstance(id: 810, bundleID: "com.editor", title: "Editor")
        let a = WindowInfo.testInstance(id: 811, bundleID: "com.browser", title: "A")
        let b = WindowInfo.testInstance(id: 812, bundleID: "com.browser", title: "B")
        let last = WindowInfo.testInstance(id: 813, bundleID: "com.mail", title: "Mail")
        store.windows = [first, a, b, last]
        store.noteWindowRefs([first, a, b, last])
        for id in [810, 811, 812, 813] { store.add(CGWindowID(id), to: group) }
        store.setOrder(["w810", "w811", "w812", "w813"], in: group)
        store.stackApp(bundleID: "com.browser", in: group)
        // The stack sits in the *middle* on purpose: at either end a bug that
        // sends it to the back is invisible half the time.
        check("the stack starts in the middle",
              store.order(in: group) == ["w810", "scom.browser", "w813"],
              "\(store.order(in: group))")

        store.saveNow()
        let saved = StateStore.load().groups.first { $0.id == group.uuidString }
        check("the stack's slot reaches disk",
              saved?.order.contains { if case .stacked("com.browser") = $0 { true } else { false } } == true,
              "\(saved?.order.count ?? -1) entries")

        // A fresh store over that file, with the same windows present: the
        // arrangement has to come back the way it was left.
        let relaunched = AppStore()
        relaunched.windows = [first, a, b, last]
        relaunched.noteWindowRefs([first, a, b, last])
        _ = relaunched.restorePass(against: [first, a, b, last])
        check("the stack rule survives", relaunched.isStacked("com.browser", in: group))
        check("and it comes back in its own slot, not at the end",
              relaunched.order(in: group) == ["w810", "scom.browser", "w813"],
              "\(relaunched.order(in: group))")
        check("so the capsule draws it in the middle",
              items(relaunched, in: group).map(\.orderKey) == ["w810", "scom.browser", "w813"],
              "\(items(relaunched, in: group).map(\.orderKey))")
    }

    /// A stacked app's launcher must still stand aside, and its windows must stop
    /// competing for titles.
    private static func appStackInteractions() {
        let store = freshStore()
        guard store.groups.count >= 2 else { return check("a group exists", false) }
        let group = store.groups[1].id

        let a = WindowInfo.testInstance(id: 900, bundleID: "com.browser", title: "A")
        let b = WindowInfo.testInstance(id: 901, bundleID: "com.browser", title: "B")
        store.windows = [a, b]
        store.noteWindowRefs([a, b])
        store.add(900, to: group); store.add(901, to: group)
        store.stackApp(bundleID: "com.browser", in: group)

        // `pins(alongside:)` hides a launcher whose app has a window here. A
        // stack reports its windows precisely so that rule keeps working — a
        // launcher drawn beside the very windows it would have opened is the
        // duplicate that rule exists to prevent.
        store.pinApp(bundleID: "com.browser", in: group)
        let drawn = items(store, in: group)
        check("a stacked app's launcher still stands aside",
              !drawn.contains { if case .pinned = $0 { true } else { false } })

        // Titles disambiguate *loose* windows of one app. Stacked windows are
        // already behind one icon, so they must stop inflating that count.
        let layout = DeckLayout.compute(
            items: drawn, pinnedCount: 0, titlesEnabled: true,
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
        guard let data = try? JSONEncoder().encode(state),
              let back = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return check("app stacks round-trip", false) }

        check("a group's stacks round-trip",
              back.groups.first?.stackedAppBundleIDs.sorted() == ["com.browser", "com.editor"])

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

    // MARK: - ⌥Tab

    /// What ⌥Tab offers, and in what order.
    ///
    /// The list mirrors the strip, so most of its correctness is inherited from
    /// `sections`. What is *not* inherited, and is asserted here, is the handful
    /// of decisions layered on top: collapsed capsules still count, launchers
    /// only count while their app runs, and the ordering has to put the thing
    /// you are in first or a quick flip lands somewhere arbitrary.
    private static func switchEntries() {
        let store = freshStore()
        guard store.groups.count >= 3 else { return check("two groups exist", false) }
        let main = store.main.id
        let work = store.groups[1].id
        let folded = store.groups[2].id

        // Five Chrome windows in Work, one in Main, one elsewhere — the reported
        // shape: "there should be 2 chrome, 1 is 5, 1 is 1".
        var all: [WindowInfo] = []
        for i in 1...5 {
            all.append(.testInstance(id: CGWindowID(400 + i), bundleID: "com.browser",
                                     title: "Work \(i)", pid: 3))
        }
        all.append(.testInstance(id: 410, bundleID: "com.browser", title: "Loose", pid: 3))
        all.append(.testInstance(id: 420, bundleID: "com.editor", title: "Folded away", pid: 4))
        store.windows = all
        store.noteWindowRefs(all)
        for i in 1...5 { store.add(CGWindowID(400 + i), to: work) }
        store.add(420, to: folded)
        store.stackApp(bundleID: "com.browser", in: work)
        store.setCollapsed(true, for: folded)

        let entries = store.switchEntries()
        let chrome = entries.filter { $0.title == "com.browser" }
        check("one entry per capsule the app has windows in", chrome.count == 2,
              "\(chrome.map { "\($0.groupName)×\($0.count)" })")
        check("the stacked capsule is one entry of five",
              chrome.contains { $0.groupID == work && $0.count == 5 },
              "\(chrome.map { "\($0.groupName)×\($0.count)" })")
        check("and the loose window is an entry of one",
              chrome.contains { $0.groupID == main && $0.count == 1 })

        // A folded capsule is still reachable from the keyboard. Mirroring the
        // strip means the same grouping, not the same visibility — the opposite
        // would hide windows the moment a group was collapsed.
        check("a collapsed capsule is still listed",
              entries.contains { $0.groupID == folded && $0.windows.contains { $0.id == 420 } },
              "\(entries.map(\.groupName))")

        // Item for item the same list the strip builds, so the two cannot drift.
        let drawn = store.sections(includingCollapsed: true)
            .flatMap { section in section.items.map { "\(section.id)/\($0.id)" } }
        check("every entry is an item the strip draws",
              Set(entries.map(\.id)).isSubset(of: Set(drawn)),
              "\(entries.map(\.id))")

        // Ordering: the thing you are in leads, so a quick ⌥Tab flips back to
        // it. This pins the observable property; the explicit hoist in
        // `orderedByRecency` guards a race the harness cannot produce, since
        // every focus change here updates `mruOrder` before anything reads it.
        store.focusedWindowID = 410
        store.settleFocusForTesting()
        check("the entry you are in leads",
              store.switchEntries().first?.windows.first?.id == 410,
              "\(store.switchEntries().first?.title ?? "-")")
        // Focus inside a stack promotes the *stack*, not one of its windows.
        store.focusedWindowID = 403
        store.settleFocusForTesting()
        let promoted = store.switchEntries().first
        check("focusing a window inside a stack promotes the stack",
              promoted?.count == 5 && promoted?.groupID == work,
              "\(promoted?.title ?? "-")×\(promoted?.count ?? -1)")
        check("and the list is otherwise unchanged in length",
              store.switchEntries().count == entries.count)

        // Launchers: in while the app runs, out when it does not. Both
        // directions, or the check passes with the filter deleted.
        let launchers = freshStore()
        let group = launchers.groups[1].id
        launchers.sampleRunningApps(windowOwnerPIDs: [], force: true)
        check("the fixture's app really is running",
              launchers.runningApps.all.contains("com.apple.finder"))
        launchers.pinApp(bundleID: "com.apple.finder", in: group)
        launchers.pin(PinnedApp(bundleID: "com.nonexistent.app", name: "Ghost"), in: group)
        let titles = Set(launchers.switchEntries().map(\.title))
        check("a running app with no windows is offered",
              launchers.switchEntries().contains { $0.item.launcherBundleID == "com.apple.finder" },
              "\(titles)")
        check("an application that is not running is not",
              !launchers.switchEntries().contains { $0.item.launcherBundleID == "com.nonexistent.app" },
              "\(titles)")

        commitTargets()
    }

    /// What committing each kind of entry does. Asserted through
    /// `commitTarget(for:)` rather than by driving the switcher, which needs a
    /// run loop `SelfTest.run` never turns.
    private static func commitTargets() {
        let store = freshStore()
        let group = store.groups[1].id

        let a = WindowInfo.testInstance(id: 500, bundleID: "com.browser", title: "A", pid: 3)
        let b = WindowInfo.testInstance(id: 501, bundleID: "com.browser", title: "B", pid: 3)
        let c = WindowInfo.testInstance(id: 502, bundleID: "com.editor", title: "C", pid: 4)
        let d = WindowInfo.testInstance(id: 503, bundleID: "com.editor", title: "D", pid: 4)
        store.windows = [a, b, c, d]
        store.noteWindowRefs([a, b, c, d])
        for id: CGWindowID in [500, 501, 502, 503] { store.add(id, to: group) }
        store.stackApp(bundleID: "com.browser", in: group)
        store.combine(503, into: 502, in: group)
        // 501 is the most recently used of the stack's two windows.
        store.focusedWindowID = 500
        store.settleFocusForTesting()
        store.focusedWindowID = 501
        store.settleFocusForTesting()

        let entries = store.switchEntries()
        guard let stack = entries.first(where: { $0.item.isStack }),
              let cluster = entries.first(where: { $0.item.isCluster })
        else { return check("the fixture builds a stack and a cluster", false) }

        check("a stack raises its most recent window",
              store.commitTarget(for: stack) == .focus(501),
              "\(store.commitTarget(for: stack))")
        check("a cluster raises all of its windows",
              store.commitTarget(for: cluster) == .focusAll([502, 503]),
              "\(store.commitTarget(for: cluster))")

        // A plain window entry, from a capsule with nothing folded into it.
        let plain = freshStore()
        let lone = WindowInfo.testInstance(id: 510, bundleID: "com.solo", title: "Solo", pid: 5)
        plain.windows = [lone]
        plain.noteWindowRefs([lone])
        guard let entry = plain.switchEntries().first else {
            return check("a lone window makes an entry", false)
        }
        check("a window entry raises itself", plain.commitTarget(for: entry) == .focus(510))
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

    /// The single placement rule: a new window joins the capsule being worked in.
    ///
    /// There is deliberately no notion of a focus being "settled" any more. That
    /// existed to arbitrate against dead slots that tried to claim windows back,
    /// and nothing claims windows back — so the walk back through recent focus,
    /// and the two-second age threshold that decided which focus counted, are
    /// both gone. `focusHint` is simply the focus from before this pass.
    private static func capturing() {
        let store = freshStore()
        guard store.groups.count >= 3 else { return check("two groups exist", false) }
        let working = store.groups[1].id     // where you are actually working
        let other = store.groups[2].id       // an app's window living elsewhere

        let mine = WindowInfo.testInstance(id: 100, bundleID: "com.editor", title: "Working here")
        let theirs = WindowInfo.testInstance(id: 101, bundleID: "com.sheets", title: "Elsewhere")
        store.windows = [mine, theirs]
        store.noteWindowRefs([mine, theirs])
        store.add(100, to: working)
        store.add(101, to: other)

        store.focusedWindowID = 100
        store.settleFocusForTesting()
        check("the capsule of the focused window is the target",
              store.captureTarget(focusHint: 100) == working,
              "\(String(describing: store.captureTarget(focusHint: 100)))")
        check("and it follows focus to another capsule",
              store.captureTarget(focusHint: 101) == other)

        // Main is a real answer, not the absence of one.
        let loose = WindowInfo.testInstance(id: 102, bundleID: "com.reader", title: "In Main")
        store.windows = [mine, theirs, loose]
        store.noteWindowRefs([mine, theirs, loose])
        store.focusedWindowID = 102
        store.settleFocusForTesting()
        check("working in Main files new windows into Main",
              store.captureTarget(focusHint: 102) == store.main.id,
              "\(String(describing: store.captureTarget(focusHint: 102)))")

        // Focus on something the strip does not draw — a desktop click, or an
        // application that is frontmost before it has a window. The last capsule
        // genuinely worked in stands; without this a desktop click would quietly
        // move you to Main and the next window opened would land there.
        store.focusedWindowID = 100
        store.settleFocusForTesting()
        check("the last real capsule is remembered", store.activeGroup.id == working)
        store.focusedWindowID = 999           // not a window on the strip
        check("focus on nothing keeps the last capsule active",
              store.activeGroup.id == working, "\(store.activeGroup.name)")
        check("and a window opened then still lands there",
              store.captureTarget(focusHint: 999) == working,
              "\(String(describing: store.captureTarget(focusHint: 999)))")

        // End to end, both directions — a test of one alone passes with the
        // derivation hardcoded. Auto-capture is paused for 20s after launch,
        // which is this whole process, so it has to be lifted first.
        store.endLaunchGraceForTesting()
        store.focusedWindowID = 100
        store.settleFocusForTesting()
        let born = WindowInfo.testInstance(id: 103, bundleID: "com.editor", title: "New")
        store.windows = [mine, theirs, loose, born]
        store.noteWindowRefs(store.windows)
        store.settleFocusForTesting()
        store.captureNewWindows([103], focusHint: 100)
        check("a window opened from Work joins Work", store.isMember(103, of: working),
              "\(store.group(of: 103).name)")

        store.focusedWindowID = 102
        store.settleFocusForTesting()
        let born2 = WindowInfo.testInstance(id: 104, bundleID: "com.editor", title: "New 2")
        store.windows = store.windows + [born2]
        store.noteWindowRefs(store.windows)
        store.settleFocusForTesting()
        store.captureNewWindows([104], focusHint: 102)
        check("a window opened from Main stays in Main", store.isMember(104, of: store.main.id),
              "\(store.group(of: 104).name)")
    }

    /// The guarantee the whole change exists for: a dead slot in another capsule
    /// cannot take a newly opened window, however well it matches.
    ///
    /// This is the bug that took three wrong fixes and fed itself — a seized
    /// window died in the wrong capsule, leaving a fresh slot for the next one.
    /// It is now unrepresentable rather than arbitrated, so the test is short.
    private static func aDeadSlotNeverClaimsANewWindow() {
        let store = freshStore()
        guard store.groups.count >= 3 else { return check("two groups exist", false) }
        let working = store.groups[1].id
        let relic = store.groups[2].id
        store.endLaunchGraceForTesting()

        // An identical window of the same app, same title, same frame, filed in
        // another capsule and closed a moment ago. Every signal the old matcher
        // used points at `relic`.
        let rect = CGRect(x: 40, y: 40, width: 757, height: 559)
        let dead = WindowInfo.testInstance(id: 700, bundleID: "com.browser",
                                           title: "New Tab", frame: rect)
        let here = WindowInfo.testInstance(id: 701, bundleID: "com.editor",
                                           title: "Working here", frame: rect)
        store.windows = [dead, here]
        store.noteWindowRefs([dead, here])
        store.add(700, to: relic)
        store.add(701, to: working)
        check("the relic slot really is set up", store.isMember(700, of: relic))

        store.windows = [here]                      // the relic's window closes
        store.focusedWindowID = 701                 // you are working in `working`

        let fresh = WindowInfo.testInstance(id: 702, bundleID: "com.browser",
                                            title: "New Tab", frame: rect)
        store.windows = [here, fresh]
        store.noteWindowRefs([here, fresh])
        store.settleFocusForTesting()
        store.captureNewWindows([702], focusHint: 701)

        check("a new window joins the capsule being worked in",
              store.isMember(702, of: working), "702 is in \(store.group(of: 702).name)")
        check("and is not seized by the matching dead slot",
              !store.isMember(702, of: relic))
        check("it lands in exactly one capsule",
              store.groups.filter { !$0.isMain && $0.memberIDs.contains(702) }.count == 1)
    }


    /// A folded group is absent from `sections`, so seeding a fresh arrangement
    /// from there gave it an empty row and the first drag did nothing visible
    /// while persisting a one-entry order.
    private static func reorderingInsideAFoldedGroup() {
        let store = freshStore()
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

        // The strip's rule, in the panel that shows the same list: a window the
        // arrangement does not mention is placed beside its own application's
        // rather than behind everything. A folded group is only ever seen here,
        // so without this it keeps the scatter the strip no longer has.
        let sibling = WindowInfo.testInstance(id: 4, bundleID: "com.a", title: "A2")
        let beside = AllGroupsModel.ordered([a, b, c, sibling], by: ["w1", "w2", "w3"])
        check("an unarranged window joins its own app in the panel",
              beside.map(\.id) == [1, 4, 2, 3],
              "\(beside.map(\.id))")
    }

    // MARK: - Pruning

    private static func pruning() {
        let store = freshStore()
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
        let store = freshStore()
        guard store.groups.count >= 2 else { return check("a group exists", false) }
        let index = store.groups.firstIndex { !$0.isMain }!
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
        check("saved window ids are trusted in this session",
              store.windowIDsTrustworthyForTesting)
        check("window id beats a changed title", store.isMember(500, of: group))
        check("loose title match recovers a decorated title", store.isMember(501, of: group))
        check("restore reports what it claimed", claimed.contains(500) && claimed.contains(501))
        check("an absent window stays queued",
              store.groups[index].savedMembers.contains { $0.title == "Never comes back" })
        check("a matched reference is consumed",
              !store.groups[index].savedMembers.contains { $0.title == "Exact" })
    }

    // MARK: - Deck size

    /// The size setting must not be able to break the one property the layout
    /// guarantees: everything fits, at every scale, however crowded.
    ///
    /// The failure this is aimed at has happened before in a different form —
    /// "clamping a width *up* to a floor causes overflow" — and scaling
    /// `hardMinimumWidth` is exactly that shape of change, since it raises a
    /// floor the fair share can be pushed below. A busy strip at the largest
    /// scale is where that shows.
    private static func deckSizing() {
        let windows = (1...60).map {
            WindowInfo.testInstance(id: CGWindowID($0), bundleID: "com.x", title: "W\($0)")
        }
        let items = windows.map { DeckItem.window($0) }

        for scale in [DeckMetrics.minScale, 1, 1.25, DeckMetrics.maxScale] {
            let metrics = DeckMetrics(scale: scale)
            let result = DeckLayout.compute(items: items, pinnedCount: 0,
                                            titlesEnabled: true, maxWidth: 1240,
                                            pillCount: 3, sectionCount: 3,
                                            metrics: metrics)
            check("a crowded strip fits at \(scale)x", result.totalWidth <= 1240,
                  "\(result.totalWidth)")
            let content = result.slots.reduce(0) { $0 + $1.width }
                + CGFloat(max(result.slots.count - 3, 0)) * result.spacing
            check("its contents fit at \(scale)x", content <= 1240, "\(content)")
            check("every window still gets a slot at \(scale)x",
                  result.slots.count == items.count)
            check("no slot collapses to nothing at \(scale)x",
                  result.slots.allSatisfy { $0.width > 0 && $0.iconSize > 0 })
        }

        // The point of the setting: bigger really is bigger, on a row with room
        // to spare. Asserted on a *short* row, because a crowded one is capped by
        // the display and both scales would come back at maxWidth — which would
        // make this pass with the scale ignored entirely.
        let few = Array(items.prefix(4))
        let small = DeckLayout.compute(items: few, pinnedCount: 0, titlesEnabled: false,
                                       maxWidth: 1240, metrics: DeckMetrics(scale: 0.7))
        let large = DeckLayout.compute(items: few, pinnedCount: 0, titlesEnabled: false,
                                       maxWidth: 1240, metrics: DeckMetrics(scale: 1.6))
        check("a larger scale draws wider tiles",
              large.slots[0].width > small.slots[0].width)
        check("a larger scale draws bigger icons",
              large.slots[0].iconSize > small.slots[0].iconSize)
        check("a larger scale needs more of the strip",
              large.totalWidth > small.totalWidth)
        check("a larger scale is taller",
              DeckMetrics(scale: 1.6).height > DeckMetrics(scale: 0.7).height)

        // Out of range is clamped rather than honoured. `lenient` degrades a bad
        // *shape* to the default and says nothing about range, so a hand-edited
        // file is the one way an absurd value reaches this — and a strip taller
        // than the screen puts the slider that fixes it out of reach.
        check("an absurd scale is clamped", DeckMetrics(scale: 40).scale == DeckMetrics.maxScale)
        check("a zero scale is clamped", DeckMetrics(scale: 0).scale == DeckMetrics.minScale)
        check("a negative scale is clamped", DeckMetrics(scale: -3).scale == DeckMetrics.minScale)

        let store = freshStore()
        store.deckScale = 99
        check("the store clamps what it is given", store.deckScale == DeckMetrics.maxScale)
        store.deckScale = 1.1
        check("and keeps a value in range", store.deckScale == 1.1)
    }

    /// Adding a field is the safe kind of persistence change — but "safe" has
    /// been wrong before, so assert both directions.
    private static func deckSizePersistence() {
        var state = PersistedState()
        state.deckScale = 1.3
        guard let data = try? JSONEncoder().encode(state),
              let back = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return check("the deck size round-trips", false) }
        check("the deck size round-trips", back.deckScale == 1.3)

        let legacy = """
        {"groups":[{"id":"A","name":"Old","colorIndex":1,
          "members":[{"bundleID":"x","title":"t"}]}]}
        """
        guard let old = try? JSONDecoder().decode(PersistedState.self, from: Data(legacy.utf8))
        else { return check("a file predating the deck size decodes", false) }
        check("a file predating the deck size decodes", old.groups.count == 1)
        check("its group survives", old.groups.first?.members.count == 1)
        check("the deck size defaults to 1", old.deckScale == 1)

        // A wrong *shape* must degrade to the default rather than take the file
        // down — the failure that once replaced every group, pin and shortcut.
        let broken = """
        {"groups":[{"id":"A","name":"Keep","colorIndex":1,"members":[]}],"deckScale":"large"}
        """
        let salvaged = try? JSONDecoder().decode(PersistedState.self, from: Data(broken.utf8))
        check("a deck size of the wrong type does not fail the file", salvaged != nil)
        check("groups survive it", salvaged?.groups.first?.name == "Keep")
        check("and it falls back to the default", salvaged?.deckScale == 1)
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
