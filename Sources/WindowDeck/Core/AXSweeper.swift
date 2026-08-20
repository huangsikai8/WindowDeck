import AppKit
import ApplicationServices

/// Describes every open window through the Accessibility API, off the main
/// thread.
///
/// **It has to be off the main thread.** Every AX call is synchronous IPC into
/// another process, and one sweep makes a call per application plus six per
/// window — ~270 of them for a typical session. On an unloaded machine each
/// returns in microseconds and running it inline was invisible, which is why it
/// lived on the main actor for so long. Under memory pressure it is a different
/// function entirely: measured here with 21 applications open, six of them
/// routinely took 150–500ms to answer a *single* `kAXWindowsAttribute`, and a
/// whole sweep took 2.4–3.6 seconds. That ran every three seconds on the thread
/// that draws the strip, handles the hotkeys and fires every timer — which is
/// precisely what a "mini hang" is.
///
/// The tell that it is blocking rather than working: CPU stays flat across the
/// stall. The first symptom of the worst instance was a perf heartbeat arriving
/// 85 seconds after the previous one instead of 60, with CPU up only 2.3s over
/// the gap — a main thread parked in `mach_msg`, the same blocked-leaf signature
/// that once made the engine tick look expensive in a `sample` profile.
///
/// Nothing downstream needed a new state to absorb this. The engine keeps
/// drawing the previous descriptions until a sweep lands, which is exactly what
/// `refresh(full: false)` already did for a raise.
final class AXSweeper {

    /// One application, snapshotted on the main thread.
    ///
    /// The sweep touches no AppKit object of its own. `NSRunningApplication` is
    /// documented thread-safe, but reading four properties on the main thread and
    /// passing values across is cheaper to reason about than proving that for
    /// every property `describe` might grow, and it costs one array walk.
    struct AppRef {
        let pid: pid_t
        let bundleID: String?
        let name: String
        let isHidden: Bool
    }

    struct Input {
        let apps: [AppRef]
        let onScreen: Set<CGWindowID>
        /// Every window id the server currently knows, on any Space. Retained
        /// descriptions are filtered against it.
        let live: Set<CGWindowID>
        let currentSpaceOnly: Bool
        let minimumWindowSide: CGFloat
        /// Windows already seen reporting `AXStandardWindow`, copied in because
        /// the engine owns the authoritative set and prunes it.
        let standardWindowIDs: Set<CGWindowID>
        /// Describe every application even if it is being backed off.
        ///
        /// Set when the window server has just reported a new window. A window
        /// is claimed by a group within `AppStore.arrivalGrace` — 5 seconds —
        /// of being created, and it can only be claimed once it has been
        /// *described*. Left to the ordinary 10-second backoff, opening a
        /// window in an application that happened to be slow would miss that
        /// window entirely and land the window in the wrong capsule, which is
        /// the exact failure the capture rules exist to prevent. Freshness wins
        /// over the budget at the one moment it matters, and it costs only
        /// background time now that the sweep is off the main thread.
        let ignoreBackoff: Bool
    }

    struct Output {
        let windows: [WindowInfo]
        /// Ids this sweep newly saw as standard, merged back by the engine.
        let newlyStandard: Set<CGWindowID>
        /// Applications that own at least one real window, wherever it is drawn.
        ///
        /// This is what "does the Dock draw a dot for it" has to mean, and the
        /// window server cannot answer it. Measured: ChatGPT closed with the red
        /// button keeps five layer-0 windows alive in `CGWindowList` — one of
        /// them 1280x668 — while Accessibility correctly reports it has none. So
        /// the server said "has windows" and suppressed its launcher, the AX pass
        /// said "no windows" and drew no tile, and the application vanished from
        /// the strip entirely while the real Dock still showed it.
        ///
        /// Recorded before the current-Space cull, which is the reason the window
        /// server was consulted in the first place: an app whose only windows sit
        /// one Desktop away still owns them and must not be offered as a
        /// launcher.
        let pidsWithWindows: Set<pid_t>
    }

    /// Serial: two sweeps at once would race on the retention cache and double
    /// the Accessibility traffic for no benefit.
    private let queue = DispatchQueue(label: "com.windowdeck.ax-sweep", qos: .userInitiated)

    // MARK: - Queue-confined state
    //
    // Touched only inside `queue`, which is what makes it safe without a lock.

    /// The windows each application had when it last answered.
    ///
    /// An application that stops answering keeps the windows it had rather than
    /// appearing to have quit. Dropping them is the same visible failure as the
    /// hidden-app bug — the strip silently loses a dozen windows — and a stuck
    /// application is precisely when the strip has to stay usable.
    private var lastWindowsByPID: [pid_t: [WindowInfo]] = [:]
    /// Applications that blew the budget, and the uptime at which each may be
    /// tried again.
    private var backoff: [pid_t: TimeInterval] = [:]

