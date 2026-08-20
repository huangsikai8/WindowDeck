import AppKit
import SwiftUI

/// Drives the hold-and-tap window switcher.
///
/// ```
/// press ─────▶ build candidates, select index 1, start presentation timer
///    │
///    ├── modifier released first ──▶ commit. Panel never drawn.
///    ├── pressed again first ──────▶ show now, advance selection
///    └── timer fires ──────────────▶ show panel
///                                        │
///              press again ──────────────┤ advance (⇧ reverses)
///              modifier released ────────▶ focus selection, close
///              Escape ───────────────────▶ close, change nothing
/// ```
///
/// **Deciding and drawing are separate.** The candidate list is resolved on the
/// first press, so a quick tap-and-release switches with no UI at all — the way
/// ⌘Tab behaves. Drawing only happens if the modifier is still held, which is
/// what keeps a fast flip from feeling ceremonial.
///
/// It has to be a state machine rather than a keypress handler because the
/// interaction spans several events, and because Carbon reports key-*down*
/// only — noticing the modifier being released needs a separate monitor.
@MainActor
final class SwitcherController {

    var onCommit: ((WindowInfo) -> Void)?
    /// Raise several windows together — what committing a cluster does, and what
    /// clicking one on the strip already does.
    var onCommitAll: (([WindowInfo]) -> Void)?

    /// What is being cycled. The state machine below is identical for both; only
    /// the list, the panel and what committing means differ, which is why this
    /// is a mode rather than a second controller.
    private enum Mode { case windows, entries }
    private var mode: Mode = .windows

    private let store: AppStore
    private let panel = SwitcherPanel()
    private let entryPanel = AppSwitcherPanel()
    private let previews = PreviewService.shared

    /// Held here rather than on a panel's model, because there are two panels
    /// and the machine has to be able to advance without knowing which is up.
    private var selection = 0
    private var candidateCount = 0

    private var isActive = false
    private var triggerFlags: NSEvent.ModifierFlags = []
    private var flagsMonitors: [Any] = []
    private var keyMonitors: [Any] = []
    /// Guards against a tile re-appearing mid-scroll and queueing a second
    /// capture of the same window.
    private var pendingCaptures: Set<CGWindowID> = []
    private var safetyWork: DispatchWorkItem?
    private var presentWork: DispatchWorkItem?
    /// Auto-repeat while the shortcut's key is held down. Carbon delivers one
    /// press however long a hotkey is held, so holding Tab to run down a long
    /// list did nothing without this.
    private var repeatWork: DispatchWorkItem?
    private var repeatTimer: Timer?
    private var repeatDelta = 1
    private var repeatTicks = 0

    /// Matched to the system's own key repeat closely enough to feel native:
    /// a pause long enough that a deliberate single tap never repeats, then a
    /// steady stream fast enough to cross a forty-entry list.
    private static let repeatDelay: TimeInterval = 0.42
    private static let repeatInterval: TimeInterval = 0.085

    init(store: AppStore) {
        self.store = store

        // The pointer can drive either panel: hovering moves the selection,
        // clicking commits it. Both are guarded inside the panel against the
        // pointer merely *being* somewhere when the panel appears under it —
        // otherwise wherever the mouse happened to rest would steal the
        // selection from the keyboard the instant the switcher opened.
        panel.onHoverIndex = { [weak self] index in self?.select(index) }
        panel.onClickIndex = { [weak self] index in self?.select(index); self?.commit() }
        entryPanel.onHoverIndex = { [weak self] index in self?.select(index) }
        entryPanel.onClickIndex = { [weak self] index in self?.select(index); self?.commit() }
        // Only tiles that actually appear on screen ask for a capture, so a
        // large group costs a screenful rather than all of it.
        panel.model.onNeedsImage = { [weak self] window in
            self?.captureIfNeeded(window)
        }
    }

