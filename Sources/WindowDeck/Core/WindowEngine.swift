import AppKit
import ApplicationServices

/// Enumerates open windows, keeps the list current, and raises individual ones.
///
/// Two OS sources are combined. The Accessibility API is the primary one: it
/// gives reliable titles and is the only way to raise a *specific* window.
/// `CGWindowListCopyWindowInfo` supplies the set of windows on the current
/// Space, which is both a cheap change-detector and free Space filtering.
///
/// `kCGWindowName` is deliberately unused — reading titles that way would
/// require Screen Recording permission, which WindowDeck avoids entirely.
@MainActor
final class WindowEngine {

    /// What a refresh reports.
    struct Snapshot {
        let windows: [WindowInfo]
        /// Windows created since the last refresh.
        let created: Set<CGWindowID>
        /// Frontmost ordinary window, or nil if nothing qualifies.
        let focusedWindowID: CGWindowID?
        /// True while a genuinely fullscreen window is frontmost — its own
        /// Space, menu bar hidden. Distinct from a merely zoomed window.
        let isFullscreen: Bool
        /// Process ids owning an ordinary window on *any* Space. Lets the store
        /// tell "this app has nothing open" apart from "nothing open on this
        /// Desktop", without a second window-server query per redraw.
        let windowOwnerPIDs: Set<pid_t>
    }

    var onChange: ((Snapshot) -> Void)?

    /// Shorten windows that have just been zoomed so they stop above the strip.
    var clampZoomedWindows = true
    /// Height of the band at the bottom of the screen the strip occupies.
    var reservedBandHeight: CGFloat = 0

    /// When true, only windows on the currently visible Space are listed.
    var currentSpaceOnly: Bool = true {
        didSet { refresh() }
    }

    private var pollTimer: Timer?
    private var lastOnScreenIDs: Set<CGWindowID> = []
    private var lastFrontmostID: CGWindowID?
    private var ticksSinceFullScan = 0
    /// Kept so actions can resolve a window ID back to its AX element without
    /// the caller having to hold onto WindowInfo values.
    private var lastKnownWindows: [WindowInfo] = []
    /// Which applications the last sweep found a real window for.
    ///
    /// Nil until the first sweep lands, and the window server answers in the
    /// meantime — otherwise every running application would look window-less for
    /// the first half second and the strip would open with a row of launchers
    /// that immediately vanished.
    private var pidsWithWindows: Set<pid_t>?
    /// Every window ID seen on the previous tick, across all Spaces, so genuinely
    /// new windows can be told apart from ones merely coming into view.
    private var knownWindowIDs: Set<CGWindowID> = []
    private var hasSeededKnownIDs = false
    private var refreshWork: DispatchWorkItem?
    /// Windows seen reporting `AXStandardWindow` at least once. A window's
    /// subrole can change while it is minimised, and this is what stops that
    /// looking like the window closed. Pruned against the window server each
    /// refresh so it cannot grow for the life of the process.
    private var standardWindowIDs: Set<CGWindowID> = []

    /// The Accessibility pass, which runs off the main thread. See `AXSweeper`
    /// for why that is not optional.
    private let sweeper = AXSweeper()
    /// A sweep is never run concurrently with itself; a request arriving while
    /// one is in flight collapses into a single re-run when it lands.
    private var sweepInFlight = false
    private var sweepPending = false

    /// Windows smaller than this are palettes, HUDs and inspectors, not documents.
    private let minimumWindowSide: CGFloat = 80

    // MARK: - Lifecycle

