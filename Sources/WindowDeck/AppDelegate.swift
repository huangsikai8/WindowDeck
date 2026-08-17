import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let store = AppStore()
    private let engine = WindowEngine()
    private let hotKeys = HotKeyManager()
    private var switcher: SwitcherController!
    private var groupSwitcher: GroupSwitcherController!
    private let gestures = GestureMonitor()
    private var blurCaptureWork: [CGWindowID: DispatchWorkItem] = [:]
    /// Until this moment, trust the focus we asked for over what the window
    /// server reports — it has not caught up yet.
    private var optimisticFocusUntil: Date = .distantPast
    private var deck: DeckController!
    private var settings: SettingsWindowController!
    private var statusItem: NSStatusItem!
    private var terminationSource: DispatchSourceSignal?

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
            if windows != self.store.windows {
                self.store.windows = windows
                self.store.noteWindowRefs(windows)
            }
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
            // Restore first: a window that belongs to a saved group should rejoin
            // it rather than be captured by whichever group is active.
            let restored = self.store.restorePass(against: windows)
            self.store.captureNewWindows(snapshot.created, claimedByRestore: restored)
            self.store.pruneClusters()
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

        groupSwitcher = GroupSwitcherController(store: store)
        // Read live rather than captured: the strip resizes constantly as
        // windows open and close, so a rect taken once would soon be wrong.
        groupSwitcher.anchorProvider = { [weak self] in self?.deck.selectorFrame ?? .zero }

        // Two independent paths to the same action. The strip swipe is free;
        // the global one costs Input Monitoring, so it is opt-in and either can
        // run without the other.
        gestures.onSwipe = { [weak self] direction in self?.stepGroup(direction) }
        deck.onStripSwipe = { [weak self] direction in
            guard let self, self.store.swipeOverStrip else { return }
            self.stepGroup(direction)
        }
        store.onGestureSettingsChanged = { [weak self] in self?.syncGestures() }
        syncGestures()

        store.onWindowLostFocus = { [weak self] window in
            self?.scheduleBlurCapture(window)
        }



        hotKeys.onTrigger = { [weak self] action, reversed in
            guard let self else { return }
            switch action {
            case .selectGroup(let position):
                self.store.selectGroup(atPosition: position)
            case .cycleGroupWindows, .cycleAppWindows:
                guard let shortcut = self.store.shortcuts[action] else { return }
                self.switcher.handle(action: action, reversed: reversed, shortcut: shortcut)
            case .cycleGroups(let direction):
                guard let shortcut = self.store.shortcuts[action] else { return }
                self.groupSwitcher.handle(direction: direction, shortcut: shortcut)
            }
        }
        store.onShortcutsChanged = { [weak self] in self?.syncHotKeys() }
        syncHotKeys()
        trackGroupCount()

        NSLog("WindowDeck: launched — accessibility trusted = %@", Permissions.isTrusted ? "YES" : "NO")

        if Permissions.isTrusted {
            engine.start()
        } else {
            // The strip stays up showing a "Grant Accessibility…" affordance;
            // trust is only re-read out of band, so we watch for the flip.
            Permissions.requestTrust()
            Permissions.pollUntilTrusted { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated {
                    NSLog("WindowDeck: accessibility granted — starting engine")
                    self.store.refreshTrust()
                    self.engine.start()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow()
        engine.stop()
        hotKeys.unregisterAll()
    }

    /// `pkill` — which the build script uses on every rebuild — sends SIGTERM,
    /// and the default disposition kills the process outright without running
    /// `applicationWillTerminate`. Handling it means group membership survives a
    /// rebuild rather than depending on the build script being careful.
    private func installTerminationHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
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
        // Only offer group shortcuts for groups that exist, or a stale binding
        // would occupy a combination nothing can reach.
        let usable = store.shortcuts.filter { action, _ in
            if case .selectGroup(let position) = action {
                return position <= store.groups.count
            }
            return true
        }
        hotKeys.register(usable)
        store.registeredActions = hotKeys.registeredActions

        // Registration failing means macOS already owns the combination. Settings
        // shows this per row, but a log line makes it answerable without opening
        // anything — "the key does nothing" is otherwise indistinguishable from a
        // bug in the action itself.
        let refused = usable.keys.filter { !hotKeys.registeredActions.contains($0) }
        if !refused.isEmpty {
            NSLog("WindowDeck: system refused %@", refused
                .map { "\($0.storageKey)=\(store.shortcuts[$0]?.displayString ?? "?")" }
                .sorted().joined(separator: ", "))
        }
    }

    /// Adding, deleting or reordering groups changes which position each
    /// shortcut maps to, so the registrations are rebuilt.
    private func trackGroupCount() {
        withObservationTracking {
            _ = store.groups.count
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.syncHotKeys()
                self.trackGroupCount()
            }
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
        store.selectGroup(store.addGroup(named: name).id)
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

    /// One step through the groups, the same move a tap of ⌘↑/⌘↓ makes. A swipe
    /// is a discrete gesture with no held modifier, so it commits immediately
    /// rather than opening the list.
    private func stepGroup(_ direction: GroupCycleDirection) {
        let index = store.groupIndex(steppedBy: direction.step, from: store.activeGroupIndex)
        guard store.groups.indices.contains(index) else { return }
        // Direction passed explicitly so the slide follows the swipe even when
        // the step wraps round the end of the list.
        store.selectGroup(store.groups[index].id, direction: direction)
    }

    /// Starts, stops or reconfigures the global tap to match the settings.
    private func syncGestures() {
        gestures.fingerCounts = store.swipeFingerCounts
        gestures.travelThreshold = store.globalSwipeTravel
        deck.syncSwipeSensitivity()

        guard store.globalSwipeGesture else {
            gestures.stop()
            return
        }
        guard !gestures.isRunning else { return }
        if !gestures.start() {
            // Not yet granted. Prompt once; the toggle stays on so it starts by
            // itself as soon as the permission lands.
            Permissions.requestInputMonitoring()
            Permissions.pollUntilInputMonitoring { [weak self] in
                _ = self?.gestures.start()
            }
        }
    }

    @objc private func quit() {
        store.saveNow()
        NSApp.terminate(nil)
    }
}
