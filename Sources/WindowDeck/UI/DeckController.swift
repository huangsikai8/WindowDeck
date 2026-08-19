import AppKit
import Observation
import SwiftUI

/// Owns the panel: hosts the SwiftUI content, sizes it to its entries, and keeps
/// it parked at the bottom edge of the active screen.
@MainActor
final class DeckController {

    private let store: AppStore
    private let panel: DeckPanel
    private let hosting: NSHostingView<DeckView>
    let hover = HoverController()
    private let allGroups = AllGroupsPanel()
    private let stackPanel = AppStackPanel()

    private var isHiddenForFullscreen = false
    /// Hidden deliberately via the menu bar item, which fullscreen must not undo.
    private var isUserHidden = false
    private var edgeTimer: Timer?

    init(
        store: AppStore,
        onActivate: @escaping (WindowInfo) -> Void,
        onClose: @escaping (WindowInfo) -> Void,
        onNewGroup: @escaping () -> Void,
        onEditGroups: @escaping () -> Void,
        onActivateAll: @escaping ([WindowInfo]) -> Void,
        onRenameCluster: @escaping (WindowCluster) -> Void
    ) {
        self.store = store

        // Assigned after init so the handlers can reach `self`.
        var hoverHandler: (WindowInfo, Bool, CGRect) -> Void = { _, _, _ in }
        var showAllGroups: () -> Void = {}
        var stackHoverHandler: (String, String, [WindowInfo], Bool, CGRect) -> Void
            = { _, _, _, _, _ in }
        self.hosting = NSHostingView(rootView: DeckView(
            store: store,
            onActivate: onActivate,
            onClose: onClose,
            onNewGroup: onNewGroup,
            onEditGroups: onEditGroups,
            onHover: { window, hovering, frame in hoverHandler(window, hovering, frame) },
            onActivateAll: onActivateAll,
            onRenameCluster: onRenameCluster,
            onShowAllGroups: { showAllGroups() },
            onStackHover: { bundleID, name, windows, hovering, frame in
                stackHoverHandler(bundleID, name, windows, hovering, frame)
            }
        ))

        // Empty sizing options: by default NSHostingView installs constraints
        // from the SwiftUI intrinsic size and resizes the window itself, which
        // fights setContentSize. DeckLayout is the single authority on width.
        self.hosting.sizingOptions = []

        self.panel = DeckPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: DeckMetrics.height))
        self.panel.contentView = hosting

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // On a multi-display setup NSScreen.main follows the focused app, so
        // re-centring on app switch keeps the strip on the display in use.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        showAllGroups = { [weak self] in self?.presentAllGroups() }

        allGroups.onSelect = { [weak self] window in
            guard let self else { return }
            self.onActivateWindow?(window)
        }
        allGroups.model.onClose = onClose
        allGroups.onExpand = { [weak self] groupID in
            self?.store.setCollapsed(false, for: groupID)
        }

        hoverHandler = { [weak self] window, hovering, frame in
            guard let self else { return }
            // Pulled fresh each time so Settings changes take effect immediately.
            self.hover.timings = self.store.hoverTimings
            self.hover.mode = self.store.previewMode
            self.hover.entryHover(
                window,
                anchor: self.screenRect(fromHosting: frame),
                entering: hovering
            )
        }

        stackHoverHandler = { [weak self] bundleID, name, windows, hovering, frame in
            guard let self else { return }
            // The two panels are mutually exclusive: a stack tile has no single
            // window to preview, and leaving one up while the other opens would
            // stack two floating panels over the strip.
            //
            // The stack is asked *first*, and the order is the whole fix for a
            // stacked app stalling in the middle of a sweep. What makes the
            // strip warm is a panel being on screen, and taking the preview down
            // before the stack looks leaves only the lingering window — which is
            // zero for anyone who set it that way, so the stack went back to the
            // full delay while a thumbnail was still visibly up. Nothing left
            // the bar; this is a handover, not a departure. Both run in one
            // turn, so the preview never draws a frame alongside the list.
            self.stackPanel.mode = self.store.previewMode
            self.stackPanel.hover(
                bundleID: bundleID,
                name: name,
                windows: windows,
                anchor: self.screenRect(fromHosting: frame),
                entering: hovering,
                timings: self.store.hoverTimings
            )
            if hovering { self.hover.cancel() }
        }

        stackPanel.onSelect = { [weak self] window in
            self?.onActivateWindow?(window)
        }
    }

    /// SwiftUI reports frames top-left-origin within the hosting view; screen
    /// coordinates are bottom-left-origin.
    private func screenRect(fromHosting rect: CGRect) -> CGRect {
        let frame = panel.frame
        return CGRect(
            x: frame.minX + rect.minX,
            y: frame.minY + (frame.height - rect.maxY),
            width: rect.width,
            height: rect.height
        )
    }

    func show() {
        layout()
        trackLayoutInputs()
        isUserHidden = false
        panel.orderFrontRegardless()
    }

    /// Called whenever fullscreen state changes. The strip gets out of the way
    /// of a genuinely fullscreen window, but stays reachable by pushing the
    /// cursor to the very bottom of the screen — the way the Dock behaves.
    func setFullscreen(_ fullscreen: Bool, enabled: Bool) {
        let shouldHide = fullscreen && enabled
        guard shouldHide != isHiddenForFullscreen else { return }
        isHiddenForFullscreen = shouldHide

        if shouldHide {
            panel.orderOut(nil)
            startEdgeWatch()
        } else {
            stopEdgeWatch()
            if !isUserHidden { panel.orderFrontRegardless() }
        }
    }

    /// Polls the cursor only while hidden for fullscreen. A global event monitor
    /// would run all the time for a case that is usually not active; this costs
    /// nothing in the normal state because the timer doesn't exist.
    private func startEdgeWatch() {
        stopEdgeWatch()
        edgeTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkEdge() }
        }
    }

    private func stopEdgeWatch() {
        edgeTimer?.invalidate()
        edgeTimer = nil
    }

    private func checkEdge() {
        guard let screen = NSScreen.main else { return }
        let mouse = NSEvent.mouseLocation
        let atBottom = mouse.y <= screen.frame.minY + 2

        if atBottom, !panel.isVisible {
            layout()
            panel.orderFrontRegardless()
        } else if panel.isVisible, !panel.frame.insetBy(dx: -8, dy: -8).contains(mouse) {
            panel.orderOut(nil)
        }
    }

    func toggle() {
        if panel.isVisible {
            isUserHidden = true
            panel.orderOut(nil)
        } else {
            show()
        }
    }

    /// Height of the band the strip occupies, for the zoom clamp to reserve.
    ///
    /// Exactly the strip plus the gap beneath it — one `edgeInset`, not two — so
    /// a zoomed window's bottom lands flush on top of the strip rather than
    /// leaving a visible band of desktop above it.
    var reservedBandHeight: CGFloat {
        DeckMetrics.height + DeckMetrics.edgeInset
    }

    var isVisible: Bool { panel.isVisible }

    /// Raising a window from the all-groups panel goes through the same path a
    /// click on the strip does.
    var onActivateWindow: ((WindowInfo) -> Void)?

    /// Builds the panel's rows fresh each time: which groups are folded, and what
    /// each holds, both change constantly.
    private func presentAllGroups() {
        guard !allGroups.isVisible else { return allGroups.hide() }
        // The model builds its own rows now, so an edit made inside the panel is
        // reflected without waiting for the next strip layout.
        allGroups.model.store = store
        allGroups.model.reload()
        allGroups.show(anchor: panel.frame)
    }

    /// Horizontal swipes made while the pointer is over the strip. Needs no
    /// permission — these events come to us because the pointer is here.
    var onStripSwipe: ((GroupCycleDirection) -> Void)? {
        get { panel.onHorizontalSwipe }
        set { panel.onHorizontalSwipe = newValue }
    }

    /// Re-read from the store rather than cached, so moving the slider takes
    /// effect on the next swipe instead of the next launch.
    func syncSwipeSensitivity() {
        panel.threshold = store.stripSwipeThreshold
    }

    /// Screen rect of the drop-up selector chip. The keyboard group switcher
    /// rises from here, so it appears exactly where clicking the chip would have
    /// opened the menu.
    var selectorFrame: NSRect {
        let frame = panel.frame
        return NSRect(
            x: frame.minX + DeckMetrics.padding,
            y: frame.minY + (frame.height - DeckMetrics.tileHeight) / 2,
            width: DeckMetrics.selectorWidth,
            height: DeckMetrics.tileHeight
        )
    }

    /// The strip is exactly as wide as its contents need, capped at the display.
    /// `DeckLayout` decides the per-entry widths so nothing ever has to scroll.
    func layout() {
        guard let screen = NSScreen.main else { return }

        let width: CGFloat = store.isTrusted
            ? DeckLayout.compute(
                items: store.visibleItems,
                pinnedCount: store.visiblePinnedApps.count,
                titlesEnabled: store.showTitles,
                maxWidth: DeckMetrics.maxWidth(screen: screen)
              ).totalWidth
            : 420

        // Only a group change animates. layout() also runs whenever a window
        // opens or closes, and animating those would leave the bar permanently
        // breathing in the corner of your eye.
        let changedGroup = lastLaidOutGroupID != store.activeGroupID
        lastLaidOutGroupID = store.activeGroupID

        // Animating a resize of a 1240pt panel re-lays out every tile in the
        // hosting view on each frame, so overlapping animations from fast
        // swiping stack that cost up. `animateThisChange` is false once a switch
        // interrupts the previous one, and the strip's own slide is gated on the
        // same flag so the two never disagree.
        guard changedGroup, store.animateThisChange, store.animateGroupChanges,
              panel.isVisible else {
            panel.setContentSize(NSSize(width: width, height: DeckMetrics.height))
            reposition()
            return
        }

        // Frame rather than size then origin: the strip is centred, so a resize
        // moves it too, and animating those separately reads as two motions.
        // Matched to the content transition's 0.22s so the bar and its contents
        // arrive together.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(centredFrame(width: width, screen: screen), display: true)
        }
    }

    /// Where the strip sits for a given content width.
    private func centredFrame(width: CGFloat, screen: NSScreen) -> NSRect {
        // Full frame, not visibleFrame — see `reposition()`.
        let screenFrame = screen.frame
        let size = panel.frameRect(forContentRect:
            NSRect(x: 0, y: 0, width: width, height: DeckMetrics.height)).size
        return NSRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.minY + DeckMetrics.edgeInset,
            width: size.width,
            height: size.height
        )
    }

    /// SwiftUI redraws itself when the store changes, but the panel is AppKit —
    /// it has to be told to resize. Re-arms after every change.
    private func trackLayoutInputs() {
        withObservationTracking {
            // The whole array, not just its count: which app each window belongs
            // to decides whether it gets a title, which changes the width.
            _ = store.visibleItems
            _ = store.visiblePinnedApps.count
            _ = store.isTrusted
            _ = store.showTitles
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.layout()
                self.trackLayoutInputs()
            }
        }
    }

    private var lastLaidOutGroupID: UUID?

    private func reposition() {
        // Full frame, not visibleFrame: the real Dock is hidden by the user, and
        // anchoring to visibleFrame would make the strip jump if it reappears.
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.minY + DeckMetrics.edgeInset
        ))
    }

    @objc private func screenParametersChanged() {
        layout()
    }
}
