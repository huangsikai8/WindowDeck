import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let store = AppStore()
    private let engine = WindowEngine()
    private let hotKeys = HotKeyManager()
    private var switcher: SwitcherController!
    private var blurCaptureWork: [CGWindowID: DispatchWorkItem] = [:]
    /// Until this moment, trust the focus we asked for over what the window
    /// server reports — it has not caught up yet.
    private var optimisticFocusUntil: Date = .distantPast
    private var deck: DeckController!
    private var settings: SettingsWindowController!
    private var statusItem: NSStatusItem!
    private var terminationSource: DispatchSourceSignal?
    private var heartbeatTimer: Timer?
    /// What was last handed to Carbon, so an unchanged set is not re-registered.
    private var registeredShortcuts: [ShortcutAction: Shortcut]?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Never shown (agent app), but it is what makes ⌘A/⌘C/⌘V work in the
        // settings window's text fields.
        MainMenu.install()
        installTerminationHandler()
        setUpStatusItem()
        settings = SettingsWindowController(store: store)

        deck = DeckController(
            store: store,
            onActivate: { [weak self] window in self?.engine.focus(window) },
            onClose: { [weak self] window in self?.engine.close(window) },
            onNewGroup: { [weak self] in self?.promptNewGroup() },
            onEditGroups: { [weak self] in self?.openSettings() },
            onActivateAll: { [weak self] windows in self?.engine.focusAll(windows) },
            onRenameCluster: { [weak self] cluster in self?.promptRenameCluster(cluster) }
        )
        deck.onActivateWindow = { [weak self] window in self?.engine.focus(window) }

        // Clicking the thumbnail is the only hover action that really switches.
        deck.hover.onCommit = { [weak self] window in
            self?.engine.focus(window)
        }

        // Record the target the moment we ask for it, rather than waiting for the
        // window server to catch up. Without this, cycling quickly built its
        // candidate list from stale focus and the keypress did nothing.
        engine.onFocusRequested = { [weak self] windowID in
            self?.store.focusedWindowID = windowID
            self?.optimisticFocusUntil = Date().addingTimeInterval(0.6)
        }

        engine.onChange = { [weak self] snapshot in
            guard let self else { return }
            let windows = snapshot.windows
            // Assign only on an actual change. @Observable notifies on every
            // assignment regardless of equality, and each notification redraws
            // the whole strip — re-sorting the windows, recomputing the layout
            // and rebuilding every tile. Refreshes fire several times a second
            // during use and usually carry identical content.
            self.store.sampleRunningApps(windowOwnerPIDs: snapshot.windowOwnerPIDs)
            if windows != self.store.windows {
                self.store.windows = windows
            }
            // Unconditionally, and deliberately outside the equality guard above:
            // `WindowInfo.==` ignores some fields, so a window that changed only in
            // those never reaches this call. Every field this touches is
            // @ObservationIgnored, so it costs dictionary writes and no redraw.
            self.store.noteWindowRefs(windows)
            // Recorded before focus is updated: a window that has just opened
            // already holds focus, so the group context has to come from what we
            // were in immediately before.
            let previousFocus = self.store.focusedWindowID

            // Don't let a stale reading overwrite a focus we just requested;
            // activate() is asynchronous and the server lags behind it.
            if Date() >= self.optimisticFocusUntil || snapshot.focusedWindowID == self.store.focusedWindowID {
                self.optimisticFocusUntil = .distantPast
                if snapshot.focusedWindowID != self.store.focusedWindowID {
                    self.store.focusedWindowID = snapshot.focusedWindowID
                }
            }
            if snapshot.isFullscreen != self.store.isFullscreen {
                self.store.isFullscreen = snapshot.isFullscreen
            }
            self.deck.setFullscreen(snapshot.isFullscreen, enabled: self.store.hideInFullscreen)
            // Groups rebuild themselves here, not at launch: after a reboot the
            // windows arrive gradually as applications reopen.
            //
            // Two steps, and the order still matters: restore first, so a window
            // returning to a saved group is not then treated as brand new and
            // filed wherever you happen to be standing.
            //
            // There used to be four. The two that are gone tried to work out
            // which *previous* window an arriving one was replacing, and that
            // question is no longer asked — a new window joins the capsule being
            // worked in, full stop, and nothing reaches out to claim it back.
            let restored = self.store.restorePass(against: windows)
            self.store.captureNewWindows(snapshot.created,
                                         claimedByRestore: restored,
                                         focusHint: previousFocus)
            self.store.pruneClusters()
            self.store.pruneDeadMembers()
            // After pruning, so a launcher is never born into a slot that is
            // about to be swept away, and before the strip is built, because all
            // three launcher rules are about transitions rather than the present.
            self.store.updateLaunchers()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationLaunched),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )

        engine.currentSpaceOnly = store.currentSpaceOnly
        engine.clampZoomedWindows = store.clampZoomedWindows
        engine.reservedBandHeight = deck.reservedBandHeight
        store.onSettingsChanged = { [weak self] in
            guard let self else { return }
            self.engine.currentSpaceOnly = self.store.currentSpaceOnly
            self.engine.clampZoomedWindows = self.store.clampZoomedWindows
        }

        deck.show()

        switcher = SwitcherController(store: store)
        switcher.onCommit = { [weak self] window in self?.engine.focus(window) }
        // Committing a cluster raises its whole set, exactly as clicking one on
        // the strip does — the same engine call, so the two cannot diverge.
        switcher.onCommitAll = { [weak self] windows in self?.engine.focusAll(windows) }

        store.onWindowLostFocus = { [weak self] window in
            self?.scheduleBlurCapture(window)
        }



        hotKeys.onTrigger = { [weak self] action, reversed in
            guard let self, let shortcut = self.store.shortcuts[action] else { return }
            self.switcher.handle(action: action, reversed: reversed, shortcut: shortcut)
        }
        // The key going up, which is not the modifier going up: it ends the
        // auto-repeat and leaves the session open.
        hotKeys.onRelease = { [weak self] action in
            self?.switcher.handleRelease(action: action)
        }
        store.onShortcutsChanged = { [weak self] in self?.syncHotKeys() }
        syncHotKeys()

        NSLog("WindowDeck: launched — accessibility trusted = %@", Permissions.isTrusted ? "YES" : "NO")

        // Permission state first, because it explains most "it does nothing"
        // reports on its own: without Accessibility the app is inert, and
        // without Screen Recording the previews silently show nothing.
        Trace.log(.system, "permissions — accessibility \(Permissions.isTrusted ? "granted" : "DENIED")")
        Trace.log(.system, "settings — \(store.groups.count) groups, preview \(store.previewMode), "
            + "currentSpaceOnly \(store.currentSpaceOnly), "
            + "\(store.shortcuts.count) shortcuts bound")
        startHeartbeat()

        if Permissions.isTrusted {
            engine.start()
        } else {
            Trace.warn(.system, "accessibility DENIED — engine not started, app is inert until granted")
            // The strip stays up showing a "Grant Accessibility…" affordance;
            // trust is only re-read out of band, so we watch for the flip.
            Permissions.requestTrust()
            Permissions.pollUntilTrusted { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated {
                    NSLog("WindowDeck: accessibility granted — starting engine")
                    Trace.log(.system, "accessibility granted — starting engine")
                    self.store.refreshTrust()
                    self.engine.start()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Trace.log(.app, "terminating — flushing state")
        store.saveNow()
        engine.stop()
        hotKeys.unregisterAll()
        heartbeatTimer?.invalidate()
        // Last, so everything above is already on disk when the clean-exit
        // marker is written. A marker that beats the final lines would claim a
        // tidy shutdown for a session that never finished one.
        Trace.markCleanExit()
    }

    /// `pkill` — which the build script uses on every rebuild — sends SIGTERM,
    /// and the default disposition kills the process outright without running
    /// `applicationWillTerminate`. Handling it means group membership survives a
    /// rebuild rather than depending on the build script being careful.
    private func installTerminationHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            Trace.log(.app, "SIGTERM received (rebuild or kill) — saving before exit")
            self?.store.saveNow()
            NSApp.terminate(nil)
        }
        source.resume()
        terminationSource = source
    }

    /// Registration and the record of what registered must move together —
    /// keeping them in one place is what stops the Settings list showing a
    /// working shortcut as unavailable after groups change.
    private func syncHotKeys() {
        let usable = store.shortcuts

        // `register` unregisters everything first, so repeating it with an
        // identical set is not merely wasted work — it leaves a window in which
        // no shortcut is bound at all. This used to be driven by an observation
        // tracker on `groups`, which fires on *any* mutation and not only on a
        // change of count: the diagnostics log showed every hotkey being torn
        // down and rebuilt roughly every three seconds, indefinitely. The
        // tracker is gone with the group shortcuts it existed for, and this
        // guard stays, because the cost of getting it wrong is silence.
        guard usable != registeredShortcuts else { return }
        registeredShortcuts = usable
        hotKeys.register(usable)
        store.registeredActions = hotKeys.registeredActions

        // Registration failing means macOS already owns the combination. Settings
        // shows this per row, but a log line makes it answerable without opening
        // anything — "the key does nothing" is otherwise indistinguishable from a
        // bug in the action itself.
        let refused = usable.keys.filter { !hotKeys.registeredActions.contains($0) }
        Trace.log(.hotkey, "registered \(hotKeys.registeredActions.count)/\(usable.count) shortcuts"
            + (refused.isEmpty ? "" : " — macOS refused \(refused.map(\.storageKey).joined(separator: ", "))"),
            level: refused.isEmpty ? .info : .warn)
        if !refused.isEmpty {
            NSLog("WindowDeck: system refused %@", refused
                .map { "\($0.storageKey)=\(store.shortcuts[$0]?.displayString ?? "?")" }
                .sorted().joined(separator: ", "))
        }
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "rectangle.3.group",
            accessibilityDescription: "WindowDeck"
        )

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Toggle Deck", action: #selector(toggleDeck), keyEquivalent: "d"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "New Group…", action: #selector(promptNewGroup), keyEquivalent: "n"))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Reveal Diagnostics Log",
                                action: #selector(revealLog), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit WindowDeck", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    /// Snapshots a window shortly after it loses focus.
    ///
    /// Debounced because ⌘Tabbing quickly passes focus *through* several windows
    /// on the way somewhere — without this, each one in transit would be
    /// captured despite never really being looked at. Only the window you
    /// actually left settles long enough to be worth recording.
    private func scheduleBlurCapture(_ window: WindowInfo) {
        blurCaptureWork[window.id]?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.blurCaptureWork.removeValue(forKey: window.id)
            Task { @MainActor in
                await PreviewService.shared.warm(
                    window,
                    maxSize: CGSize(width: SwitcherPanel.tileWidth, height: SwitcherPanel.tileHeight)
                )
            }
        }
        blurCaptureWork[window.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    @objc private func applicationLaunched() {
        store.extendRestoreWindow()
    }

    /// Selects the log in the Finder rather than opening it. A log is read in
    /// whatever the reader prefers, and its neighbour — the previous
    /// generation — is usually wanted too.
    @objc private func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([Trace.logURL])
    }

    /// One line a minute saying what this process actually costs.
    ///
    /// Deliberately a fixed, slow cadence rather than something tied to
    /// activity: the question it answers — "was WindowDeck the thing making the
    /// machine slow?" — is asked after the fact, about a period nobody was
    /// measuring at the time. It has twice turned out to be something else, so
    /// the log needs to be able to say so.
    private func startHeartbeat() {
        Trace.heartbeat(windows: store.windows.count, groups: store.groups.count)
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Trace.heartbeat(windows: self.store.windows.count, groups: self.store.groups.count)
            }
        }
    }

    @objc private func toggleDeck() {
        deck.toggle()
    }

    @objc private func promptNewGroup() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Personal"

        let alert = NSAlert()
        alert.messageText = "New Group"
        alert.informativeText = "Name this arrangement."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        // An accessory app has to activate before a modal will come forward.
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        store.addGroup(named: name)
    }

    private func promptRenameCluster(_ cluster: WindowCluster) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = cluster.customName ?? ""
        field.placeholderString = "Project"

        let alert = NSAlert()
        alert.messageText = "Name This Group of Windows"
        alert.informativeText = "Leave blank to show the window count instead."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.renameCluster(cluster.id, to: field.stringValue)
    }

    @objc private func openSettings() {
        settings.show()
    }

    @objc private func quit() {
        store.saveNow()
        NSApp.terminate(nil)
    }
}