    /// How long one application may take before it is treated as stuck. Well
    /// above a healthy one, which answers in microseconds.
    private let describeBudget: TimeInterval = 0.15
    /// How long a stuck application is left alone before being tried again.
    ///
    /// This only skips *re-describing* it. Its windows are retained meanwhile,
    /// and windows opening or closing are still caught on the 0.5s window-server
    /// probe, which makes no Accessibility calls at all — so what actually goes
    /// stale for this long is titles, and only for an application that is not
    /// answering anyway.
    private let backoffInterval: TimeInterval = 10
    /// A sweep slower than this is worth a line in the log. The stall this
    /// whole class exists for was previously only inferrable from heartbeat drift.
    private let sweepBudget: TimeInterval = 0.25

    /// Runs a sweep and delivers the result on the main queue.
    ///
    /// The caller is responsible for not overlapping requests; `WindowEngine`
    /// collapses any that arrive while one is in flight.
    func sweep(_ input: Input, completion: @escaping (Output) -> Void) {
        queue.async { [self] in
            let output = run(input)
            DispatchQueue.main.async { completion(output) }
        }
    }

    private func run(_ input: Input) -> Output {
        let clock = ProcessInfo.processInfo
        let sweepStart = clock.systemUptime
        var results: [WindowInfo] = []
        var newlyStandard: Set<CGWindowID> = []
        var seenPIDs: Set<pid_t> = []
        var sawWindow: Set<pid_t> = []

        for app in input.apps {
            seenPIDs.insert(app.pid)

            // A known-stuck application is skipped outright rather than waited on
            // again. Asking costs the full timeout every sweep and the answer has
            // not been arriving.
            if !input.ignoreBackoff, let until = backoff[app.pid], clock.systemUptime < until {
                let held = retained(pid: app.pid, live: input.live)
                // Held descriptions are of real windows, so a stuck application
                // must not be mistaken for one that has none — that would draw a
                // launcher beside the windows it is still holding.
                if !held.isEmpty { sawWindow.insert(app.pid) }
                results.append(contentsOf: held)
                continue
            }

            let started = clock.systemUptime
            let axApp = AXUIElementCreateApplication(app.pid)
            // Explicit as well as process-wide: this is the element every blocking
            // call below goes through, and saying so costs no IPC.
            AXUIElementSetMessagingTimeout(axApp, AX.messagingTimeout)
            let elements: [AXUIElement]? = AX.value(axApp, kAXWindowsAttribute)

            if let elements {
                var described: [WindowInfo] = []
                described.reserveCapacity(elements.count)
                for element in elements {
                    guard let info = describe(
                        element: element,
                        app: app,
                        input: input,
                        newlyStandard: &newlyStandard,
                        sawWindow: &sawWindow
                    ) else { continue }
                    described.append(info)
                }
                lastWindowsByPID[app.pid] = described
                results.append(contentsOf: described)
            } else {
                // No answer. Almost always the timeout, since a regular
                // application always has this attribute — so hold what it had
                // rather than report that all its windows closed.
                let held = retained(pid: app.pid, live: input.live)
                if !held.isEmpty { sawWindow.insert(app.pid) }
                results.append(contentsOf: held)
            }

            let elapsed = clock.systemUptime - started
            if elapsed > describeBudget {
                backoff[app.pid] = clock.systemUptime + backoffInterval
                let held = lastWindowsByPID[app.pid]?.count ?? 0
                Trace.warn(.engine, "\(app.name) (pid \(app.pid)) took \(Int(elapsed * 1000))ms on "
                    + "Accessibility — holding its \(held) windows, retrying in \(Int(backoffInterval))s")
            } else {
                backoff.removeValue(forKey: app.pid)
            }
        }

        // Applications that are gone keep nothing.
        let departed = lastWindowsByPID.keys.filter { !seenPIDs.contains($0) }
        for pid in departed {
            lastWindowsByPID.removeValue(forKey: pid)
            backoff.removeValue(forKey: pid)
        }

        let sweepElapsed = clock.systemUptime - sweepStart
        if sweepElapsed > sweepBudget {
            Trace.warn(.engine, "window sweep took \(Int(sweepElapsed * 1000))ms "
                + "for \(results.count) windows across \(seenPIDs.count) apps — off the main thread")
        }

        // Group by app so the strip reads like a Dock, stable across refreshes.
        let sorted = results.sorted {
            $0.appName == $1.appName
                ? $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending
                : $0.appName.localizedStandardCompare($1.appName) == .orderedAscending
        }
        return Output(windows: sorted, newlyStandard: newlyStandard, pidsWithWindows: sawWindow)
    }