    func start() {
        // Before anything asks Accessibility a question: one stuck application
        // must not be able to park the main thread. See `AX.boundMessagingTimeouts`.
        AX.boundMessagingTimeouts()

        let center = NSWorkspace.shared.notificationCenter
        for name: NSNotification.Name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification
        ] {
            center.addObserver(self, selector: #selector(workspaceEvent), name: name, object: nil)
        }

        // Two cadences. The 0.5s tick only diffs CGWindowList, which is a single
        // cheap call — no Accessibility IPC — so window open/close is caught fast.
        // Every 6th tick (~3s) a full AX scan also picks up title changes.
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        refresh()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func workspaceEvent(_ note: Notification) {
        if note.name == NSWorkspace.didTerminateApplicationNotification,
           let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            IconCache.forget(pid: app.processIdentifier)
        }
        refresh()
    }

    /// Ticks between full Accessibility scans, which catch title changes.
    /// How often the cheap probe runs. Also the width of "just now" for anyone
    /// judging whether two events happened in the same pass.
    static let tickInterval: TimeInterval = 0.5
    private let fullScanInterval = 6

    private func tick() {
        ticksSinceFullScan += 1

        // Watch the frontmost window as well as the window *set*. Clicking
        // another window — especially another window of the same app, which
        // fires no workspace notification — changes neither the set nor the
        // count, so without this the focus highlight and the most-recently-used
        // ordering both lagged until the periodic sweep, up to three seconds.
        let (ids, frontmost) = onScreenState()
        let setChanged = ids != lastOnScreenIDs
        let focusChanged = frontmost != lastFrontmostID
        let dueForSweep = ticksSinceFullScan >= fullScanInterval

        if setChanged || focusChanged || dueForSweep {
            lastOnScreenIDs = ids
            lastFrontmostID = frontmost
            // Only a focus change needs no re-description — titles and
            // membership can't have moved. The periodic sweep still catches
            // titles that changed without any window opening or closing.
            refresh(full: setChanged || dueForSweep)
        }
    }

    /// The cheap per-tick probe: visible window IDs and which is in front, from
    /// one query and no Accessibility calls.
    private func onScreenState() -> (Set<CGWindowID>, CGWindowID?) {
        let entries = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []

        var ids: Set<CGWindowID> = []
        var frontmost: CGWindowID?

        for entry in entries {
            guard (entry[kCGWindowLayer as String] as? Int) == 0 else { continue }
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID else { continue }
            ids.insert(id)
            if frontmost == nil,
               (entry[kCGWindowOwnerName as String] as? String) != "WindowDeck" {
                frontmost = id
            }
        }
        return (ids, frontmost)
    }

