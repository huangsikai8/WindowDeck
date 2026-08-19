import AppKit
import SwiftUI

/// Drives the whole hover escalation:
///
/// ```
/// entry hover ──instant──▶ title bar
///                  ──0.15s──▶ same panel grows upward into a thumbnail
///                       cursor onto panel ──▶ full-size peek
///                            click panel ──▶ actually switch
/// ```
///
/// The title and thumbnail are deliberately **one panel with two heights**, not
/// two panels. An earlier version swapped a small chip for a separate larger
/// popup after 150ms, which made the UI change shape under the cursor and left
/// the title unreadable. Here nothing is ever replaced: the panel's bottom edge
/// and horizontal centre are identical in both states, so the caption does not
/// move a pixel while the image area grows above it.
///
/// Stages before the click change nothing real. The peek is an image drawn over
/// the window's own position, so a mis-hover costs nothing and needs no undo.
@MainActor
final class HoverController {

    /// Called when the user clicks the panel — the one action that really
    /// switches windows.
    var onCommit: ((WindowInfo) -> Void)?

    private let service = PreviewService.shared
    private let peek = PeekOverlayController()

    private let panel: NSPanel
    private let hosting: NSHostingView<PreviewContent>
    private let model = PreviewModel()

    private var showWork: DispatchWorkItem?
    private var expandWork: DispatchWorkItem?
    private var peekWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?

    private var current: WindowInfo?
    private var currentAnchor: CGRect = .zero
    private var isOverPanel = false

    /// Read fresh on every hover so Settings changes apply without a restart.
    var timings: HoverTimings = .defaults
    var mode: PreviewMode = .thumbnailAndPeek

    /// Expanded size. The caption bar keeps `captionHeight` of this at the bottom.
    static let expandedSize = CGSize(width: 260, height: 190)
    static let captionHeight: CGFloat = 30
    /// Overlap with the entry, so the cursor never crosses dead space on its way
    /// up to the panel.
    private static let entryOverlap: CGFloat = 2

    init() {
        hosting = NSHostingView(rootView: PreviewContent(model: model))
        hosting.sizingOptions = []

        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: HoverController.expandedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Above the strip (.floating, 3) but below the menu layer (101).
        // At .popUpMenu this tied with context menus, and ties resolve by
        // whichever was ordered front last — always this panel — so right-click
        // menus opened behind it.
        panel.level = NSWindow.Level(rawValue: 5)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        // Interactive: this panel is what the cursor rests on to hold the peek
        // open, and what gets clicked to commit.
        panel.ignoresMouseEvents = false
        panel.animationBehavior = .none
        panel.contentView = hosting

        hosting.rootView = PreviewContent(
            model: model,
            onHover: { [weak self] hovering in self?.panelHover(hovering) },
            onClick: { [weak self] in self?.commit() }
        )
    }

    // MARK: - Strip entry hover

    /// The in-flight preview capture, so it can be abandoned the moment the
    /// pointer moves somewhere else.
    private var captureTask: Task<Void, Never>?

    func entryHover(_ window: WindowInfo, anchor: CGRect, entering: Bool) {
        guard entering else {
            // Sliding from one entry to the next, SwiftUI delivers the new
            // entry's enter *before* the old entry's exit. Without this guard
            // the stale exit cancels the work just scheduled for the new entry,
            // so the second entry hovered would show a title that never expands
            // and then vanish.
            guard current?.id == window.id else { return }
            scheduleHide()
            return
        }

        hideWork?.cancel()

        // Same window already showing — don't restart the escalation.
        if current?.id == window.id, panel.isVisible {
            currentAnchor = anchor
            return
        }

        // Whatever was being captured for the previous entry is no longer
        // wanted; letting it finish is pure waste.
        captureTask?.cancel()

        current = window
        currentAnchor = anchor
        model.caption = Self.caption(for: window)

        showWork?.cancel()
        expandWork?.cancel()

        // Already scanning the strip: go straight to the thumbnail. The delay
        // exists to avoid firing on a passing sweep, and that has already been
        // settled by the time the panel is up. Skipping the collapsed state
        // entirely also avoids a visible shrink-then-grow between entries.
        if isWarm && mode.wantsThumbnail {
            model.image = service.cachedImage(for: window.id)
            expand(window, anchor: anchor)
            return
        }

        model.image = nil
        model.isExpanded = false

        let present: () -> Void = { [weak self] in self?.presentCollapsed(anchor: anchor) }
        if timings.titleDelay > 0 {
            let work = DispatchWorkItem(block: present)
            showWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + timings.titleDelay, execute: work)
        } else {
            present()
        }

        guard mode.wantsThumbnail else { return }