    /// What an application had when it last answered, minus anything the window
    /// server says is gone.
    ///
    /// That filter is what makes retention safe rather than a way to strand dead
    /// windows on the strip: the id set came from the window-server query the
    /// refresh already made, so it costs no Accessibility call, and a window
    /// closed while its application was stuck still leaves the strip on the very
    /// next tick.
    private func retained(pid: pid_t, live: Set<CGWindowID>) -> [WindowInfo] {
        guard let held = lastWindowsByPID[pid] else { return [] }
        let kept = held.filter { live.contains($0.id) }
        if kept.count != held.count { lastWindowsByPID[pid] = kept }
        return kept
    }

    private func describe(
        element: AXUIElement,
        app: AppRef,
        input: Input,
        newlyStandard: inout Set<CGWindowID>,
        sawWindow: inout Set<pid_t>
    ) -> WindowInfo? {
        guard let id = AX.windowID(of: element) else { return nil }

        let subrole: String? = AX.value(element, kAXSubroleAttribute)
        let isMinimized = AX.bool(element, kAXMinimizedAttribute)
        let title: String = AX.value(element, kAXTitleAttribute) ?? ""
        let isStandard = subrole == kAXStandardWindowSubrole as String
        let isHiddenApp = app.isHidden

        // Standard windows only — that filter is what keeps sheets, popovers,
        // palettes and inspectors out of the strip. But it cannot be the whole
        // story, because **a window's subrole can change while it is minimised**:
        // Activity Monitor's main window reports `AXDialog` once minimised, so a
        // strict test dropped it from every group and minimising was
        // indistinguishable from closing.
        //
        // Two escapes, both narrow. A window already seen as standard stays
        // accepted for as long as it exists, since minimising cannot turn a real
        // window into a dialog. And a *minimised* dialog carrying a title is
        // treated as real — genuine dialogs are modal and cannot be minimised at
        // all, which is what keeps this from readmitting sheets. The second rule
        // matters on a cold start, where nothing has been seen yet.
        // Measured: a window reports `AXDialog` whenever it is *put away* —
        // minimised, or belonging to an application hidden with ⌘H. Not only
        // minimised, which is what the first version of this assumed, so nine
        // hidden apps' windows were still being dropped: Firefox, Excel, Word,
        // Outlook, Notes, Terminal, TextEdit, Activity Monitor, Google Docs.
        //
        // Still narrow. A genuine dialog is modal and can be neither minimised
        // nor hidden, so requiring one of those states plus a title is what keeps
        // sheets and alerts out.
        let wasStandard = input.standardWindowIDs.contains(id) || newlyStandard.contains(id)
        let isPutAway = isMinimized || isHiddenApp
        let dialogButRealWindow = isPutAway && !title.isEmpty
            && subrole == kAXDialogSubrole as String
        guard isStandard || wasStandard || dialogButRealWindow else { return nil }
        if isStandard { newlyStandard.insert(id) }

        // Minimized windows leave the on-screen set but must still be listed —
        // they're the ones a user most wants a click target for. So do the
        // windows of an application hidden with ⌘H, and that exemption was
        // missing: hiding an app made every one of its windows disappear from
        // the strip as though it had quit. Measured on a machine with a single
        // Space, twelve apps hidden this way — Excel, Word, Outlook, Terminal,
        // Spotify and more — accounted for nearly every window the strip was
        // not showing, and it looked for all the world like a Spaces problem.
        //
        // "Off screen" answers *where the window is drawn*, which is not the same
        // question as *does this window exist on this Desktop*.
        // Zero-size and tiny windows are offscreen scratch windows some apps keep.
        // Checked before the window is counted, so a scratch window never makes
        // its application look like it has one.
        let size = AX.size(element)
        if !isMinimized, let size,
           size.width < input.minimumWindowSide || size.height < input.minimumWindowSide {
            return nil
        }

        // A real window of this application, wherever it happens to be drawn.
        // Deliberately above the current-Space cull: the question this answers is
        // "does the app own a window at all", not "is one on this Desktop".
        sawWindow.insert(app.pid)

        if input.currentSpaceOnly && !isMinimized && !isHiddenApp && !input.onScreen.contains(id) {
            return nil
        }
        let frame = size.flatMap { size in
            AX.position(element).map { CGRect(origin: $0, size: size) }
        }

        return WindowInfo(
            id: id,
            pid: app.pid,
            bundleID: app.bundleID,
            appName: app.name,
            title: title,
            isMinimized: isMinimized,
            frame: frame,
            element: element
        )
    }
}
