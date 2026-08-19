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

    private let store: AppStore
    private let panel = SwitcherPanel()
    private let previews = PreviewService.shared

    private var isActive = false
    private var triggerFlags: NSEvent.ModifierFlags = []
    private var flagsMonitors: [Any] = []
    private var keyMonitors: [Any] = []
    /// Guards against a tile re-appearing mid-scroll and queueing a second
    /// capture of the same window.
    private var pendingCaptures: Set<CGWindowID> = []
    private var safetyWork: DispatchWorkItem?
    private var presentWork: DispatchWorkItem?

    init(store: AppStore) {
        self.store = store
        // Only tiles that actually appear on screen ask for a capture, so a
        // large group costs a screenful rather than all of it.
        panel.model.onNeedsImage = { [weak self] window in
            self?.captureIfNeeded(window)
        }
    }

    /// Called on every press of a cycle shortcut.
    func handle(action: ShortcutAction, reversed: Bool, shortcut: Shortcut) {
        let appOnly = (action == .cycleAppWindows)

        if isActive {
            // A press while a session is open normally means cycling. But if the
            // modifier is no longer down, the previous release was never
            // observed — commit that session and start a fresh one, rather than
            // advancing a session the user already finished. Without this an
            // event arriving late turns two separate flips into one, which is
            // what "it ignored my press" looked like.
            if !NSEvent.modifierFlags.intersection(triggerFlags).contains(triggerFlags) {
                commit()
            } else {
                advance(reversed ? -1 : 1)
                // A second press means cycling, not flipping — so stop waiting
                // and show the panel straight away.
                presentNow()
                return
            }
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
            panel.model.selection = store.cycleStartIndex(candidates, reversed: reversed)

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
    }

    private func presentNow() {
        presentWork?.cancel()
        presentWork = nil
        guard isActive, !panel.isVisible else { return }
        panel.show()
    }

    /// Commit is driven by seeing the modifier released. If that event is ever
    /// missed — focus changing to something that swallows it, monitors failing —
    /// the panel would sit on screen forever. This bounds that.
    private func armSafetyTimeout() {
        safetyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.commit() }
        safetyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }


    private func advance(_ delta: Int) {
        let count = panel.model.candidates.count
        guard count > 0 else { return }
        panel.model.selection = ((panel.model.selection + delta) % count + count) % count
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
        let selected = panel.model.candidates[safe: panel.model.selection]
        finish()
        // Skip the raise when the selection is the window already in front —
        // with a lone candidate a quick tap would otherwise re-focus what you
        // are looking at, costing a refresh for no visible effect.
        guard let selected, selected.id != store.focusedWindowID else { return }
        onCommit?(selected)
    }

    private func cancel() {
        guard isActive else { return }
        finish()
    }

    private func finish() {
        isActive = false
        triggerFlags = []
        safetyWork?.cancel()
        safetyWork = nil
        presentWork?.cancel()
        presentWork = nil
        pendingCaptures.removeAll()
        stopMonitoring()
        panel.hide()
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