    /// Called on every press of a cycle shortcut.
    func handle(action: ShortcutAction, reversed: Bool, shortcut: Shortcut) {
        let appOnly = (action == .cycleAppWindows)
        let wanted: Mode = (action == .cycleEntries) ? .entries : .windows

        if isActive {
            // A press while a session is open normally means cycling. But if the
            // modifier is no longer down, the previous release was never
            // observed — commit that session and start a fresh one, rather than
            // advancing a session the user already finished. Without this an
            // event arriving late turns two separate flips into one, which is
            // what "it ignored my press" looked like.
            if !NSEvent.modifierFlags.intersection(triggerFlags).contains(triggerFlags) {
                commit()
            } else if wanted != mode {
                // A different switcher entirely while one is open. Finish the
                // session that is up rather than advancing it with the wrong
                // list, then start the new one below.
                commit()
            } else {
                advance(reversed ? -1 : 1)
                // A second press means cycling, not flipping — so stop waiting
                // and show the panel straight away.
                presentNow()
                startRepeat(reversed ? -1 : 1)
                return
            }
        }

        mode = wanted
        if wanted == .entries {
            beginEntries(reversed: reversed, shortcut: shortcut)
            return
        }

        let candidates = store.cycleCandidates(appOnly: appOnly)
        // A single window is still worth showing when the key is *held* — you
        // get to see what the app has — but a quick tap has nothing to switch
        // to, so it commits to the window you are already in and nothing
        // visibly happens. Both halves of "short does nothing, long shows it".
        guard !candidates.isEmpty else { return }

        // Animations disabled at the source. The list is rebuilt in a new
        // most-recently-used order each time, and ForEach matches tiles by window
        // id — so without this SwiftUI animates them sliding to new positions,
        // which is the "swapping" motion. Per-view .animation() modifiers cannot
        // suppress a reorder; the transaction can.
        withTransaction(Transaction(animation: nil)) {
            panel.model.candidates = candidates
            // Where the first tap lands depends on how the list was ordered —
            // index 0 is the current window only in most-recently-used order —
            // so the store decides, next to the ordering that makes it true.
            selection = store.cycleStartIndex(candidates, reversed: reversed)
            candidateCount = candidates.count
            panel.model.selection = selection

            // Everything already captured is shown immediately. Opening performs
            // no capturing of its own — windows you have used were snapshotted
            // when you switched away from them.
            var images: [CGWindowID: NSImage] = [:]
            for window in candidates {
                if let cached = previews.cachedImage(for: window.id, maxAge: PreviewService.switcherMaxAge) {
                    images[window.id] = cached
                }
            }
            panel.model.images = images
        }

        isActive = true
        triggerFlags = shortcut.triggerFlags
        startMonitoring()
        armSafetyTimeout()

        // A very fast tap can release the modifier before the monitor is
        // installed, and that release is then never observed — leaving the panel
        // to appear and hang until the safety timeout. Reading the live modifier
        // state closes that gap: if it is already up, the tap is complete.
        if !NSEvent.modifierFlags.intersection(triggerFlags).contains(triggerFlags) {
            commit()
            return
        }

        // Deliberately not shown yet. Releasing the modifier before this fires
        // commits without ever drawing anything, so a quick flip costs no UI.
        presentWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.presentNow() }
        presentWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + store.switcherHoldDelay, execute: work)
        startRepeat(reversed ? -1 : 1)
    }

    /// ⌥Tab. The same shape as the window path above — build the list, choose
    /// the starting index, arm the machinery — with two differences: the list is
    /// what the strip draws rather than windows, and it always starts at the
    /// neighbour of where you stand, because this switcher is always
    /// most-recently-used. `cycleOrder` is about the *window* switcher, and
    /// reading it here would make a quick ⌥Tab stop flipping to the last thing.
    private func beginEntries(reversed: Bool, shortcut: Shortcut) {
        let entries = store.switchEntries()
        guard !entries.isEmpty else { return }

        withTransaction(Transaction(animation: nil)) {
            entryPanel.model.entries = entries
            selection = entries.count > 1 ? (reversed ? entries.count - 1 : 1) : 0
            candidateCount = entries.count
            entryPanel.model.selection = selection
        }

        isActive = true
        triggerFlags = shortcut.triggerFlags
        startMonitoring()
        armSafetyTimeout()

        if !NSEvent.modifierFlags.intersection(triggerFlags).contains(triggerFlags) {
            commit()
            return
        }

        presentWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.presentNow() }
        presentWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + store.switcherHoldDelay, execute: work)
        startRepeat(reversed ? -1 : 1)
    }

    private func presentNow() {
        presentWork?.cancel()
        presentWork = nil
        guard isActive else { return }
        switch mode {
        case .windows:
            guard !panel.isVisible else { return }
            panel.show()
        case .entries:
            guard !entryPanel.isVisible else { return }
            entryPanel.show()
        }
    }

    /// Commit is driven by seeing the modifier released. If that event is ever
    /// missed — focus changing to something that swallows it, monitors failing —
    /// the panel would sit on screen forever. This bounds that.
    private func armSafetyTimeout() {
        safetyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive else { return }
            // Still holding the modifier? Then this is a deliberate long look at
            // the list, not a release event that went missing — re-arm instead
            // of closing the switcher out from under it. The net still catches
            // the case it exists for, within ten seconds of the key actually
            // being let go.
            if NSEvent.modifierFlags.intersection(self.triggerFlags).contains(self.triggerFlags) {
                self.armSafetyTimeout()
            } else {
                self.commit()
            }
        }
        safetyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }


    /// The pointer picked an entry. Same path as a keyboard advance, so the two
    /// cannot disagree about what "selected" means.
    private func select(_ index: Int) {
        guard isActive, index >= 0, index < candidateCount else { return }
        selection = index
        switch mode {
        case .windows: panel.model.selection = index
        case .entries: entryPanel.model.selection = index
        }
    }

    /// Called when the shortcut's key goes up, while its modifier may still be
    /// held. Ends the repeat and nothing else — the session ends on the
    /// *modifier* being released, which is a different event.
    func handleRelease(action: ShortcutAction) {
        stopRepeat()
    }

    private func startRepeat(_ delta: Int) {
        stopRepeat()
        repeatDelta = delta
        repeatTicks = 0
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive else { return }
            // Showing before the stream starts: a held key is unambiguously
            // cycling rather than flipping, so the panel has earned its place.
            self.presentNow()
            self.repeatTimer = Timer.scheduledTimer(
                withTimeInterval: Self.repeatInterval, repeats: true
            ) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self, self.isActive else { timer.invalidate(); return }
                    // Stop if the modifier has gone, even without a release
                    // event: a repeat that outlives the session would walk the
                    // list on its own, which is worse than a missed repeat.
                    guard NSEvent.modifierFlags.intersection(self.triggerFlags)
                        .contains(self.triggerFlags) else {
                        self.stopRepeat()
                        return
                    }
                    // Bounded. The stream stops when the key is let go, which
                    // arrives as a Carbon release event — and if that event ever
                    // fails to arrive, an unbounded repeat would walk the list
                    // on its own for as long as the modifier stayed down. Two
                    // hundred steps is far more than any list and about
                    // seventeen seconds.
                    self.repeatTicks += 1
                    guard self.repeatTicks < 200 else { self.stopRepeat(); return }
                    self.advance(self.repeatDelta)
                }
            }
        }
        repeatWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.repeatDelay, execute: work)
    }

    private func stopRepeat() {
        repeatWork?.cancel()
        repeatWork = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    private func advance(_ delta: Int) {
        guard candidateCount > 0 else { return }
        selection = ((selection + delta) % candidateCount + candidateCount) % candidateCount
        switch mode {
        case .windows: panel.model.selection = selection
        case .entries: entryPanel.model.selection = selection
        }
    }

    /// Captures a single window that scrolled into view without an image —
    /// typically one you have never visited this session.
    private func captureIfNeeded(_ window: WindowInfo) {
        guard panel.model.images[window.id] == nil else { return }
        guard !pendingCaptures.contains(window.id) else { return }
        pendingCaptures.insert(window.id)

        Task { [weak self] in
            guard let self else { return }
            let image = await self.previews.image(
                for: window,
                maxSize: CGSize(width: SwitcherPanel.tileWidth, height: SwitcherPanel.tileHeight),
                maxAge: PreviewService.switcherMaxAge
            )
            self.pendingCaptures.remove(window.id)
            guard self.isActive, let image else { return }
            self.panel.model.images[window.id] = image
        }
    }

    // MARK: - Finishing

    private func commit() {
        guard isActive else { return }
        switch mode {
        case .windows:
            let selected = panel.model.candidates[safe: selection]
            finish()
            // Skip the raise when the selection is the window already in front —
            // with a lone candidate a quick tap would otherwise re-focus what you
            // are looking at, costing a refresh for no visible effect.
            guard let selected, selected.id != store.focusedWindowID else { return }
            onCommit?(selected)

        case .entries:
            let selected = entryPanel.model.entries[safe: selection]
            let target = selected.map { store.commitTarget(for: $0) } ?? .none
            finish()
            switch target {
            case .focus(let id):
                guard id != store.focusedWindowID,
                      let window = store.windows.first(where: { $0.id == id }) else { return }
                onCommit?(window)
            case .focusAll(let ids):
                let windows = ids.compactMap { id in store.windows.first { $0.id == id } }
                guard !windows.isEmpty else { return }
                onCommitAll?(windows)
            case .open(let bundleID):
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
                      let app = PinnedApp(url: url) else { return }
                AppLauncher.open(app)
            case .none:
                return
            }
        }
    }

    private func cancel() {
        guard isActive else { return }
        finish()
    }

    private func finish() {
        isActive = false
        triggerFlags = []
        stopRepeat()
        selection = 0
        candidateCount = 0
        safetyWork?.cancel()
        safetyWork = nil
        presentWork?.cancel()
        presentWork = nil
        pendingCaptures.removeAll()
        stopMonitoring()
        panel.hide()
        entryPanel.hide()
    }

    // MARK: - Monitors

    /// Both global and local: the app is normally inactive, so the global
    /// monitor does the work, but the local one covers the case where WindowDeck
    /// itself is frontmost.
    private func startMonitoring() {
        stopMonitoring()

        let flagsHandler: (NSEvent) -> Void = { [weak self] event in
            guard let self, self.isActive else { return }
            // Commit the moment the held modifier is gone.
            if !event.modifierFlags.intersection(self.triggerFlags).contains(self.triggerFlags) {
                self.commit()
            }
        }

        let keyHandler: (NSEvent) -> Void = { [weak self] event in
            guard let self, self.isActive else { return }
            if event.keyCode == 53 { self.cancel() }   // Escape
        }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged], handler: flagsHandler) {
            flagsMonitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged], handler: {
            flagsHandler($0); return $0
        }) {
            flagsMonitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: keyHandler) {
            keyMonitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: {
            keyHandler($0); return $0
        }) {
            keyMonitors.append(m)
        }
    }

    private func stopMonitoring() {
        for monitor in flagsMonitors + keyMonitors { NSEvent.removeMonitor(monitor) }
        flagsMonitors.removeAll()
        keyMonitors.removeAll()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
