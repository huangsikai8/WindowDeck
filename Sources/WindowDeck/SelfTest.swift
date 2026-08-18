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
        edgeCases()
        runningState()
        menuIconCaching()
        capturing()
        appearedExcludesCreated()
        tabSwitchKeepsItsOwnSlot()
        allGroupsRowOrdering()
        pruning()
        restoring()

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
        store.windows = [tabA]
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