        let work = DispatchWorkItem { [weak self] in self?.expand(window, anchor: anchor) }
        expandWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timings.thumbnailDelay, execute: work)
    }

    /// True while a thumbnail is on screen, and briefly after one was — so a
    /// short hop off the strip, or the gap between two entries, doesn't reset
    /// you to the full wait.
    private var isWarm: Bool {
        if panel.isVisible && model.isExpanded { return true }
        // Shared with the app-stack list: warmth belongs to the strip, not to
        // one panel, or crossing between the two re-imposes the full delay.
        return StripWarmth.shared.isWarm
    }

    // MARK: - The two states

    private func presentCollapsed(anchor: CGRect) {
        layout(anchor: anchor, expanded: false)
        panel.orderFrontRegardless()
    }

    private func expand(_ window: WindowInfo, anchor: CGRect) {
        StripWarmth.shared.hold("preview")
        model.isExpanded = true
        layout(anchor: anchor, expanded: true)
        panel.orderFrontRegardless()

        if let cached = service.cachedImage(for: window.id) {
            model.image = cached
            return
        }

        // Cancellable, and deliberately not started immediately.
        //
        // Sweeping the pointer along the strip used to fire one capture per tile
        // passed over. The results were discarded once the cursor moved on, but
        // the captures still ran to completion — twenty tiles meant twenty
        // ScreenCaptureKit captures to display one image, which is what made
        // hovering feel heavy. Waiting for the pointer to settle means a sweep
        // now issues none at all.
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled, self.current?.id == window.id else { return }

            let image = await self.service.image(
                for: window,
                maxSize: CGSize(
                    width: HoverController.expandedSize.width - 16,
                    height: HoverController.expandedSize.height - HoverController.captionHeight - 14
                )
            )
            // The cursor may have moved on while the capture was in flight.
            guard !Task.isCancelled, self.current?.id == window.id else { return }

            guard let image else {
                // Capture refused or the window vanished. Settle back to the
                // title bar rather than showing an error card on every hover —
                // Settings ▸ Permissions is where that belongs.
                self.model.isExpanded = false
                self.layout(anchor: self.currentAnchor, expanded: false)
                return
            }
            self.model.image = image
        }
    }

    /// One frame calculation for both states. The width is deliberately the
    /// same in both: only the height changes. Sizing the title bar to its text
    /// meant a long title showed in full and was then truncated the instant the
    /// panel snapped to the thumbnail width — the text visibly reflowing under
    /// the cursor. A constant width lays the caption out identically throughout.
    ///
    /// `origin.y` is pinned to the entry, so the extra height grows upward and
    /// the caption never moves.
    private func layout(anchor: CGRect, expanded: Bool) {
        let width = HoverController.expandedSize.width
        let height = expanded ? HoverController.expandedSize.height : HoverController.captionHeight

        var x = anchor.midX - width / 2
        if let screen = NSScreen.main {
            x = min(max(x, screen.frame.minX + 8), screen.frame.maxX - width - 8)
        }
        let y = anchor.maxY - Self.entryOverlap

        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    private static func caption(for window: WindowInfo) -> String {
        let base = window.title.isEmpty
            ? window.appName
            : "\(window.title) — \(window.appName)"
        return window.isMinimized ? "\(base) (minimized)" : base
    }

    // MARK: - Peek

    private func panelHover(_ hovering: Bool) {
        isOverPanel = hovering

        guard hovering else {
            // Leaving the panel ends the peek at once — that is the whole
            // dismissal contract.
            peekWork?.cancel()
            peek.hide()
            scheduleHide()
            return
        }

        hideWork?.cancel()
        guard mode.wantsPeek, let window = current, !window.isMinimized else { return }

        peekWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.presentPeek(window) }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timings.peekDelay, execute: work)
    }

    private func presentPeek(_ window: WindowInfo) {
        Task { [weak self] in
            guard let self else { return }
            guard let capture = await self.service.fullSizeCapture(for: window) else { return }
            // Still hovering the same panel?
            guard self.isOverPanel, self.current?.id == window.id else { return }
            self.peek.show(image: capture.image, at: capture.screenRect)
        }
    }

    private func commit() {
        guard let window = current else { return }
        hideAll()
        onCommit?(window)
    }

    // MARK: - Dismissal

    private func scheduleHide() {
        // Deliberately does not cancel the pending show/expand work. Moving
        // within a single entry produces spurious exit-then-enter pairs, and the
        // re-enter takes the "same window, already visible" early return — so
        // anything cancelled here would never be rescheduled and the panel would
        // sit at title-only forever. If the hide actually fires, `hideAll`
        // cancels them then.
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isOverPanel else { return }
            self.hideAll()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timings.hideGrace, execute: work)
    }

    private func hideAll() {
        showWork?.cancel()
        expandWork?.cancel()
        peekWork?.cancel()
        hideWork?.cancel()
        captureTask?.cancel()
        // Drop stale captures here rather than on a timer — full-size window
        // images are large, and this is the natural idle moment.
        service.evictExpired()
        // Stay warm briefly, so glancing away and back doesn't re-impose the
        // full delay.
        if model.isExpanded {
            StripWarmth.shared.release("preview", staying: timings.warmWindow)
        } else {
            StripWarmth.shared.release("preview", staying: 0)
        }
        peek.hide()
        panel.orderOut(nil)
        current = nil
        isOverPanel = false
        model.isExpanded = false
        model.image = nil
    }

    func forget(_ id: CGWindowID) {
        service.forget(id)
    }

    /// Takes the preview down at once, cancelling anything scheduled.
    ///
    /// For the moment the pointer moves onto a stacked app: that tile has its own
    /// panel and no single window to preview, so both must never be up together.
    func cancel() {
        guard current != nil || panel.isVisible else { return }
        hideAll()
    }
}

@MainActor
@Observable
final class PreviewModel {
    var caption: String = ""
    var image: NSImage?
    var isExpanded = false
}

struct PreviewContent: View {
    @Bindable var model: PreviewModel
    var onHover: (Bool) -> Void = { _ in }
    var onClick: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            // Collapses to nothing in the title-only state, so the caption below
            // keeps its exact position while this grows above it.
            if model.isExpanded {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.primary.opacity(0.06))

                    if let image = model.image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                // Fades rather than pops as the capture arrives.
                .opacity(model.image == nil ? 0.55 : 1)
                .animation(.easeOut(duration: 0.12), value: model.image != nil)
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Text(model.caption)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 9)
                .frame(maxWidth: .infinity)
                .frame(height: HoverController.captionHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffectBackground(material: .popover))
        .clipShape(RoundedRectangle(cornerRadius: model.isExpanded ? 12 : 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: model.isExpanded ? 12 : 7, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .onTapGesture(perform: onClick)
    }
}