    /// Requests a rebuild shortly, collapsing a burst into one.
    ///
    /// Actions triggered by a keypress must never rebuild synchronously. A
    /// refresh costs Accessibility round-trips for every application plus a full
    /// strip redraw, and running that on the keypress path delays the *next*
    /// event — including the modifier release, which is what made a following
    /// press advance the open session instead of starting a new switch. That is
    /// the "it ignored my press" symptom.
    func scheduleRefresh(full: Bool = false, after delay: TimeInterval = 0.12) {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refreshWork = nil
            self?.refresh(full: full)
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// - Parameter full: whether to re-describe every window through the
    ///   Accessibility API.
    ///
    /// Most refreshes don't need to. Raising a window changes which one is in
    /// front — not what windows exist or what they're called — so the expensive
    /// part is skipped and the previous descriptions are reused. That is what
    /// keeps a switch off the Accessibility path entirely. A newly created
    /// window forces a full pass regardless, since it has no description yet.
    func refresh(full: Bool = true) {
        refreshWork?.cancel()
        refreshWork = nil
        if full { ticksSinceFullScan = 0 }

        // One window-server query feeds everything below.
        let server = queryWindowServer()
        let hasNewWindows = hasSeededKnownIDs && !server.allIDs.subtracting(knownWindowIDs).isEmpty

        // The Accessibility pass is asynchronous: it is asked for here and
        // publishes a second time when it lands. This refresh goes out *now*,
        // with the descriptions already in hand — which is exactly what a
        // non-full refresh has always done for a raise, so nothing downstream
        // needed a new state to absorb it. Everything below this line is window
        // server data, which costs no IPC into another process and cannot block.
        if full || hasNewWindows {
            requestSweep(onScreen: server.onScreenIDs, live: server.allIDs,
                         ignoreBackoff: hasNewWindows)
            ticksSinceFullScan = 0
        }
        let windows = lastKnownWindows

        // "Newly created" is judged against every window on every Space, not
        // against the filtered list. With current-Space filtering on, switching
        // Space makes a whole set of windows appear at once — comparing against
        // the visible list would call all of them new.
        let created: Set<CGWindowID>
        if hasSeededKnownIDs {
            created = server.allIDs.subtracting(knownWindowIDs)
        } else {
            // First pass: everything already open is not "new".
            created = []
            hasSeededKnownIDs = true
        }
        knownWindowIDs = server.allIDs
        // Forget windows that genuinely went away.
        if standardWindowIDs.count > server.allIDs.count {
            standardWindowIDs.formIntersection(server.allIDs)
        }

        // A window the server has just reported often isn't fully described by
        // the Accessibility API yet. Force a full scan on the very next tick so
        // whoever is waiting on it hears back in ~0.5s rather than waiting for
        // the periodic 3s sweep.
        if !created.isEmpty { ticksSinceFullScan = fullScanInterval }

        let focused = server.frontmostID
        let fullscreen = isFrontmostFullscreen(windows: windows, focused: focused)

        // Never resize while fullscreen: that window is meant to own the screen,
        // and the strip gets out of its way instead.
        if clampZoomedWindows && !fullscreen {
            clampZoomed(windows, bounds: server.bounds)
        }

        onChange?(Snapshot(
            windows: windows,
            created: created,
            focusedWindowID: focused,
            isFullscreen: fullscreen,
            // Accessibility, not the window server: an application that closed
            // its last window with the red button can keep layer-0 windows in
            // `CGWindowList`, which made it look like it still had one and
            // suppressed the launcher the Dock draws for it.
            windowOwnerPIDs: pidsWithWindows ?? server.ownerPIDs
        ))
    }

    /// Everything the window server can tell us, from a single query.
    ///
    /// One call rather than four: the on-screen set, the full cross-Space ID set,
    /// the frontmost window and every window's frame all come out of the same
    /// list. `kCGWindowIsOnscreen` distinguishes visible windows, so the
    /// `.optionOnScreenOnly` variant isn't needed separately.
    private struct WindowServerSnapshot {
        var allIDs: Set<CGWindowID> = []
        var onScreenIDs: Set<CGWindowID> = []
        var bounds: [CGWindowID: CGRect] = [:]
        var frontmostID: CGWindowID?
        var ownerPIDs: Set<pid_t> = []
    }

    private func queryWindowServer() -> WindowServerSnapshot {
        var snapshot = WindowServerSnapshot()

        // Two queries, not one. CGWindowList only guarantees front-to-back
        // ordering for the **on-screen** list; including off-screen windows
        // interleaves other Spaces and "first entry" stops meaning "frontmost".
        // Collapsing both into a single unfiltered query made the focus latch
        // onto a window on another Space and never move.
        let visible = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []

        for entry in visible {
            guard (entry[kCGWindowLayer as String] as? Int) == 0 else { continue }
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID else { continue }

            snapshot.onScreenIDs.insert(id)

            if let dict = entry[kCGWindowBounds as String] as? [String: CGFloat],
               let x = dict["X"], let y = dict["Y"],
               let w = dict["Width"], let h = dict["Height"] {
                snapshot.bounds[id] = CGRect(x: x, y: y, width: w, height: h)
            }

            if snapshot.frontmostID == nil,
               (entry[kCGWindowOwnerName as String] as? String) != "WindowDeck" {
                snapshot.frontmostID = id
            }
        }

        // Ordering is irrelevant here — this only answers "which window IDs
        // exist anywhere", for spotting genuinely new windows.
        let all = CGWindowListCopyWindowInfo(
            [.excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []

        for entry in all {
            guard (entry[kCGWindowLayer as String] as? Int) == 0 else { continue }
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID else { continue }
            snapshot.allIDs.insert(id)
            if let pid = entry[kCGWindowOwnerPID as String] as? pid_t {
                snapshot.ownerPIDs.insert(pid)
            }
        }

        return snapshot
    }

    /// `kAXFullScreen` is the discriminator between a fullscreen window and a
    /// merely zoomed one. They look nearly identical by geometry — both fill the
    /// screen — but want opposite behaviour from the strip, so geometry is not
    /// used to decide this.
    private func isFrontmostFullscreen(windows: [WindowInfo], focused: CGWindowID?) -> Bool {
        guard let focused, let window = windows.first(where: { $0.id == focused }) else {
            // A fullscreen window often isn't in our list at all — it lives on
            // its own Space. Fall back to asking the frontmost app directly.
            return frontmostAppHasFullscreenWindow()
        }
        return AX.bool(window.element, AX.fullScreenAttribute)
    }

    private func frontmostAppHasFullscreenWindow() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return false }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused: AXUIElement = AX.value(axApp, kAXFocusedWindowAttribute) else { return false }
        return AX.bool(focused, AX.fullScreenAttribute)
    }

    /// Shortens windows that have just been zoomed so their bottom clears the
    /// strip.
    ///
    /// macOS gives no public way to reserve screen space — only the real Dock
    /// gets that — so this is reactive. Two properties keep it from becoming a
    /// tug of war:
    ///
    /// - **Self-limiting.** After the resize the window is no longer full
    ///   height, so it stops matching the zoom test and is never touched again.
    /// - **Hand-placed windows never match**, because the test demands full
    ///   width *and* alignment to the top of the visible frame. A window you
    ///   dragged low stays exactly where you put it.
    /// - Parameter bounds: window frames already read from the window server.
    ///
    /// The geometry test runs entirely on those bounds, which cost nothing —
    /// they came from a `CGWindowList` query already being made. Accessibility
    /// is only consulted for the handful of windows that actually look zoomed.
    ///
    /// Doing it the other way round meant three cross-process AX calls per
    /// window per screen on every refresh: ~114 round-trips a second for a
    /// typical session, to discover that nothing needed changing.
    private func clampZoomed(_ windows: [WindowInfo], bounds: [CGWindowID: CGRect]) {
        guard reservedBandHeight > 0 else { return }
        guard let primary = NSScreen.screens.first else { return }

        for window in windows where !window.isMinimized {
            guard let frame = bounds[window.id] else { continue }

            // Which display is it on? `frame` is top-left-origin, like AX.
            guard let screen = NSScreen.screens.first(where: { candidate in
                let visible = candidate.visibleFrame
                let topInAX = primary.frame.maxY - visible.maxY
                return abs(frame.minX - visible.minX) <= 12 && abs(frame.minY - topInAX) <= 6
            }) else { continue }

            // When the real Dock is showing, `visibleFrame` already stops above
            // it — and the strip sits at the screen's actual bottom edge, hidden
            // beneath that Dock, so no further reservation is owed for it. Only
            // the sliver (if any) by which the strip's own band would poke above
            // the Dock's height still needs to be reserved. Subtracting the full
            // band unconditionally double-reserved: the Dock's clearance plus
            // the strip's own, so a zoomed window stopped well above the Dock
            // with visible empty space between them.
            let visible = screen.visibleFrame
            let dockReservation = visible.minY - screen.frame.minY
            let allowedHeight = visible.height - max(0, reservedBandHeight - dockReservation)

            guard frame.width >= visible.width - 12 else { continue }
            guard frame.height > allowedHeight + 2 else { continue }

            // Only now is it worth asking Accessibility anything — and the
            // fullscreen check must stay AX-based, since a fullscreen window and
            // a zoomed one are the same shape.
            guard !AX.bool(window.element, AX.fullScreenAttribute) else { continue }
            AX.setSize(window.element, CGSize(width: frame.width, height: allowedHeight))
        }
    }

    // MARK: - Enumeration

    /// Window IDs currently on screen. `.optionOnScreenOnly` reports only the
    /// active Space, which is exactly the Space filter we want.
    private func onScreenWindowIDs() -> Set<CGWindowID> {
        let entries = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []

        return Set(entries.compactMap { entry in
            // Layer 0 is normal application content; menus, the Dock and overlays
            // live above it.
            guard (entry[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return entry[kCGWindowNumber as String] as? CGWindowID
        })
    }

    /// Asks for a fresh description of every window.
    ///
    /// - Parameter onScreen: the visible-window set from the caller's existing
    ///   window-server query, so this doesn't repeat it.
    /// - Parameter live: every window id the server knows, on any Space. The
    ///   sweeper filters retained descriptions against it.
    private func requestSweep(onScreen: Set<CGWindowID>, live: Set<CGWindowID>,
                              ignoreBackoff: Bool = false) {
        guard Permissions.isTrusted else { return }
        // Overlapping sweeps would race on the retention cache and double the
        // Accessibility traffic to learn the same thing twice.
        guard !sweepInFlight else { sweepPending = true; return }
        sweepInFlight = true

        sweeper.sweep(AXSweeper.Input(
            apps: currentAppRefs(),
            onScreen: onScreen,
            live: live,
            currentSpaceOnly: currentSpaceOnly,
            minimumWindowSide: minimumWindowSide,
            standardWindowIDs: standardWindowIDs,
            ignoreBackoff: ignoreBackoff
        )) { [weak self] output in
            MainActor.assumeIsolated { self?.sweepFinished(output) }
        }
    }

    /// The running applications, snapshotted on the main thread.
    ///
    /// The sweep handles no AppKit object of its own — it gets plain values.
    /// `NSRunningApplication` is documented thread-safe, but reading the four
    /// properties here costs one array walk and removes the need to keep proving
    /// that for every property `describe` might grow.
    private func currentAppRefs() -> [AXSweeper.AppRef] {
        let selfBundleID = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, !app.isTerminated else { return nil }
            guard app.bundleIdentifier != selfBundleID else { return nil }
            return AXSweeper.AppRef(
                pid: app.processIdentifier,
                bundleID: app.bundleIdentifier,
                name: app.localizedName ?? "Unknown",
                isHidden: app.isHidden
            )
        }
    }

    private func sweepFinished(_ output: AXSweeper.Output) {
        sweepInFlight = false
        standardWindowIDs.formUnion(output.newlyStandard)
        lastKnownWindows = output.windows
        pidsWithWindows = output.pidsWithWindows

        // Publish unconditionally rather than only when the list changed. A
        // sweep that moved nothing but a frame still has to reach the store:
        // `WindowInfo.==` ignores `frame` on purpose, and `noteWindowRefs` runs
        // on every snapshot precisely because a window that was merely moved
        // must still update its recorded frame — that is what tab matching is
        // keyed on. The redraw guard lives downstream, in `onChange`.
        if sweepPending {
            sweepPending = false
            refresh(full: true)
        } else {
            refresh(full: false)
        }
    }

    // MARK: - Actions

    /// Brings forward exactly one window.
    ///
    /// Order matters. Activating the app first makes the app raise whatever it
    /// considers frontmost — usually the wrong window. Raising the specific
    /// element first, then activating, leaves the app's other windows untouched.
    /// `.activateAllWindows` is deliberately not used.
    /// Reports the window we just asked the system to focus.
    ///
    /// `activate()` is asynchronous, so calling `refresh()` straight afterwards
    /// reads the *old* frontmost window from the window server — focus tracking
    /// then lags by up to a tick. That is fatal for rapid cycling: press again
    /// within that window and the candidate list is built from stale focus, so
    /// "the window before this one" resolves to the one you are already in and
    /// the keypress appears to do nothing.
    var onFocusRequested: ((CGWindowID) -> Void)?

    /// Brings an application forward, overriding cooperative activation.
    ///
    /// Plain `activate()` is a *request*, and macOS refuses it whenever the
    /// asking app is not already frontmost — which WindowDeck never is, because
    /// the strip is a `.nonactivatingPanel` on purpose. Measured directly in the
    /// settings window: `NSApp.isActive` stayed false after every single call.
    /// The result is a window correctly raised within its own app while the app
    /// itself stays behind whatever you were looking at, so clicking an entry
    /// looked like it had done nothing.
    ///
    /// The deprecated option is not a shortcut here; it is the only form that
    /// works from a background agent.
    private func bringForward(pid: pid_t) {
        let app = NSRunningApplication(processIdentifier: pid)

        // Unhiding is a separate verb from activating, and `activate()` will not
        // do it. Hiding an app with ⌘H used to remove its windows from the strip
        // entirely, so this never came up; now that they are listed, clicking one
        // raised the window inside an application that stayed hidden.
        if app?.isHidden == true { app?.unhide() }

        // Accessibility, not AppKit, is what actually brings the app forward.
        //
        // `NSRunningApplication.activate()` is a request under cooperative
        // activation and macOS refuses it for an app that is not already
        // frontmost — which WindowDeck never is, the strip being a
        // `.nonactivatingPanel` by design. The `ignoringOtherApps` option looks
        // like the escape hatch and is not: the compiler reports it deprecated
        // "and will have no effect" on macOS 14, so calls carrying it did nothing
        // beyond the plain request that was already failing.
        //
        // Setting `kAXFrontmost` on the application element goes through the
        // Accessibility API instead, which WindowDeck already holds permission
        // for, and is not subject to that refusal.
        AX.setBool(AXUIElementCreateApplication(pid), kAXFrontmostAttribute, true)

        // Kept as a belt-and-braces follow-up; harmless when the AX route worked.
        app?.activate()
    }

    func focus(_ window: WindowInfo) {
        onFocusRequested?(window.id)
        if AX.bool(window.element, kAXMinimizedAttribute) {
            AX.setBool(window.element, kAXMinimizedAttribute, false)
        }
        AX.perform(window.element, kAXRaiseAction)
        AX.setBool(window.element, kAXMainAttribute, true)
        bringForward(pid: window.pid)
        // Deferred, and light: raising changes which window is in front, not
        // what windows exist, so the Accessibility pass is skipped entirely.
        scheduleRefresh(full: false)
    }

    /// Brings every window of a cluster forward together.
    ///
    /// Iterated in **reverse** on purpose: each window is raised and its app
    /// activated in turn, so the *last* one processed wins the final activation.
    /// Going backwards makes that the first member — the one the user designated
    /// — rather than whichever happened to be last in the list.
    func focusAll(_ windows: [WindowInfo]) {
        guard !windows.isEmpty else { return }
        if let first = windows.first { onFocusRequested?(first.id) }

        for window in windows.reversed() {
            if AX.bool(window.element, kAXMinimizedAttribute) {
                AX.setBool(window.element, kAXMinimizedAttribute, false)
            }
            AX.perform(window.element, kAXRaiseAction)
            AX.setBool(window.element, kAXMainAttribute, true)
            bringForward(pid: window.pid)
        }
        scheduleRefresh()
    }

    func close(_ window: WindowInfo) {
        guard let button: AXUIElement = AX.value(window.element, kAXCloseButtonAttribute) else { return }
        AX.perform(button, kAXPressAction)
        scheduleRefresh(full: true)
    }

    func minimize(_ window: WindowInfo) {
        AX.setBool(window.element, kAXMinimizedAttribute, true)
        scheduleRefresh(full: true)
    }
}
