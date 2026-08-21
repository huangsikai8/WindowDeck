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

    /// Every capsule on the strip, Main first.
    var groups: [DeckGroup]


    // Settings
    var currentSpaceOnly: Bool = true { didSet { onSettingsChanged?(); scheduleSave() } }
    var showTitles: Bool = true { didSet { scheduleSave() } }
    var previewMode: PreviewMode = .thumbnailAndPeek { didSet { scheduleSave() } }
    /// A newly opened window joins the group holding the focused window — the
    /// one thing the active group decides.
    var autoAddNewWindows: Bool = true { didSet { scheduleSave() } }
    /// Keep an entry for a running app once its last window is closed, the way
    /// the Dock does.
    var showRunningApps: Bool = true { didSet { scheduleSave() } }
    /// Stop zoomed windows extending under the strip.
    var clampZoomedWindows: Bool = true { didSet { onSettingsChanged?(); scheduleSave() } }
    /// Hide the strip while an app is genuinely fullscreen.
    var hideInFullscreen: Bool = true { didSet { scheduleSave() } }
    /// How large the strip draws, 1 being the original size. Everything follows
    /// from it — see `DeckMetrics`. Clamped on the way in as well as inside
    /// `DeckMetrics`, so the value that reaches disk is already sane and a file
    /// hand-edited to 40 cannot survive a round trip.
    ///
    /// `onSettingsChanged` because the zoom clamp reserves a band the height of
    /// the strip; leaving that at the old height puts zoomed windows behind a
    /// taller strip or above a shorter one.
    var deckScale: CGFloat = DeckMetrics.defaultScale {
        didSet {
            let clamped = DeckMetrics.clamped(deckScale)
            if clamped != deckScale { deckScale = clamped; return }
            onSettingsChanged?()
            scheduleSave()
        }
    }
    /// How long a cycle shortcut must be held before the switcher is drawn.
    /// Below this, a tap-and-release just switches with no interface at all.
    var switcherHoldDelay: TimeInterval = 0.18 { didSet { scheduleSave() } }
    /// What order the switcher offers windows in. See `CycleOrder`.
    var cycleOrder: CycleOrder = .recentlyUsed { didSet { scheduleSave() } }
    /// Whether app cycling stays inside the capsule the focused window is in
    /// even when the app has other windows elsewhere on the strip.
    var appCycleStaysInGroup: Bool = true { didSet { scheduleSave() } }

    /// Colour used to mark the focused window: its own capsule's colour.
    var focusTint: Color { activeGroup.displayColor }
    var hoverTimings: HoverTimings = .defaults { didSet { scheduleSave() } }

    /// What the running-app world looks like, sampled on the engine's cadence
    /// rather than read inside `visibleItems`.
    ///
    /// `visibleItems` is a computed property, so it runs on every strip redraw
    /// *and* every pass of the layout observer. Calling
    /// `NSWorkspace.runningApplications` from inside it — once for the candidate
    /// set and again per candidate to test each one — roughly doubled idle CPU.
    /// Sampling costs the same work a couple of times a second instead of dozens.
    struct RunningApps: Equatable {
        /// Bundle ids of apps the Dock would show: `activationPolicy == .regular`.
        var dockApps: Set<String> = []
        /// Every running bundle id, Dock-worthy or not.
        var all: Set<String> = []
        /// Bundle ids owning a window on *any* Space, so an app with windows one
        /// Desktop away is not mistaken for having none.
        var withWindows: Set<String> = []
        /// Dock-worthy processes with no window of their own, one entry each.
        ///
        /// Keyed by process rather than by bundle id, because a bundle id is not
        /// unique: two copies of one application on disk run as two processes
        /// sharing it. Measured — `/Applications/Slack.app` as pid 98963 and
        /// `/Applications/Slack 2.app` as pid 824, both `com.tinyspeck.slackmacgap`.
        /// The Dock draws an icon per process and showed two; every launcher here
        /// was keyed by bundle id, so the set collapsed them into one and the
        /// windowless copy was suppressed by the other copy's window.
        var windowless: [AppInstance] = []
        /// Every running process id. A launcher belongs to a *process*, so
        /// "has this application quit" has to be asked per process — a bundle id
        /// stays in `all` while a second copy of the app is still running.
        var livePIDs: Set<pid_t> = []
    }

    /// One running process of an application.
    ///
    /// `url` is the copy *this process* was launched from, which is what makes
    /// clicking its launcher reopen the right one — `urlForApplication(withBundleIdentifier:)`
    /// answers with whichever copy LaunchServices prefers and cannot tell two apart.
    struct AppInstance: Equatable, Hashable {
        let pid: pid_t
        let bundleID: String
        let name: String
        let url: URL?
    }

    /// Observed, not ignored. A launcher draws unlit when its app is not in this
    /// set, and the set starts empty — so with the view unable to see it change,
    /// a pin for a running app stayed faded until something *else* happened to
    /// force a redraw. Assignment is guarded by equality because `@Observable`
    /// notifies on every assignment regardless of value, and this is rebuilt
    /// twice a second.
    private(set) var runningApps = RunningApps()
    @ObservationIgnored private var runningAppsSampledAt = Date.distantPast

    /// Rate-limited: app launches and quits are rare compared with refreshes, and
    /// the engine already forces a refresh on both, so a short staleness window
    /// costs nothing visible.
    func sampleRunningApps(windowOwnerPIDs: Set<pid_t>, force: Bool = false) {
        guard force || Date().timeIntervalSince(runningAppsSampledAt) >= 1.5 else { return }
        runningAppsSampledAt = Date()

        var sample = RunningApps()
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier else { continue }
            sample.all.insert(bundleID)
            sample.livePIDs.insert(app.processIdentifier)
            if app.activationPolicy == .regular { sample.dockApps.insert(bundleID) }
            if windowOwnerPIDs.contains(app.processIdentifier) {
                sample.withWindows.insert(bundleID)
            } else if app.activationPolicy == .regular {
                // Judged per process: another copy of the same application having
                // a window says nothing about this one.
                sample.windowless.append(AppInstance(
                    pid: app.processIdentifier,
                    bundleID: bundleID,
                    name: app.localizedName ?? bundleID,
                    url: app.bundleURL
                ))
            }
        }
        // Stable order, so the row does not reshuffle between samples.
        sample.windowless.sort {
            $0.name == $1.name ? $0.pid < $1.pid
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        if sample != runningApps { runningApps = sample }
    }

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
    /// When each window was last seen alive, so a slot can be told from a relic.
    @ObservationIgnored private var lastSeenAt: [CGWindowID: Date] = [:]
    /// The capsule last known to be worked in.
    ///
    /// Focus is the source of truth, but focus is not always on a window the
    /// strip draws — clicking the desktop focuses Finder with nothing open, and
    /// a launching application is frontmost before it has a window. This holds
    /// the last real answer so those moments do not silently move you to Main.
    @ObservationIgnored private var lastActiveWindowID: CGWindowID?
    /// How long after a focus change that change is still assumed to be an
    /// application raising its own window rather than something the user did.
    /// See `captureTarget` for the measurements behind the value.
    private static let activationRaise: TimeInterval = 0.15
    /// When focus last moved to a window the strip draws. Only used to tell a
    /// deliberate switch from the raise an application does when it activates.
    @ObservationIgnored private var lastFocusChangeAt = Date.distantPast
    /// Set when a capsule is acted on directly rather than by focus — clicking a
    /// launcher inside it. Cleared as soon as focus lands on a real window again,
    /// so it can never outlive the action that set it.
    @ObservationIgnored private var lastActiveGroupOverride: UUID?

    /// How long after launch to keep trying to rematch saved members. Generous,
    /// because a reboot reopens applications gradually.
    private static let restoreWindow: TimeInterval = 300
    /// Extension granted when a new application launches, so a late starter is
    /// still caught after the initial window lapses.
    private static let restoreExtension: TimeInterval = 60

    init() {
        groups = [DeckGroup(name: "Main", isMain: true)]
        loadPersisted()
    }

    // MARK: - Derived

    /// The fallback capsule. Every window no other group claims is drawn here,
    /// so its membership is never written down — see `DeckGroup.isMain`.
    var main: DeckGroup { groups.first(where: \.isMain) ?? groups[0] }

    /// The group being worked in: the one holding the focused window.
    ///
    /// **Derived, never chosen.** There is no switching left, and this is not a
    /// selection — it is simply where you are. It decides one thing, which is
    /// where a newly opened window lands, and it is read by the operations that
    /// need a default target (a new pin, cluster or stack) and by the strip,
    /// which tints that capsule so you can see where the next window will go.
    ///
    /// It is a computed property on purpose. The retired `activeGroupID` was a
    /// stored selection that the strip, the cluster operations and the cycling
    /// shortcuts each read as "the group being acted on", and it could disagree
    /// with what was on screen — which it did, in all three.
    /// Records that a capsule was acted on directly — clicking a launcher in it.
    ///
    /// This is what makes "clicking Work's launcher opens the window in Work" true
    /// *without* an exception in the placement rule. The click does not place the
    /// window; it changes which capsule is active, and the ordinary rule then puts
    /// the window where you are. Stated by the user as "I clicked Work's launcher,
    /// so technically Work becomes active. No inconsistency to rule."
    func noteWorkingIn(_ groupID: UUID) {
        guard groups.contains(where: { $0.id == groupID }) else { return }
        lastActiveGroupOverride = groupID
    }

    /// Focus on something that is not a window in a capsule — you clicked the
    /// desktop, or an application is launching and has not drawn its window yet —
    /// leaves the last capsule genuinely worked in active. Clicking the desktop
    /// is not an instruction to change capsules, and a new window opened straight
    /// after must not be exiled to Main because of it.
    var activeGroup: DeckGroup {
        // A capsule acted on directly outranks the window that happens to hold
        // focus. Clicking Work's launcher is a statement about where you are
        // working; the window still focused behind it is not, and it is cleared
        // the moment focus lands anywhere real — including on the window the
        // click just opened.
        if let lastActiveGroupOverride,
           let group = groups.first(where: { $0.id == lastActiveGroupOverride }) {
            return group
        }
        if let focusedWindowID, windows.contains(where: { $0.id == focusedWindowID }) {
            return group(of: focusedWindowID)
        }
        // The last window worked in, with its capsule resolved *now* rather than
        // recorded when focus landed on it. Storing the resolved group went stale
        // the moment that window was moved elsewhere: the ring jumped back to the
        // capsule it had left, and the next window opened followed it there.
        //
        // Deliberately not conditioned on the window still being open — this is
        // the answer for when focus is on nothing, which is exactly when it may
        // have closed. `group(of:)` reads membership, which outlives the window.
        if let lastActiveWindowID { return group(of: lastActiveWindowID) }
        return main
    }

    var activeGroupID: UUID { activeGroup.id }

    /// Which capsule a window is drawn in. Exactly one, always: a specific group
    /// if one claims it, Main otherwise.
    func group(of windowID: CGWindowID?) -> DeckGroup {
        guard let windowID else { return main }
        return groups.first { !$0.isMain && $0.memberIDs.contains(windowID) } ?? main
    }

    /// Every window the strip draws. The whole strip is on screen at once now,
    /// so this is the live window list itself.
    var visibleWindows: [WindowInfo] { windows }

    /// The windows drawn inside one capsule. Main's are the ones nothing else
    /// claims — the complement, computed rather than stored.
    func windows(in group: DeckGroup) -> [WindowInfo] {
        guard group.isMain else { return windows.filter { group.memberIDs.contains($0.id) } }
        return windows.filter { window in
            !groups.contains { !$0.isMain && $0.memberIDs.contains(window.id) }
        }
    }

    /// Items the user has arranged by hand lead, in that order; anything else
    /// is placed beside the windows of its own application. Operates on item
    /// keys so a pinned app and a window can sit next to each other in one
    /// arrangement.
    ///
    /// **A newly opened window has no key at all.** Nothing writes one —
    /// `captureNewWindows` files it into a group's membership and stops there,
    /// and a key is only minted by a drag, by `stackApp` or by the restore pass.
    /// So an unranked item used to be sent to the end of the row, which put a
    /// second Finder window at the far right of the capsule while the first sat
    /// wherever the arrangement had it.
    ///
    /// That is invisible until it is not: with an *empty* order the default sort
    /// already groups by application (`AXSweeper` sorts by app name then title),
    /// so a fresh install reads perfectly. The order is non-empty in every
    /// session after the first, because the restore pass rebuilds it from
    /// `savedOrder` — which is exactly when the app-grouped default stops
    /// applying and the windows of one app scatter.
    ///
    /// Nothing here is persisted: the item still has no key, so there is no new
    /// `OrderRef` case, nothing to prune when the window closes, and an
    /// arrangement the user *made* still wins outright — two windows of one app
    /// dragged to opposite ends are both ranked, and neither moves.
    private func applyManualOrder(_ items: [DeckItem], order: [String]) -> [DeckItem] {
        guard !order.isEmpty else { return items }
        var rank: [String: Int] = [:]
        for (index, key) in order.enumerated() { rank[key] = index }

        var placed = items
            .filter { rank[$0.orderKey] != nil }
            .sorted { rank[$0.orderKey, default: 0] < rank[$1.orderKey, default: 0] }

        // Searched against the *growing* list rather than the ranked items
        // alone, so several new windows of one app land behind the first in the
        // order they were given rather than all on top of the same anchor.
        for item in items where rank[item.orderKey] == nil {
            if let anchor = placed.lastIndex(where: { $0.sharesApp(with: item) }) {
                placed.insert(item, at: anchor + 1)
            } else {
                placed.append(item)
            }
        }
        return placed
    }

    /// Moves one item to sit where another currently is, inside one capsule.
    /// Keys rather than window ids, so a pin can be dragged among windows.
    ///
    /// `groupID` is the arrangement being edited — the capsule the drag happened
    /// in, which is never assumed. Every capsule honours its own group's order,
    /// and writing to some notion of "the current group" instead is the mistake
    /// that made drags in one capsule reorder another.
    func moveItem(_ key: String, before target: String, in groupID: UUID) {
        guard key != target,
              let index = groups.firstIndex(where: { $0.id == groupID })
        else { return }

        // Seed from what's on screen right now, so the first drag nudges one
        // entry instead of reshuffling the whole strip. Launchers currently
        // hidden behind an open window of the same app are seeded too, in the
        // pins-first position they default to — without that, the first drag in
        // a group would silently condemn them to the end of the row when they
        // came back.
        var order = groups[index].order
        if order.isEmpty { order = seededOrder(forGroupAt: index) }

        // Which way the drag is going, decided *before* the key is pulled out.
        // Inserting only ever before the target made the last position
        // unreachable: dropping on the rightmost tile put you to its left, so a
        // tile could never be dragged to the end of a row.
        let movingRight: Bool
        if let from = order.firstIndex(of: key), let to = order.firstIndex(of: target) {
            movingRight = from < to
        } else {
            movingRight = false
        }

        order.removeAll { $0 == key }
        if let targetIndex = order.firstIndex(of: target) {
            order.insert(key, at: movingRight ? targetIndex + 1 : targetIndex)
        } else {
            order.append(key)
        }
        groups[index].order = order
        // Debounced rather than immediate: this fires repeatedly as a drag
        // passes over each neighbour.
        scheduleSave()
    }

    /// One capsule's contents, in the order it draws them.
    ///
    /// Every step here is load-bearing and the sequence is the point:
    ///
    /// 1. clusters fold, then app stacks fold over *their output* — a hand-made
    ///    cluster outranks a blanket rule about an application, and folding
    ///    stacks first swallows the cluster whole;
    /// 2. launchers are computed against the folded items, so a stacked app
    ///    hides its own launcher exactly as a loose window does;
    /// 3. the group's own manual arrangement is applied over the combined list,
    ///    because a capsule honours its own order and nothing else's.
    ///
    /// Building a section's items any other way is a mistake this project has
    /// made three times — each one drew a launcher beside the very window it
    /// would have opened.
    /// `launchersElsewhere` is gone: an application has exactly one launcher and
    /// `launcherHome` already says which capsule holds it, so there is no longer a
    /// cross-capsule check for Main to make. Every capsule answers for itself.
    private func items(in group: DeckGroup) -> [DeckItem] {
        let members = windows(in: group)
        let folded = foldAppStacks(foldClusters(members, in: group), in: group)
        let launchers = pins(alongside: folded, in: group)
            + runningLaunchers(for: group, folded: folded)
        return applyManualOrder(launchers + folded, order: group.order)
    }

    /// The group's launchers, minus any whose app already has a window here.
    ///
    /// A launcher's whole job is "open this". Once a window of that app is on
    /// screen in this capsule, the window entry does that job, and showing both
    /// put two identical icons side by side with no way to tell which was which.
    /// The pin keeps its place in the manual arrangement while hidden, so it
    /// returns where you put it once the last such window closes or leaves.
    private func pins(alongside items: [DeckItem], in group: DeckGroup) -> [DeckItem] {
        let present = Set(items.flatMap { $0.windows.compactMap(\.bundleID) })
        return group.pinnedApps
            .filter { !present.contains($0.bundleID) }
            .map { DeckItem.pinned($0) }
    }

    /// The single launcher an application gets while it is running with no window
    /// of its own on show, and which capsule holds it.
    ///
    /// Stateful on purpose, and this is the one place in the strip that is. Every
    /// other item is recomputed from `windows` on each redraw, but a launcher is
    /// defined by *moments* rather than by the present: it comes into being when
    /// an application's last window anywhere closes, and it stays put until the
    /// capsule holding it gets a real window of that application back. Derived
    /// fresh each time, it would migrate to whichever capsule closed a window most
    /// recently — which is the opposite of standing still.
    ///
    /// Not persisted, and must not be. A launcher *is* "this capsule holds a slot
    /// for an application whose window is gone", and both the slot and its place
    /// in the row are already on disk as a dead member reference and its
    /// `OrderRef`. Adding a field for it would buy nothing but the one category of
    /// change that has silently wiped the state file before.
    @ObservationIgnored private var launcherHome: [pid_t: LauncherSlot] = [:]

    /// Where an application's launcher lives, and which process it stands for.
    ///
    /// The instance is held rather than looked up on demand: a launcher outlives
    /// its application's presence in `runningApps.windowless` — that list is
    /// "running with nothing open", and a sticky launcher's app may well have
    /// opened a window in some other capsule since. Re-deriving it from that list
    /// made the icon vanish the moment the window server reported any window for
    /// the pid, which is the sticky rule's whole point defeated by a lookup.
    private struct LauncherSlot {
        var groupID: UUID
        var instance: AppInstance
        /// Resolved once, when the launcher is born.
        ///
        /// Building it is `Bundle(url:)` plus `FileManager.displayName(atPath:)` —
        /// a bundle read and a LaunchServices round trip — and it was being redone
        /// for every launcher, in every capsule, on every `sections()` call, of
        /// which there are four per redraw. Exactly the shape of the `menuSized`
        /// trap: `AppIconCache` memoises the icon and says so, and the layer above
        /// it was doing filesystem work on the redraw path regardless.
        var app: PinnedApp
    }

    /// Brings `launcherHome` up to date. Called once per refresh, before the
    /// strip is built, because all three rules are about transitions.
    func updateLaunchers() {
        let selfID = Bundle.main.bundleIdentifier

        // Keyed by process throughout, never by bundle id. Two copies of one
        // application on disk run as two processes sharing a bundle id, the Dock
        // draws an icon for each, and asking any of these questions of the bundle
        // collapses them into one — the trap "a bundle id is not a running
        // application" records exactly that, measured on two Slacks.
        launcherHome = launcherHome.filter { runningApps.livePIDs.contains($0.key) }

        // Rule 3: a launcher stays until *its own* capsule gets a real window of
        // that process back. Windows opening in another capsule are none of its
        // business — that is what makes it stand still.
        for (pid, slot) in launcherHome {
            guard let group = groups.first(where: { $0.id == slot.groupID }) else {
                launcherHome[pid] = nil
                continue
            }
            if windows(in: group).contains(where: { $0.pid == pid }) { launcherHome[pid] = nil }
        }

        guard showRunningApps else { return }

        // Rules 1 and 2: one is created when a process's last window closes, and
        // never if that process already has one. `runningApps.windowless` is
        // already judged per process — it means "this pid owns no window on any
        // Space" — so it is the whole test. An earlier version also required the
        // *bundle* to have no live window, which is the same mistake in a
        // different place: the copy whose window was closed was suppressed by the
        // other copy's window.
        for instance in runningApps.windowless where instance.bundleID != selfID {
            guard launcherHome[instance.pid] == nil,
                  let home = launcherBirthplace(of: instance),
                  let app = Self.pinnedApp(for: instance)
            else { continue }
            launcherHome[instance.pid] = LauncherSlot(groupID: home, instance: instance, app: app)
        }
    }

    /// Which capsule a process's launcher is born in: the one whose window of it
    /// survived longest.
    ///
    /// `lastSeenAt` answers that directly within a session. Across a restart it is
    /// empty and two capsules can both hold a stale slot for one application, with
    /// nothing on disk to say which won — so the first in strip order takes it.
    /// Accepted rather than persisted: it is rare, and it corrects itself the next
    /// time a window of that application closes.
    private func launcherBirthplace(of instance: AppInstance) -> UUID? {
        let live = Set(windows.map(\.id))
        var best: (id: UUID, seen: Date)?

        // Every window of this application that has been seen and is now gone,
        // whichever capsule it was in. Main has to be judged here too, and by the
        // same measure: reading only the named groups' membership would miss that
        // Main held the window which survived longest, and the launcher would be
        // born in whichever named capsule closed *first* — the opposite of the
        // rule. Main's windows are the ones no named group claims, which is the
        // same complement the strip draws it from.
        //
        // Matched on bundle id rather than pid deliberately, and it is the one
        // place that is right: `knownRefs` describes windows that are gone, and a
        // relaunched application is a new process, so a pid would match nothing
        // after a restart. Which *process* the launcher stands for is settled by
        // the caller; this only answers where it belongs.
        for (id, ref) in knownRefs where ref.bundleID == instance.bundleID && !live.contains(id) {
            let owner = groups.first { !$0.isMain && $0.memberIDs.contains(id) }?.id ?? main.id
            let seen = lastSeenAt[id] ?? .distantPast
            if best == nil || seen > best!.seen { best = (owner, seen) }
        }

        // Nothing of this application has ever been seen — it was already running
        // with no windows when WindowDeck started. Main is where a window lives
        // when nothing else claims it, so that is where its launcher belongs.
        return best?.id ?? main.id
    }

    /// The launchers one capsule draws: the applications whose single launcher
    /// lives here.
    ///
    /// `folded` decides only *whether* a launcher is drawn, never where it lives —
    /// an application with a window on show in this capsule is already represented
    /// by that window, and two identical icons side by side with nothing to tell
    /// them apart is what this guard exists to prevent.
    private func runningLaunchers(for group: DeckGroup, folded: [DeckItem]) -> [DeckItem] {
        guard showRunningApps else { return [] }

        // Before any set building: most capsules hold no launcher at all, and this
        // runs once per capsule on each of the four `sections()` calls a redraw
        // makes.
        let mine = launcherHome.filter { $0.value.groupID == group.id }
        guard !mine.isEmpty else { return [] }

        // A live window of the *same process* here already represents it. Asked
        // per pid, not per bundle: two copies of one application are two icons,
        // and one copy's window must not stand in for the other's.
        let present = Set(folded.flatMap { $0.windows.map(\.pid) })
        // A pinned application is drawn by `pins(alongside:)`, which knows nothing
        // about launchers — so without this the capsule draws the pin and the
        // launcher as two identical icons side by side, which is the very thing
        // the pin-hiding rule exists to prevent. Worse in Main, where the launcher
        // has no member slot and falls back to `p<bundleID>` — the pin's own order
        // key — so both would rank identically and the duplicate would persist.
        let pinned = Set(group.pinnedApps.map(\.bundleID))

        // The closed member window this launcher stands in for, so it keeps the
        // position that window held in the manual arrangement. The *most recently
        // seen* of them: dead ids accumulate one per closed window while the
        // application runs, and taking whichever the set happened to yield first
        // put the launcher at the position of a long-gone window rather than the
        // one just closed.
        var slotFor: [String: (id: CGWindowID, seen: Date)] = [:]
        if !group.isMain {
            let live = Set(windows.map(\.id))
            for id in group.memberIDs where !live.contains(id) {
                guard let ref = knownRefs[id] else { continue }
                let seen = lastSeenAt[id] ?? .distantPast
                if let held = slotFor[ref.bundleID], held.seen >= seen { continue }
                slotFor[ref.bundleID] = (id, seen)
            }
        }

        return mine
            .filter { !present.contains($0.key) && !pinned.contains($0.value.app.bundleID) }
            .sorted { ($0.value.app.name, $0.key) < ($1.value.app.name, $1.key) }
            .map { _, slot in
                DeckItem.running(slot.app, placeholderFor: slotFor[slot.app.bundleID]?.id,
                                 instance: slot.instance)
            }
    }

    /// The single description of what the strip draws: one capsule per group,
    /// Main first, each honouring its own arrangement.
    var sections: [DeckSection] { sections(includingCollapsed: false) }

    /// `includingCollapsed` is what the overflow panel asks for: the same row,
    /// with nothing folded away.
    func sections(includingCollapsed: Bool) -> [DeckSection] {
        // Still built for *every* named group, collapsed ones included: a
        // collapsed capsule owns its windows even though it is not drawn, and
        // `switchEntries()` reads this list with `includingCollapsed: true`.
        let others = groups.filter { !$0.isMain }.map { ($0, items(in: $0)) }

        var sections: [DeckSection] = []
        let mainItems = items(in: main)
        if !mainItems.isEmpty {
            sections.append(DeckSection(id: main.id.uuidString, groupID: main.id,
                                        color: main.displayColor,
                                        dividerBefore: false, items: mainItems))
        }
        for (group, items) in others {
            if group.isCollapsed && !includingCollapsed { continue }
            guard !items.isEmpty else { continue }
            sections.append(DeckSection(id: group.id.uuidString, groupID: group.id,
                                        color: group.displayColor,
                                        dividerBefore: false, items: items))
        }
        return sections
    }

    /// What a drag from one capsule to another means.
    ///
    /// A window *moves*: it joins the target group and leaves the one it came
    /// from, because it can only be in one. Dropping into Main is the same
    /// operation seen from the other side — `add` clears every other membership,
    /// and Main's own is implicit, so the window simply stops being claimed.
    /// Pins are copied and removed the same way, except that a pin genuinely can
    /// exist in two capsules, so only the source it was dragged from is cleared.
    func moveItem(_ key: String, from source: UUID, to target: UUID) {
        guard source != target else { return }

        if key.hasPrefix("w"), let windowID = CGWindowID(key.dropFirst()) {
            add(windowID, to: target)
            return
        }

        if key.hasPrefix("p") {
            let bundleID = String(key.dropFirst())
            pinApp(bundleID: bundleID, in: target)
            unpin(bundleID, in: source)
        }
    }

    /// Folds a group's clusters into its window list, leaving loose windows alone.
    private func foldClusters(_ windows: [WindowInfo], in group: DeckGroup) -> [DeckItem] {
        guard !group.clusters.isEmpty else { return windows.map { .window($0) } }
        var consumed: Set<CGWindowID> = []
        var items: [DeckItem] = []
        for window in windows where !consumed.contains(window.id) {
            guard let cluster = group.clusters.first(where: { $0.contains(window.id) }) else {
                items.append(.window(window)); consumed.insert(window.id); continue
            }
            let members = cluster.memberIDs.compactMap { id in windows.first { $0.id == id } }
            guard members.count >= 2 else {
                items.append(.window(window)); consumed.insert(window.id); continue
            }
            items.append(.cluster(cluster, members))
            consumed.formUnion(members.map(\.id))
        }
        return items
    }

    /// Collapses each stacked application's loose windows behind one icon.
    ///
    /// Runs **over the output of `foldClusters`** and touches only `.window`
    /// items, which is what stops the two features fighting over one window: a
    /// window the user deliberately clustered stays in its cluster even when its
    /// application is also stacked. Clusters are hand-made and specific; a stack
    /// is a blanket rule, so the specific one wins.
    ///
    /// The stack takes the position of its **leftmost** member, so collapsing
    /// five Chrome windows leaves the icon where the first of them was rather
    /// than moving the row around.
    private func foldAppStacks(_ items: [DeckItem], in group: DeckGroup) -> [DeckItem] {
        // Runs on every redraw, so it must cost nothing in the common case of no
        // stacks at all — the same guard `pruneClusters` carries and for the same
        // reason.
        guard !group.stackedAppBundleIDs.isEmpty else { return items }

        // How many loose windows each stacked app has here. A stack needs two:
        // with one window left it is indistinguishable from an ordinary entry,
        // so it renders as one. The *rule* is untouched by this — closing four
        // of five Chrome windows and reopening them re-stacks them, which is the
        // failure mode clusters had.
        var counts: [String: Int] = [:]
        for case .window(let window) in items {
            guard let bundleID = window.bundleID,
                  group.stackedAppBundleIDs.contains(bundleID) else { continue }
            counts[bundleID, default: 0] += 1
        }
        let stacking = Set(counts.filter { $0.value >= 2 }.keys)
        guard !stacking.isEmpty else { return items }

        var result: [DeckItem] = []
        var placed: Set<String> = []
        for item in items {
            guard case .window(let window) = item,
                  let bundleID = window.bundleID, stacking.contains(bundleID)
            else { result.append(item); continue }

            // Only the first one produces the tile; the rest are absorbed.
            guard !placed.contains(bundleID) else { continue }
            placed.insert(bundleID)
            let members = items.compactMap { entry -> WindowInfo? in
                guard case .window(let candidate) = entry,
                      candidate.bundleID == bundleID else { return nil }
                return candidate
            }
            result.append(.appStack(bundleID: bundleID, windows: members))
        }
        return result
    }

    /// Fired with the window that just *stopped* being focused. That instant is
    /// when its content is final, and it is exactly the state a switcher should
    /// show later — so it is the right moment to snapshot it, and it costs one
    /// capture per switch rather than a polling loop.
    @ObservationIgnored var onWindowLostFocus: ((WindowInfo) -> Void)?

    private func noteFocusForMRU(_ id: CGWindowID?, previous: CGWindowID?) {
        guard let id, id != previous else { return }
        // Only a window that is actually on the strip updates where you are
        // working. Focus landing on something the strip does not draw says
        // nothing about which capsule you are in, so the last real answer stands.
        if windows.contains(where: { $0.id == id }) {
            lastActiveWindowID = id
            lastFocusChangeAt = Date()
            lastActiveGroupOverride = nil
        }
        mruOrder.removeAll { $0 == id }
        mruOrder.insert(id, at: 0)
        // Bounded: without this it accumulates every window ever focused.
        if mruOrder.count > 200 { mruOrder.removeLast(mruOrder.count - 200) }

        if let previous, let window = windows.first(where: { $0.id == previous }) {
            onWindowLostFocus?(window)
        }
    }

    /// Cycling candidates: the windows of the capsule you are standing in.
    ///
    /// Scoped to that capsule and nothing wider. The strip shows every window at
    /// once, so an unscoped cycle would offer the whole bar — and only one
    /// capsule is the one being worked in. A folded capsule still scopes: it
    /// still owns its windows even though it is not drawn, and widening the
    /// cycle the moment a group is collapsed would be a surprise.
    ///
    /// Ordered by `cycleOrder`: most recently used with the current window
    /// leading, or the strip's own arrangement with positions left where they
    /// are. Anything never focused this session still appears, after the windows
    /// that have been — so a freshly opened group is navigable rather than empty.
    func cycleCandidates(appOnly: Bool) -> [WindowInfo] {
        // The capsule's own group, which is also whose arrangement `.stripOrder`
        // sorts by: every capsule honours its own order, so scoping to one has
        // to take that arrangement with it or the switcher would list its
        // windows in some other capsule's order.
        let orderGroup = activeGroup
        var pool = windows(in: orderGroup)

        if appOnly {
            // Resolved against every tracked window, not the group's. Looking it
            // up in the group made the shortcut a silent no-op whenever the
            // window you were in wasn't a member of the group on show — which is
            // most of the time once you have groups.
            guard let focusedWindowID,
                  let current = windows.first(where: { $0.id == focusedWindowID })
            else { return [] }

            let withinCapsule = pool.filter { $0.pid == current.pid }
            // The capsule always holds the window you are standing in, so the
            // only question left is what to do when it holds *only* that one:
            // stay put and do nothing, or widen to every window the app has open
            // anywhere on the strip. That is the whole of `appCycleStaysInGroup`
            // now — the scope itself is no longer in doubt, because a window is
            // drawn in exactly one capsule.
            if withinCapsule.count > 1 || appCycleStaysInGroup {
                pool = withinCapsule
            } else {
                pool = windows.filter { $0.pid == current.pid }
            }
        }

        switch cycleOrder {
        case .recentlyUsed:
            return byRecency(pool)
        case .stripOrder:
            // Reuses the strip's single description of "what order this group is
            // drawn in", so the switcher and the strip cannot drift apart.
            //
            // The current window is deliberately **not** hoisted to index 0 here.
            // Doing that is what makes positions move between opens, which is the
            // whole point of this mode — the list stays put and only the starting
            // highlight moves. `cycleStartIndex` is where that lives.
            return applyManualOrder(pool.map { .window($0) }, order: orderGroup.order)
                .compactMap { if case .window(let w) = $0 { w } else { nil } }
        }
    }

    private func byRecency(_ pool: [WindowInfo]) -> [WindowInfo] {
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

    // MARK: - Switching between things on the strip

    /// Everything ⌥Tab can switch to, most recently used first.
    ///
    /// Built straight from `sections(includingCollapsed: true)` — the same list
    /// the strip draws — so the switcher and the bar can never disagree about
    /// what an entry *is*. Two things about that are decisions:
    ///
    /// * **Collapsed capsules are included.** Mirroring the strip means the same
    ///   grouping, not the same visibility. A folded capsule still owns its
    ///   windows, and making them unreachable from the keyboard the moment a
    ///   group is folded would be a trap rather than a simplification.
    /// * **A launcher is listed only when its application is running.** A
    ///   running app with no windows is exactly what ⌘Tab shows, so it belongs.
    ///   One that is not running does not: releasing the key while passing over
    ///   it would *launch* something, which is not what a switcher is for.
    func switchEntries() -> [SwitchEntry] {
        var entries: [SwitchEntry] = []

        for section in sections(includingCollapsed: true) {
            guard let groupID = section.groupID,
                  let group = groups.first(where: { $0.id == groupID }) else { continue }

            for item in section.items {
                let id = "\(section.id)/\(item.id)"
                switch item {
                case .window(let window):
                    entries.append(SwitchEntry(
                        id: id, item: item, groupID: groupID, groupName: group.name,
                        groupColor: group.displayColor, title: window.appName,
                        icon: window.icon, windows: [window]))

                case .appStack(let bundleID, let members):
                    entries.append(SwitchEntry(
                        id: id, item: item, groupID: groupID, groupName: group.name,
                        groupColor: group.displayColor,
                        title: members.first?.appName ?? bundleID,
                        icon: members.first?.icon, windows: members))

                case .cluster(let cluster, let members):
                    entries.append(SwitchEntry(
                        id: id, item: item, groupID: groupID, groupName: group.name,
                        groupColor: group.displayColor,
                        title: cluster.customName?.isEmpty == false
                            ? cluster.customName! : cluster.displayName(resolving: members),
                        icon: members.first?.icon, windows: members))

                case .pinned(let app), .running(let app, _, _):
                    guard runningApps.all.contains(app.bundleID) else { continue }
                    entries.append(SwitchEntry(
                        id: id, item: item, groupID: groupID, groupName: group.name,
                        groupColor: group.displayColor, title: app.name,
                        icon: app.icon, windows: []))
                }
            }
        }

        return orderedByRecency(entries)
    }

    /// Most-recently-used, ranked by each entry's best window.
    ///
    /// The same `mruOrder` the strip and `stackWindowsByRecency` use, so the
    /// switcher cannot disagree with a tile about which window is most recent.
    /// Entries with no windows — running launchers — have no recency to rank by
    /// and sort last, in strip order.
    private func orderedByRecency(_ entries: [SwitchEntry]) -> [SwitchEntry] {
        var rank: [CGWindowID: Int] = [:]
        for (index, id) in mruOrder.enumerated() { rank[id] = index }
        func best(_ entry: SwitchEntry) -> Int {
            entry.windows.compactMap { rank[$0.id] }.min() ?? Int.max
        }

        let ordered = entries.enumerated().sorted { lhs, rhs in
            let l = best(lhs.element), r = best(rhs.element)
            return l == r ? lhs.offset < rhs.offset : l < r
        }.map(\.element)

        // The entry you are in goes to index 0 *explicitly* rather than being
        // trusted to rank first, mirroring `byRecency` and guarding the same
        // race: `mruOrder` only leads with the focused window once that focus
        // has been *recorded*, and the switcher opening a fraction early is what
        // once made it lead with the wrong window. In-process the store cannot
        // produce that state — every focus change updates `mruOrder` — so the
        // self-test pins the property this produces, not this line.
        guard let focusedWindowID,
              let here = ordered.firstIndex(where: { $0.windows.contains { $0.id == focusedWindowID } })
        else { return ordered }

        var result = ordered
        let current = result.remove(at: here)
        result.insert(current, at: 0)
        return result
    }

    /// What committing an entry does. Resolved here rather than in the switcher
    /// so the choice is testable without a run loop, and so a stack picks its
    /// window through the same recency the tile draws.
    func commitTarget(for entry: SwitchEntry) -> SwitchEntry.Commit {
        switch entry.item {
        case .window(let window):
            return .focus(window.id)
        case .appStack:
            // One window, not all of them — the whole point of a stack, and the
            // same thing clicking the tile does.
            guard let first = stackWindowsByRecency(entry.windows).first else { return .none }
            return .focus(first.id)
        case .cluster(_, let members):
            // All of them, together: a cluster is a set someone assembled by
            // hand, and clicking it raises the set.
            return members.isEmpty ? .none : .focusAll(members.map(\.id))
        case .pinned(let app), .running(let app, _, _):
            return .open(app.bundleID)
        }
    }

    /// Where the first tap lands.
    ///
    /// The two orders disagree, and the difference used to be a literal `1` in
    /// `SwitcherController` that silently assumed index 0 was the window you are
    /// already in. That holds only for `.recentlyUsed`, so the assumption has to
    /// live next to the ordering that makes it true.
    func cycleStartIndex(_ candidates: [WindowInfo], reversed: Bool) -> Int {
        let count = candidates.count
        guard count > 1 else { return 0 }

        switch cycleOrder {
        case .recentlyUsed:
            // Index 0 is the window you are already in, so the first tap lands
            // on the one before it.
            return reversed ? count - 1 : 1
        case .stripOrder:
            // The neighbour of wherever you are standing, wrapping. Cycling into
            // a group you are not in has no current position, so it starts at the
            // near end rather than nowhere.
            guard let focusedWindowID,
                  let here = candidates.firstIndex(where: { $0.id == focusedWindowID })
            else { return reversed ? count - 1 : 0 }
            return ((here + (reversed ? -1 : 1)) % count + count) % count
        }
    }


    /// Capsules a window can be filed into. All of them, Main included — filing
    /// into Main is how a window is taken out of a group.
    var assignableGroups: [DeckGroup] { groups }

    /// Each group carries its own launchers.
    var visiblePinnedApps: [PinnedApp] {
        activeGroup.pinnedApps
    }

    /// The capsule a window is drawn in, for a badge in Settings and the menus.
    /// One group, never a list: that is the model.
    func memberGroup(of windowID: CGWindowID) -> DeckGroup { group(of: windowID) }

    /// Whether a shortcut actually registered. Populated by HotKeyManager, since
    /// macOS keeps some combinations for itself and a dead key must be visible
    /// in Settings rather than silently doing nothing. Observed, so Settings
    /// redraws when registrations change.
    var registeredActions: Set<ShortcutAction> = []

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
        [.cycleGroupWindows: .defaultGroupCycle,
         .cycleEntries: .defaultEntryCycle]
    }

    // MARK: - Membership

    // Membership changes save immediately rather than on the debounce. They are
    // infrequent, they are the thing most expensive to lose, and the app is
    // routinely killed rather than quit during development.

    /// Files a window into one capsule, which is the only one it can be in.
    ///
    /// Clearing every other membership is the whole operation, not a tidy-up
    /// afterwards: a window drawn in two capsules is the shape of several past
    /// bugs, and the single place that can create one is here. Filing *into*
    /// Main is the same call with nothing left to add — Main's membership is
    /// implicit, so a window nothing claims is already in it.
    func add(_ windowID: CGWindowID, to groupID: UUID) {
        guard let target = groups.first(where: { $0.id == groupID }) else { return }
        for index in groups.indices where groups[index].id != groupID {
            groups[index].memberIDs.remove(windowID)
        }
        if !target.isMain, let index = groups.firstIndex(where: { $0.id == groupID }) {
            groups[index].memberIDs.insert(windowID)
        }
        Trace.log(.member, "file window \(windowID) into \(target.name)"
            + (target.isMain ? " (implicit)" : " (now \(groups.first { $0.id == groupID }?.memberIDs.count ?? 0) members)"))
        saveNow()
    }

    /// Takes a window out of a group, which returns it to Main.
    func remove(_ windowID: CGWindowID, from groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].memberIDs.remove(windowID)
        Trace.log(.member, "remove window \(windowID) from \(groups[index].name) "
            + "(now \(groups[index].memberIDs.count) members) — back to Main")
        saveNow()
    }

    func toggle(_ windowID: CGWindowID, in groupID: UUID) {
        if isMember(windowID, of: groupID) {
            remove(windowID, from: groupID)
        } else {
            add(windowID, to: groupID)
        }
    }

    /// True when the window is drawn in that capsule — which for Main means
    /// nothing else has claimed it.
    func isMember(_ windowID: CGWindowID, of groupID: UUID) -> Bool {
        group(of: windowID).id == groupID
    }

    // MARK: - Group management

    @discardableResult
    func addGroup(named name: String) -> DeckGroup {
        Trace.log(.group, "new group \"\(name)\"")
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

    /// Clears any custom colour: picking a preset is how you get back to one.
    func setCustomColor(_ color: Color?, for groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].customColorHex = color?.hexString
        scheduleSave()
    }

    func setColor(_ color: GroupColor, for groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].colorIndex = color.rawValue
        // Choosing a preset clears the custom colour, so the swatches always mean
        // what they show rather than being silently overridden.
        groups[index].customColorHex = nil
        scheduleSave()
    }

    func color(for groupID: UUID) -> GroupColor {
        groups.first { $0.id == groupID }?.color ?? .neutral
    }

    func rename(_ groupID: UUID, to name: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].name = name
        scheduleSave()
    }

    func deleteGroup(_ groupID: UUID) {
        // Deleting a group destroys hand-built membership that nothing else can
        // reconstruct, so the log records what was lost and how big it was.
        if let doomed = groups.first(where: { $0.id == groupID }) {
            Trace.warn(.group, "deleting group \"\(doomed.name)\" with \(doomed.memberIDs.count) members, "
                + "\(doomed.clusters.count) clusters, \(doomed.pinnedApps.count) pins")
        }
        // Main cannot be deleted: it is where everything the other capsules do
        // not claim is drawn, so removing it would leave those windows with
        // nowhere to be.
        guard let index = groups.firstIndex(where: { $0.id == groupID }), !groups[index].isMain else { return }
        groups.remove(at: index)
        scheduleSave()
    }

    /// Main is pinned to index 0; the other capsules reorder freely after it.
    func moveGroups(from source: IndexSet, to destination: Int) {
        var reordered = groups
        reordered.move(fromOffsets: source, toOffset: destination)
        if let mainIndex = reordered.firstIndex(where: { $0.isMain }), mainIndex != 0 {
            let main = reordered.remove(at: mainIndex)
            reordered.insert(main, at: 0)
        }
        groups = reordered
        scheduleSave()
    }

    // MARK: - Pinned apps

    /// Whether saved window ids are being trusted. Self-test only: id matching
    /// silently does nothing when the file is from another boot, and a test that
    /// did not check would pass with the matcher removed.
    var windowIDsTrustworthyForTesting: Bool { windowIDsTrustworthy }

    /// Ages a window out of the recency window. Self-test only.
    func forgetLastSeenForTesting(_ windowID: CGWindowID) {
        lastSeenAt[windowID] = Date(timeIntervalSinceNow: -3600)
    }

    /// Runs the prune immediately, bypassing its rate limit. Self-test only.
    func forcePruneForTesting() {
        lastPrunedAt = .distantPast
        pruneDeadMembers()
    }

    /// Read and write a group's arrangement directly. Used by the self-test,
    /// which has no way to perform a drag.
    func order(in groupID: UUID) -> [String] {
        groups.first { $0.id == groupID }?.order ?? []
    }

    func setOrder(_ order: [String], in groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].order = order
    }

    /// The capsule to pin this window's app into: the one it is drawn in.
    /// A window is only ever in one, so there is nothing to choose between.
    func pinTarget(for windowID: CGWindowID) -> DeckGroup { group(of: windowID) }

    /// How many windows a capsule is currently showing.
    func windowCount(of group: DeckGroup) -> Int { windows(in: group).count }

    /// Folds a group into the overflow cluster, or brings it back.
    func setCollapsed(_ collapsed: Bool, for groupID: UUID) {
        // Main never folds: it is the capsule everything unclaimed falls into,
        // so hiding it would hide windows with nowhere else to be drawn.
        guard let index = groups.firstIndex(where: { $0.id == groupID }), !groups[index].isMain
        else { return }
        groups[index].isCollapsed = collapsed
        scheduleSave()
    }

    /// Groups folded away, with what each is holding — the dots on the right.
    struct CollapsedGroup: Identifiable {
        let id: UUID
        let name: String
        let color: Color
        let count: Int
    }

    var collapsedGroups: [CollapsedGroup] {
        groups.filter { !$0.isMain && $0.isCollapsed }.map { group in
            CollapsedGroup(
                id: group.id,
                name: group.name,
                color: group.displayColor,
                count: windowCount(of: group)
            )
        }
    }

    /// One entry in the "Group with" menu.
    struct GroupWithTarget: Identifiable {
        let id: String
        let name: String
        /// The app, or how many windows a cluster holds.
        let detail: String
        let icon: NSImage?
        /// The window to merge into; a cluster is joined through any member.
        let windowID: CGWindowID
        let isCluster: Bool
        /// The window being right-clicked. Listed but not selectable, so its
        /// position among the others is visible — the menu is in strip order, and
        /// a gap where you are standing makes that order harder to read.
        let isSelf: Bool
    }

    /// What this window can be merged with, in the order the strip draws them.
    ///
    /// Deliberately not bucketed by application or anything else: the list reads
    /// left to right exactly as the row does, so finding an entry is the same
    /// problem as finding its tile. Any clever reordering means the menu and the
    /// strip disagree about where something is.
    ///
    /// Combining used to be a drag gesture: dwell on a tile for 0.7s and the two
    /// merged. It could not be made to work — every drag reorders the row live,
    /// so the target slid out from under the pointer and the dwell never
    /// completed. A menu has no timing to lose.
    func groupWithTargets(for windowID: CGWindowID, in groupID: UUID?) -> [GroupWithTarget] {
        // The capsule the window is drawn in, unless the caller names one.
        // Clustering is a within-capsule operation: offering windows from
        // another capsule would build a cluster in a group that does not hold
        // them, which is where the "the group on screen is not the group being
        // acted on" bugs came from.
        let group = groupID.flatMap { id in groups.first { $0.id == id } } ?? group(of: windowID)
        let pool = windows(in: group)
        let clusters = group.clusters
        // Members of a cluster are offered through the cluster, not one by one.
        let clustered = Set(clusters.flatMap(\.memberIDs))

        // Position in the group's arrangement, so buckets keep strip order.
        let rank: [String: Int] = group.order.enumerated()
            .reduce(into: [:]) { $0[$1.element] = $1.offset }
        func position(_ id: CGWindowID) -> Int { rank["w\(id)"] ?? Int.max }

        var targets: [GroupWithTarget] = []

        for cluster in clusters {
            guard let first = cluster.memberIDs.first,
                  let member = windows.first(where: { $0.id == first }) else { continue }
            let live = cluster.memberIDs.filter { id in windows.contains { $0.id == id } }.count
            targets.append(GroupWithTarget(
                id: "c\(cluster.id)",
                name: cluster.customName ?? member.appName,
                detail: "\(live) windows",
                icon: member.menuIcon,
                windowID: first,
                isCluster: true,
                isSelf: cluster.contains(windowID)
            ))
        }

        let loose = pool
            .filter { !clustered.contains($0.id) }
            .sorted { position($0.id) < position($1.id) }

        for window in loose {
            targets.append(GroupWithTarget(
                id: "w\(window.id)",
                // Long document titles make every row as wide as the worst one.
                name: window.displayTitle.truncated(to: 34),
                detail: window.appName,
                icon: window.menuIcon,
                windowID: window.id,
                isCluster: false,
                isSelf: window.id == windowID
            ))
        }

        // Strip order throughout. Clusters sit at the position of their first
        // member, which is where the strip draws them too.
        return targets.sorted { position($0.windowID) < position($1.windowID) }
    }

    /// Whether an app is pinned in a capsule.
    ///
    /// The capsule is named rather than defaulted. These three took an optional
    /// meaning Main while `pin`/`unpin` took one meaning the *active* capsule —
    /// two opposite readings of the same nil, kept alive only by the pin menu's
    /// "All" entry, which named a group the strip has not had since it became a
    /// row of capsules.
    func isPinned(_ bundleID: String, in groupID: UUID) -> Bool {
        groups.first { $0.id == groupID }?
            .pinnedApps.contains { $0.bundleID == bundleID } ?? false
    }

    /// Pin or unpin, so one menu shows the state and changes it — the same shape
    /// as the group-membership menu, rather than a one-way "remove" that cannot
    /// tell you where the app is currently pinned.
    func togglePin(_ bundleID: String, in groupID: UUID) {
        if isPinned(bundleID, in: groupID) {
            unpin(bundleID, in: groupID)
        } else {
            pinApp(bundleID: bundleID, in: groupID)
        }
    }

    /// Capsules worth listing when pinning an *app* rather than a window:
    /// wherever it is already pinned, plus the one being worked in. A pin, unlike
    /// a window, legitimately exists in several capsules — the same app can be
    /// worth launching from more than one context.
    func pinTargets(forApp bundleID: String) -> [DeckGroup] {
        var targets = groups.filter { $0.pinnedApps.contains { $0.bundleID == bundleID } }
        if !targets.contains(where: { $0.id == activeGroupID }) {
            targets.append(activeGroup)
        }
        return targets
    }

    /// Pins the application a window belongs to, in a named capsule.
    func pinApp(bundleID: String, in groupID: UUID) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let app = PinnedApp(url: url) else { return }
        pin(app, in: groupID)
    }

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
            // Main's membership is implicit, so it has nothing to restore —
            // a window nothing else claims is already drawn there. Its saved
            // *arrangement* still restores, below.
            if !groups[index].isMain, !groups[index].savedMembers.isEmpty {
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

            // The manual arrangement restores the same way. Applies to Main
            // too, which has no membership but is still hand-ordered.
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
                    case .stacked(let bundleID):
                        // Same: a stack is a *rule* about an application, and
                        // the rule is restored with the group, so its slot can
                        // be taken immediately. It does not wait for the app's
                        // windows the way a `.window` entry does — waiting would
                        // put it behind whatever arrived first, which is the
                        // reshuffle this whole path exists to prevent.
                        let key = "s\(bundleID)"
                        if !order.contains(key) { order.append(key) }
                    case .window(let member):
                        // The same window-id-first matcher membership uses. This
                        // was exact-title only, so an arrangement silently
                        // reshuffled on relaunch whenever a title had moved on —
                        // which for Terminal, browsers and editors is most of
                        // the time.
                        let taken = Set(order.compactMap { key -> CGWindowID? in
                            key.hasPrefix("w") ? CGWindowID(key.dropFirst()) : nil
                        })
                        if let match = candidate(for: member, in: windows, excluding: taken) {
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

    // MARK: - App stacks

    /// The group an app-stack operation acts on.
    ///
    /// Same reasoning as `combine` and `dissolveCluster`: in pill view the
    /// *active* group is always All while the capsule you clicked belongs to
    /// another capsule, so writing to some notion of "the current group" would
    /// put the stack somewhere nothing looks. Four operations had this bug at
    /// once.
    private func stackGroupIndex(_ groupID: UUID?) -> Int? {
        groups.firstIndex { $0.id == (groupID ?? activeGroupID) }
    }

    /// This application's windows *in this group*, as arrangement keys.
    ///
    /// Scoped deliberately. Using every window of the app would write order keys
    /// for windows that are not members, which never render but do accumulate in
    /// the group's persisted arrangement — Chrome with five windows and two of
    /// them in Main would leave three dead keys in Main's order on every
    /// unstack.
    private func stackKeys(_ bundleID: String, at index: Int) -> [String] {
        let ids = Set(windows(in: groups[index]).map(\.id))
        return windows
            .filter { $0.bundleID == bundleID && ids.contains($0.id) }
            .map { "w\($0.id)" }
    }

    func isStacked(_ bundleID: String, in groupID: UUID? = nil) -> Bool {
        guard let index = stackGroupIndex(groupID) else { return false }
        return groups[index].stackedAppBundleIDs.contains(bundleID)
    }

    /// Collapses every window of an application in this group behind one icon.
    func stackApp(bundleID: String, in groupID: UUID? = nil) {
        guard let index = stackGroupIndex(groupID),
              !groups[index].stackedAppBundleIDs.contains(bundleID) else { return }

        // Seed the arrangement before inserting the rule. `applyManualOrder`
        // ranks by key, and an unranked stack has nothing to sit beside — its
        // members' own keys are being removed here — so a brand-new `s<bundle>`
        // key would drop the stack to the far right of the row the instant it
        // was created — the same trap that would have condemned
        // hidden pins to the end on the first drag. Take the leftmost member's
        // place and drop the rest.
        let keys = stackKeys(bundleID, at: index)
        let owned = Set(keys)
        if let first = groups[index].order.firstIndex(where: { owned.contains($0) }) {
            groups[index].order[first] = "s\(bundleID)"
            groups[index].order.removeAll { owned.contains($0) }
        }

        groups[index].stackedAppBundleIDs.insert(bundleID)
        Trace.log(.group, "stack \(bundleID) in \(groups[index].name) "
            + "(\(keys.count) windows)")
        saveNow()
    }

    /// Puts the application's windows back as separate entries.
    func unstackApp(bundleID: String, in groupID: UUID? = nil) {
        guard let index = stackGroupIndex(groupID),
              groups[index].stackedAppBundleIDs.contains(bundleID) else { return }

        // The members reappear where the stack stood, in the order the strip was
        // showing them, rather than all falling to the end of the row.
        let keys = stackKeys(bundleID, at: index)
        if let slot = groups[index].order.firstIndex(of: "s\(bundleID)") {
            groups[index].order.replaceSubrange(slot...slot, with: keys)
        }

        groups[index].stackedAppBundleIDs.remove(bundleID)
        Trace.log(.group, "unstack \(bundleID) in \(groups[index].name)")
        saveNow()
    }

    /// Orders a stack's windows most recently used first.
    ///
    /// Takes the members the tile is actually drawing rather than re-deriving
    /// them from a bundle id. Re-deriving read `windows` — *every* window of that
    /// application, in any group — so a stack of five Chrome windows in Main
    /// opened, listed and offered whichever Chrome window was most recent
    /// anywhere, including ones the group has nothing to do with. The badge
    /// counted the group's five while the click went somewhere else entirely.
    ///
    /// Goes through the same `mruOrder` the cycling shortcuts rank by, rather
    /// than introducing a second notion of "most recent" that could disagree
    /// with the switcher about which window you were last in.
    func stackWindowsByRecency(_ members: [WindowInfo]) -> [WindowInfo] {
        var rank: [CGWindowID: Int] = [:]
        for (index, id) in mruOrder.enumerated() { rank[id] = index }

        return members
            .enumerated()
            .sorted { lhs, rhs in
                switch (rank[lhs.element.id], rank[rhs.element.id]) {
                case let (l?, r?): return l < r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }

    /// How many windows of this app are on show in the group, for the menu item
    /// that offers to stack them. Nil when there is nothing worth stacking.
    func stackableWindowCount(for bundleID: String, in groupID: UUID? = nil) -> Int? {
        guard !isStacked(bundleID, in: groupID) else { return nil }
        guard let index = stackGroupIndex(groupID) else { return nil }
        let count = windows(in: groups[index]).filter { $0.bundleID == bundleID }.count
        return count >= 2 ? count : nil
    }

    // MARK: - Clusters

    /// Combines two entries into one icon, or grows an existing cluster when
    /// either side is already part of one.
    /// `groupID` is the capsule the drag happened in, and it is never assumed.
    /// A cluster belongs to one group, and building it in some other notion of
    /// "the current group" put it where the capsule never looks, so nothing
    /// appeared to happen at all.
    func combine(_ windowID: CGWindowID, into targetID: CGWindowID, in groupID: UUID? = nil) {
        guard windowID != targetID,
              let index = groups.firstIndex(where: { $0.id == (groupID ?? activeGroupID) })
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

    func dissolveCluster(_ clusterID: UUID, in groupID: UUID? = nil) {
        // Same reasoning as `combine`: dissolve the cluster in the group that
        // owns it, which in pill view is not the one on screen.
        guard let index = groupID.flatMap({ id in groups.firstIndex { $0.id == id } })
                ?? groupIndexOwning(cluster: clusterID) else { return }
        groups[index].clusters.removeAll { $0.id == clusterID }
        saveNow()
    }

    /// The group that owns a cluster. In pill view the active group is All while
    /// the cluster lives in one of the bucketed groups, so every cluster
    /// operation has to look it up rather than assume.
    private func groupIndexOwning(cluster clusterID: UUID) -> Int? {
        groups.firstIndex { $0.clusters.contains { $0.id == clusterID } }
    }

    private func groupIndexOwningWindowInCluster(_ windowID: CGWindowID) -> Int? {
        groups.firstIndex { $0.clusters.contains { $0.contains(windowID) } }
    }

    func renameCluster(_ clusterID: UUID, to name: String) {
        guard let index = groupIndexOwning(cluster: clusterID),
              let clusterIndex = groups[index].clusters.firstIndex(where: { $0.id == clusterID })
        else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        groups[index].clusters[clusterIndex].customName = trimmed.isEmpty ? nil : trimmed
        saveNow()
    }

    func removeFromCluster(_ windowID: CGWindowID) {
        guard let index = groupIndexOwningWindowInCluster(windowID) else { return }
        detach(windowID, in: index)
        saveNow()
    }

    private func detach(_ windowID: CGWindowID, in groupIndex: Int) {
        for clusterIndex in groups[groupIndex].clusters.indices {
            groups[groupIndex].clusters[clusterIndex].memberIDs.removeAll { $0 == windowID }
        }
        groups[groupIndex].clusters.removeAll { !$0.isViable && $0.savedMembers.isEmpty }
    }

    /// Drops *unreclaimable* windows out of clusters, and dissolves any left with
    /// fewer than two members. Also evicts stale window descriptions.
    ///
    /// A closed window is not unreclaimable: see the note below on why a dead
    /// member id has to be kept.
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

        // A dead cluster member id is a *slot*, exactly as it is for group
        // membership, and for the same reason: it holds the place while the
        // application runs, and it is what the launcher stands in. Evicting it
        // the instant the
        // window stopped being visible is what made a cluster impossible to keep
        // — close two of five clustered Finder windows and the cluster fell below
        // two members and deleted itself, taking the persisted `(app, title)`
        // snapshot of all five with it. It also fired on an ordinary tab switch,
        // which merely orders a window off screen.
        //
        // Bounded by the same rule `pruneDeadMembers` uses: the slot lives only
        // while its application does. An id with no description left is
        // unreclaimable and goes.
        let clustered = Set(groups.flatMap { $0.clusters.flatMap(\.memberIDs) })
        let reclaimable = clustered.filter { id in
            !liveIDs.contains(id)
                && (knownRefs[id].map { runningApps.all.contains($0.bundleID) } ?? false)
        }

        var changed = false
        for index in groups.indices {
            var group = groups[index]
            if group.pruneClusters(liveIDs: liveIDs.union(reclaimable)) {
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
    /// `focusHint` is whatever was focused *before* this refresh. A new window
    /// takes focus the instant it appears, so by the time it is processed the
    /// focused window is the new one — which belongs to nothing. Asking what you
    /// were working in a moment ago is the only way to know which group you
    /// meant, and it is why creating windows in Actelligent filed them as
    /// unfiled.
    func captureNewWindows(_ created: Set<CGWindowID>,
                           claimedByRestore: Set<CGWindowID> = [],
                           focusHint: CGWindowID? = nil) {
        let now = Date()

        // Queue rather than act immediately. A window reaches the window server
        // before the Accessibility API reports it with a usable subrole and
        // size, so a brand-new window frequently isn't in `windows` on the tick
        // it is first seen. It is only ever "new" for that one tick, so acting
        // there and then loses it for good — which is why opening windows
        // quickly would sometimes silently skip one.
        //
        // The group is recorded per window, so a window opened while working in
        // Work still joins Work even if focus moves on while it settles.
        let target = captureTarget(focusHint: focusHint)

        // Nil only when nothing has ever been focused, which is a launch-time
        // state and never a statement about where a window belongs.
        if autoAddNewWindows, let target, now >= launchGraceEnds {
            for id in created.subtracting(claimedByRestore) {
                pendingCaptures[id] = PendingCapture(groupID: target, seen: now)
            }
        }

        // Nothing queued is the overwhelmingly common case; bail before doing any
        // work, rather than rebuilding an empty dictionary on every refresh.
        guard !pendingCaptures.isEmpty else { return }

        for id in claimedByRestore { pendingCaptures.removeValue(forKey: id) }
        // Anything that never becomes trackable — transient dialogs, panels —
        // is dropped rather than queued forever.
        // Ten seconds, not five. An application under load can take a while to
        // describe a new window through Accessibility, and a queue entry that
        // expires first loses the capture silently.
        pendingCaptures = pendingCaptures.filter { now.timeIntervalSince($0.value.seen) < 10 }

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
            guard let index = groups.firstIndex(where: { $0.id == pending.groupID }) else { continue }
            // One capsule per window: whatever else held it lets go. This runs
            // for Main too, where it is the whole operation — capturing into
            // Main means "nothing claims this", which is exactly what Main's
            // implicit membership is.
            let held = groups.indices.filter { groups[$0].memberIDs.contains(windowID) }
            guard !(held == [index]) else { continue }
            for other in held where other != index { groups[other].memberIDs.remove(windowID) }
            if !groups[index].isMain { groups[index].memberIDs.insert(windowID) }
            placeInArrangement(windowID, inGroupAt: index)
            changed = true
        }

        if changed { saveNow() }
    }


    /// What a capsule's arrangement starts as, the first time anything needs one.
    ///
    /// Taken from what the capsule draws right now, with its **hidden pins put
    /// back at the front**. A pin whose application has a window open is not in
    /// the drawn row, so seeding from that row alone drops it — and when the
    /// window later closes the pin returns unranked and is appended to the far
    /// right, having previously led the capsule. `moveItem` documented that trap
    /// for the first drag; `placeInArrangement` reintroduced it for the first
    /// captured window, which is why both now seed through here.
    private func seededOrder(forGroupAt index: Int) -> [String] {
        let pinKeys = groups[index].pinnedApps.map { "p\($0.bundleID)" }
        // Including collapsed: a folded capsule is drawn only in the all-groups
        // panel, and `sections` omits it — seeding from there gave it an empty row.
        let shown = sections(includingCollapsed: true)
            .first { $0.groupID == groups[index].id }?
            .items.map(\.orderKey) ?? []
        return pinKeys + shown.filter { !pinKeys.contains($0) }
    }

    /// Gives a window a place in its capsule's arrangement at the moment it joins.
    ///
    /// Beside its own application if that application is already on the row here —
    /// its windows, its stack, or its launcher — and otherwise at the **end**, so
    /// an application arriving in a capsule for the first time appears where you
    /// just made it appear rather than part-way along.
    ///
    /// `applyManualOrder` has always done exactly this for an item it cannot rank,
    /// but only for a capsule that *has* an arrangement — it returns early on an
    /// empty `order`, and the row then falls back to the sweep's own sort, which
    /// is by application name. So a new TextEdit window landed wherever "TextEdit"
    /// happened to sort among the apps already there. Invisible on a busy capsule
    /// (its arrangement is rebuilt from `savedOrder` every session) and reliable
    /// on an empty one, which is the wrong way round.
    ///
    /// Minting the key here rather than teaching the layout about arrival is what
    /// keeps this free of a "which windows are new" question — the one kind of
    /// bookkeeping this model exists to avoid. It uses the existing `.window`
    /// `OrderRef`, so nothing about the state file changes.
    private func placeInArrangement(_ windowID: CGWindowID, inGroupAt index: Int) {
        let key = "w\(windowID)"
        guard !groups[index].order.contains(key),
              let bundleID = windows.first(where: { $0.id == windowID })?.bundleID
                ?? knownRefs[windowID]?.bundleID
        else { return }

        // Seeded from what the capsule draws right now, or this key would be the
        // only ranked item in it and would sort to the left of everything already
        // there — the exact trap `moveItem` documents for the first drag.
        if groups[index].order.isEmpty {
            groups[index].order = seededOrder(forGroupAt: index).filter { $0 != key }
        }

        // A cluster holding a window of this application counts as the capsule
        // already having it. Worth doing explicitly: a cluster is ordered by its
        // *first member's* window key, so a mixed-app cluster whose leading window
        // belongs to something else would otherwise not match, and a new window
        // would be sent to the end of the row past its own siblings.
        let live = Set(windows.map(\.id))
        let clusterKeys = Set(groups[index].clusters.compactMap { cluster -> String? in
            guard cluster.memberIDs.contains(where: { knownRefs[$0]?.bundleID == bundleID }),
                  // The first member the row is actually drawing. A cluster's
                  // order key is its first *live* member, so keying on
                  // `memberIDs.first` missed the cluster whenever its leading
                  // window had been closed — and the new window was sent past its
                  // own siblings to the end of the row.
                  let first = cluster.memberIDs.first(where: { live.contains($0) })
            else { return nil }
            return "w\(first)"
        })

        let mine = groups[index].order.lastIndex { orderKey in
            if clusterKeys.contains(orderKey) { return true }
            if orderKey.hasPrefix("w") {
                return CGWindowID(orderKey.dropFirst())
                    .flatMap { knownRefs[$0]?.bundleID } == bundleID
            }
            // A stack of that application, or a launcher for it. Both stand for
            // the application itself, so a window of it belongs beside them —
            // which is also why a pinned app is not sent to the end of the row.
            if orderKey.hasPrefix("s") || orderKey.hasPrefix("p") {
                return String(orderKey.dropFirst()) == bundleID
            }
            return false
        }

        if let mine {
            groups[index].order.insert(key, at: mine + 1)
        } else {
            groups[index].order.append(key)
        }
    }

    /// Auto-capture is paused until this moment. Fixed at launch and never
    /// extended. A brief grace covers the reboot storm, when applications reopen
    /// over tens of seconds and every window is technically new.
    @ObservationIgnored private var launchGraceEnds = Date().addingTimeInterval(20)

    /// Ends the launch grace immediately. Self-test only: every case runs within
    /// seconds of launch, so auto-capture would otherwise never fire and a test
    /// of it would assert nothing.
    func endLaunchGraceForTesting() { launchGraceEnds = .distantPast }
    /// Ages the last focus change, so a fixture can say "the user has been
    /// working here" rather than "focus landed here this instant" — which is the
    /// signature of an application raising its own window, and is refused.
    func settleFocusForTesting() { lastFocusChangeAt = .distantPast }

    /// A window seen by the window server but not yet reported by the
    /// Accessibility API, along with the group it should join once it is.
    private struct PendingCapture {
        let groupID: UUID
        let seen: Date
    }

    @ObservationIgnored private var pendingCaptures: [CGWindowID: PendingCapture] = [:]

    /// Drops group members whose window is gone for good.
    ///
    /// A member's id lingers after its window closes, which is deliberate — it is
    /// what lets the strip keep the slot while the app is still running, and what
    /// lets a reopened window reclaim it. But nothing ever removed them, so every
    /// close-and-reopen left another dead id behind: six generations of one
    /// WhatsApp window in a single group, each persisted as a member.
    ///
    /// Two rules, both conservative:
    /// * the application is no longer running — the window cannot come back, so
    ///   there is nothing left to hold a place for;
    /// * more than one dead id for the same application in one group — the strip
    ///   only ever draws one placeholder for an app and a reopened window only
    ///   claims one slot, so the rest are unreachable bookkeeping.
    ///
    /// Never touches a live member, and never runs against `savedMembers`, which
    /// is the restore queue for windows that have not come back *yet*.
    /// Deliberately not run on the engine's cadence. Nothing here changes twice a
    /// second, and it walks every member of every group.
    private static let pruneInterval: TimeInterval = 15
    @ObservationIgnored private var lastPrunedAt = Date.distantPast

    func pruneDeadMembers() {
        guard Date().timeIntervalSince(lastPrunedAt) >= Self.pruneInterval else { return }
        lastPrunedAt = Date()

        // The restore queue is where the real accumulation happens. An entry that
        // never finds its window stays queued and is written back on every save,
        // so each relaunch adds another copy: six identical WhatsApp references
        // in one group, for an app with no windows at all.
        //
        // Only exact duplicates go. A reference matches at most one window, so
        // two identical ones can only ever describe the same window twice —
        // unlike two references that merely share an app, which are two
        // different documents and must both survive.
        // Keyed on app and title, *not* on the reference itself: `MemberRef` is
        // Hashable including its window id, so six queued references to the same
        // WhatsApp window — one per relaunch, each carrying that session's id —
        // compare as six different things and survive a naive dedupe.
        func identity(_ ref: MemberRef) -> String { "\(ref.bundleID)\u{1}\(ref.title)" }

        for index in groups.indices {
            var seen: Set<String> = []
            let deduped = groups[index].savedMembers.filter { seen.insert(identity($0)).inserted }
            if deduped.count != groups[index].savedMembers.count {
                groups[index].savedMembers = deduped
                saveNow()
            }

            var seenOrder: Set<String> = []
            let dedupedOrder = groups[index].savedOrder.filter { ref in
                switch ref {
                case .window(let member): seenOrder.insert("w" + identity(member)).inserted
                case .pinned(let bundleID): seenOrder.insert("p" + bundleID).inserted
                case .stacked(let bundleID): seenOrder.insert("s" + bundleID).inserted
                }
            }
            if dedupedOrder.count != groups[index].savedOrder.count {
                groups[index].savedOrder = dedupedOrder
                saveNow()
            }
        }

        let live = Set(windows.map(\.id))
        var changed = false

        // Is this window's application gone? A dead slot survives while its app
        // runs — that is what holds the launcher's position — and goes when it
        // quits. Unknown ids count as gone: nothing can be restored from them.
        func unreachable(_ id: CGWindowID) -> Bool {
            knownRefs[id].map { !runningApps.all.contains($0.bundleID) } ?? true
        }

        for index in groups.indices where !groups[index].isMain {
            for id in groups[index].memberIDs where !live.contains(id) {
                // Only when the application itself is gone. An earlier version
                // also dropped a second dead id for the same app, which quietly
                // cost real membership: close three editor windows in a group and
                // reopening them restored one.
                guard unreachable(id) else { continue }
                groups[index].memberIDs.remove(id)
                groups[index].order.removeAll { $0 == "w\(id)" }
                changed = true
            }
        }

        // Main's arrangement needs the same sweep, and used not to.
        //
        // Main has no `memberIDs`, so the loop above — which walks membership —
        // never reaches it, and every key in Main's order was previously *reused*
        // rather than added: the deleted rebinding pass had a Main branch that
        // rewrote `w<old>` to `w<new>` in place. With that gone and
        // `placeInArrangement` minting a key for every window captured into Main,
        // nothing removed them: one order key, one `knownRef` and one persisted
        // `OrderRef` per window ever opened in Main, kept alive for the session
        // (`pruneKnownRefs` deliberately retains a ref the order still names, so
        // the two held each other up).
        if let mainIndex = groups.firstIndex(where: { $0.isMain }) {
            let stale = groups[mainIndex].order.filter { key in
                guard key.hasPrefix("w"), let id = CGWindowID(key.dropFirst()) else { return false }
                return !live.contains(id) && unreachable(id)
            }
            if !stale.isEmpty {
                groups[mainIndex].order.removeAll { stale.contains($0) }
                changed = true
            }
        }

        if changed { saveNow() }
    }

    /// Which capsule a newly opened window joins: the one being worked in.
    ///
    /// `focusHint` is the focus recorded *before* this pass, and it is what makes
    /// the answer right rather than circular — a window takes focus the instant it
    /// opens, so by the time anyone asks, the focused window is the new one.
    ///
    /// There is no searching here and there must not be. This used to walk back
    /// through the most-recently-used list looking for a focus old enough to count
    /// as deliberate, which meant a new window could be filed by twenty-minute-old
    /// history, and it existed only to arbitrate against slots that tried to claim
    /// windows back. Nothing claims windows back now, so where you are standing is
    /// the whole answer.
    func captureTarget(focusHint: CGWindowID?) -> UUID? {
        // The override first: clicking a launcher in Work is a statement about
        // where the next window goes, and the window you were focused on when you
        // clicked is not.
        guard lastActiveGroupOverride == nil else { return activeGroup.id }

        // Activating an application raises the window it already had open, so for
        // a few tens of milliseconds "the focused window" is that one rather than
        // the one you were working in — and a document opened from Finder was
        // filed into whichever capsule held the application's *other* window.
        //
        // Measured on a 137 MB file and an 18 KB one: the raise and the new
        // window land 32ms and 48ms apart respectively. The gap does not grow
        // with the file, because the window is created before its contents are
        // read — the slow part happens afterwards, into a window that already
        // exists. So the threshold does not need to allow for a slow document.
        //
        // The refresh tick (0.5s) was tried first, on the argument that reusing an
        // existing number beats inventing one. It is too wide: a deliberate click
        // followed by ⌘N is a human action of 200ms or more, so half a second
        // reaches well into the range of things the user really meant. 150ms sits
        // above the measured raise with 3x margin and below deliberate action.
        //
        // A focus change younger than that is treated as fallout from the launch,
        // and the focus before it stands. Pressing ⌘N in a window you have been
        // working in is untouched: focus did not *change*, so nothing is
        // discarded. The one thing this gets wrong is clicking into a window and
        // opening another within half a second, which is the rarer mistake and
        // costs the same as having no rule at all.
        if Date().timeIntervalSince(lastFocusChangeAt) < Self.activationRaise,
           let earlier = mruOrder.dropFirst().first(where: { id in
               windows.contains { $0.id == id }
           }) {
            return group(of: earlier).id
        }

        if let focusHint, windows.contains(where: { $0.id == focusHint }) {
            return group(of: focusHint).id
        }
        return activeGroup.id
    }

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

        groups = state.groups.map { saved in
            DeckGroup(
                // Stable ids across launches, so a group named anywhere else —
                // a pending capture, a cluster's owner — still resolves.
                id: UUID(uuidString: saved.id) ?? UUID(),
                name: saved.name,
                colorIndex: saved.colorIndex,
                customColorHex: saved.customColorHex,
                isCollapsed: saved.isCollapsed,
                savedMembers: saved.members,
                savedOrder: saved.order,
                clusters: saved.clusters.map(Self.cluster(from:)),
                pinnedApps: Self.pinnedApps(from: saved.pinnedAppBundleIDs),
                stackedAppBundleIDs: Set(saved.stackedAppBundleIDs),
                isMain: saved.isMain
            )
        }
        // The file always names a Main — `PersistedState.migrate` guarantees it
        // — but a file is a thing on disk and this is the one invariant the
        // whole model rests on. Without a Main there is nowhere for an unclaimed
        // window to be drawn, so it is asserted here rather than assumed.
        if !groups.contains(where: \.isMain) {
            groups.insert(DeckGroup(name: "Main", isMain: true), at: 0)
            Trace.warn(.state, "state file named no Main group — one was created")
        }

        // Windows come back over tens of seconds after a reboot, so restore has
        // to keep trying rather than run once at launch.
        restoreDeadline = Date().addingTimeInterval(Self.restoreWindow)
        currentSpaceOnly = state.currentSpaceOnly
        showTitles = state.showTitles
        previewMode = state.previewMode
        hoverTimings = state.hoverTimings
        autoAddNewWindows = state.autoAddNewWindows
        clampZoomedWindows = state.clampZoomedWindows
        hideInFullscreen = state.hideInFullscreen
        deckScale = CGFloat(state.deckScale)
        switcherHoldDelay = state.switcherHoldDelay
        cycleOrder = state.cycleOrder
        appCycleStaysInGroup = state.appCycleStaysInGroup
        showRunningApps = state.showRunningApps
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
    static let shortcutSeedVersion = 2

    private static func shortcutsIntroduced(inSeedVersion version: Int) -> [ShortcutAction] {
        switch version {
        // Version 1 offered the group-cycling shortcuts, which no longer exist —
        // there are no groups to cycle. Its batch is deliberately empty rather
        // than deleted: the version numbers are a ratchet, and reusing one would
        // re-offer a binding to a file that has already declined it.
        case 1: []
        // ⌥Tab. A file written before it existed has no key for it, and defaults
        // are only applied to a file with *no* shortcuts at all — which is never
        // true after first launch — so without this the action would stay
        // unbound forever on every existing install.
        case 2: [.cycleEntries]
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
    /// Built from the copy this process was launched from, so two installations
    /// of one application carry their own display names — "Slack" and "Slack 2"
    /// — rather than both resolving through the bundle id to whichever copy
    /// LaunchServices happens to prefer.
    private static func pinnedApp(for instance: AppInstance) -> PinnedApp? {
        if let url = instance.url, let app = PinnedApp(url: url) { return app }
        return PinnedApp(bundleID: instance.bundleID, name: instance.name)
    }

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
        StateStore.save(PersistedState(
            groups: groups.map {
                PersistedGroup(
                    id: $0.id.uuidString,
                    name: $0.name,
                    colorIndex: $0.colorIndex,
                    customColorHex: $0.customColorHex,
                    isCollapsed: $0.isCollapsed,
                    isMain: $0.isMain,
                    // Main's is empty by construction: its membership is the
                    // complement of everyone else's, so writing a list would be
                    // a second answer to a question that already has one.
                    members: $0.isMain ? [] : snapshot(of: $0),
                    order: orderSnapshot(of: $0),
                    clusters: $0.clusters.map(persisted),
                    pinnedAppBundleIDs: $0.pinnedApps.map(\.bundleID),
                    // Sorted so the file is stable between saves. An unordered
                    // Set writes in a different order each time, which would make
                    // every save look like a change to anything diffing it.
                    stackedAppBundleIDs: $0.stackedAppBundleIDs.sorted()
                )
            },
            currentSpaceOnly: currentSpaceOnly,
            showTitles: showTitles,
            previewMode: previewMode,
            hoverTimings: hoverTimings,
            autoAddNewWindows: autoAddNewWindows,
            clampZoomedWindows: clampZoomedWindows,
            hideInFullscreen: hideInFullscreen,
            deckScale: Double(deckScale),
            switcherHoldDelay: switcherHoldDelay,
            cycleOrder: cycleOrder,
            appCycleStaysInGroup: appCycleStaysInGroup,
            shortcuts: shortcuts.reduce(into: [:]) { $0[$1.key.storageKey] = $1.value },
            shortcutSeedVersion: shortcutSeedVersion,
            showRunningApps: showRunningApps,
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
            if key.hasPrefix("s") { return .stacked(String(key.dropFirst())) }
            guard let id = CGWindowID(key.dropFirst()), let ref = knownRefs[id] else { return nil }
            return .window(ref)
        }
        return live + group.savedOrder
    }

    /// Remembers how to describe each window across restarts. Updated on every
    /// refresh so a member's description is available even once the window is no
    /// longer visible.
    func noteWindowRefs(_ windows: [WindowInfo]) {
        let now = Date()
        for window in windows {
            lastSeenAt[window.id] = now
            guard let bundleID = window.bundleID else { continue }
            knownRefs[window.id] = MemberRef(bundleID: bundleID, title: window.title,
                                             windowID: window.id)
        }
    }
}
