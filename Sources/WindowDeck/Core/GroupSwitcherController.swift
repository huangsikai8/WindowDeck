import AppKit
import SwiftUI

/// Drives ⌘↑/⌘↓ — the same hold-and-tap shape as the window switcher, applied to
/// the groups themselves.
///
/// ```
/// press ─────▶ step one group, start presentation timer
///    │
///    ├── modifier released first ──▶ switch. Panel never drawn.
///    ├── pressed again first ──────▶ show now, step again
///    └── timer fires ──────────────▶ show the list
///                                        │
///              press again ──────────────┤ step (the other key reverses)
///              modifier released ────────▶ switch to selection, close
///              Escape ───────────────────▶ close, change nothing
/// ```
///
/// Kept separate from `SwitcherController` rather than generalised. The two look
/// alike but differ in what they cycle, what they draw, where it appears and
/// what committing means — and that controller's timing is the most
/// hard-earned code in the project. Merging them would put the working one at
/// risk to save a state machine that fits on one screen.
@MainActor
final class GroupSwitcherController {

    private let store: AppStore
    private let panel = GroupSwitcherPanel()

    /// Supplies the screen rect of the selector chip, so the list rises from the
    /// same place the drop-up menu does.
    var anchorProvider: (() -> NSRect)?

    /// Which way this session last moved, so the strip slides to match even when
    /// the selection wrapped past the end of the list.
    private var lastDirection: GroupCycleDirection = .next
    private var isActive = false
    private var triggerFlags: NSEvent.ModifierFlags = []
    private var flagsMonitors: [Any] = []
    private var keyMonitors: [Any] = []
    private var safetyWork: DispatchWorkItem?
    private var presentWork: DispatchWorkItem?

    init(store: AppStore) {
        self.store = store
    }

    /// Called on every press of a group-cycle shortcut.
    func handle(direction: GroupCycleDirection, shortcut: Shortcut) {
        guard store.groups.count > 1 else { return }

        if isActive {
            // A press while a session is open means stepping further. But if the
            // modifier is already up, the release was never observed — finish
            // that session and start a new one, rather than folding two separate
            // switches into one.
            if !NSEvent.modifierFlags.intersection(triggerFlags).contains(triggerFlags) {
                commit()
            } else {
                lastDirection = direction
                advance(direction.step)
                // Pressing twice means browsing, not flipping — so stop waiting.
                presentNow()
                return
            }
        }

        withTransaction(Transaction(animation: nil)) {
            panel.model.groups = store.groups
            panel.model.activeGroupID = store.activeGroupID
            // The first press already moves one place: a tap should switch, not
            // land back on the group you are in.
            panel.model.selection = store.groupIndex(
                steppedBy: direction.step, from: store.activeGroupIndex
            )
        }

        lastDirection = direction
        isActive = true
        triggerFlags = shortcut.triggerFlags
        startMonitoring()
        armSafetyTimeout()

        // A very fast tap can release the modifier before the monitor is
        // installed, leaving the panel to appear and hang until the safety
        // timeout. Reading the live state closes that gap.
        if !NSEvent.modifierFlags.intersection(triggerFlags).contains(triggerFlags) {
            commit()
            return
        }

        presentWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.presentNow() }
        presentWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + store.switcherHoldDelay, execute: work)
    }

    private func advance(_ delta: Int) {
        panel.model.selection = store.groupIndex(steppedBy: delta, from: panel.model.selection)
    }

    private func presentNow() {
        presentWork?.cancel()
        presentWork = nil
        guard isActive, !panel.isVisible else { return }
        panel.show(anchor: anchorProvider?() ?? .zero)
    }

    /// If the release is ever missed — focus moving to something that swallows
    /// it, a monitor failing — the panel would sit there forever. This bounds it.
    private func armSafetyTimeout() {
        safetyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.commit() }
        safetyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    // MARK: - Finishing

    private func commit() {
        guard isActive else { return }
        let selected = panel.model.selectedGroupID
        finish()
        guard let selected, selected != store.activeGroupID else { return }
        store.selectGroup(selected, direction: lastDirection)
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
        stopMonitoring()
        panel.hide()
    }

    // MARK: - Monitors

    /// Global and local both: the app is normally inactive, so the global
    /// monitor does the work, but the local one covers WindowDeck being
    /// frontmost — its own settings window, for instance.
    private func startMonitoring() {
        stopMonitoring()

        let flagsHandler: (NSEvent) -> Void = { [weak self] event in
            guard let self, self.isActive else { return }
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
