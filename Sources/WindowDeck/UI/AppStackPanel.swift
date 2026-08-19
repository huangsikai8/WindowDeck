import AppKit
import SwiftUI

/// The windows behind a stacked app's icon, on a row above the strip.
///
/// Modelled on `AllGroupsPanel` — a mouse-driven list anchored to the strip —
/// and deliberately **not** on `SwitcherPanel`, which sets
/// `ignoresMouseEvents = true` because it is driven entirely from the keyboard.
/// This one exists to be clicked.
///
/// It is also separate from `HoverController` rather than a mode of it. That
/// panel escalates title → thumbnail → peek for *one* window, and every stage of
/// its state machine assumes a single `current` window; teaching it to show a
/// list would mean two behaviours sharing one set of timers, which is the shape
/// of the bugs its comments already record.
@MainActor
final class AppStackPanel {

    private let panel: NSPanel
    private let hosting: NSHostingView<AppStackContent>
    let model = AppStackModel()

    /// Raise this window and close.
    var onSelect: ((WindowInfo) -> Void)?

    private var dismissMonitors: [Any] = []
    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    /// The stack the pointer is on, recorded the moment it arrives.
    ///
    /// Deliberately *not* `model.bundleID`, which only becomes true once the
    /// panel is actually presented — a delay later. Leaving the tile before then
    /// left the exit path unable to recognise its own stack, so it returned
    /// without cancelling the pending show and the panel appeared with the
    /// pointer somewhere else entirely. `HoverController` avoids this by
    /// recording `current` on entry; this is that variable.
    private var current: String?
    /// True while the pointer is on the panel itself, so it survives the gap
    /// between leaving the tile and arriving on the list.
    private var isOverPanel = false
    /// Guards against one window being captured twice while the panel is up.
    private var pendingCaptures: Set<CGWindowID> = []
    /// The user's warm window, kept from the last hover. `hide()` is the place
    /// warmth is given up and it has no timings of its own.
    private var warmWindow: TimeInterval = HoverTimings.defaults.warmWindow

    /// Same tile as the switcher's grid, deliberately. These are windows of one
    /// application, so the *content* is what tells them apart — Chrome titles are
    /// routinely identical — and the switcher already sizes a window preview
    /// legibly and captures on demand.
    static let tileWidth = SwitcherPanel.tileWidth
    static let tileHeight = SwitcherPanel.tileHeight
    static let tileSpacing: CGFloat = 6
    private static let plateInset: CGFloat = 12
    /// One row, always. Past this the row scrolls sideways rather than wrapping:
    /// a second row moves every tile in the first one down as the panel grows,
    /// so the tile being reached for shifts while it is being reached for.
    private static let maxWidth: CGFloat = 980

    init() {
        hosting = NSHostingView(rootView: AppStackContent(model: model))
        hosting.sizingOptions = []

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Same level as the hover preview, not `.popUpMenu`: at `.popUpMenu` this
        // ties with context menus, and ties resolve by whichever was ordered
        // front last — so a right-click menu would open behind it.
        panel.level = NSWindow.Level(rawValue: 5)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.contentView = hosting

        model.onSelect = { [weak self] window in
            self?.hide()
            self?.onSelect?(window)
        }
        model.onNeedsImage = { [weak self] window in
            self?.captureIfNeeded(window)
        }
        model.onHoverPanel = { [weak self] hovering in
            guard let self else { return }
            isOverPanel = hovering
            if hovering { hideWork?.cancel() } else { scheduleHide() }
        }
    }

    var isVisible: Bool { panel.isVisible }

    /// Whether a presentation is still scheduled. Only for the self-test, which
    /// cannot let the timer fire — `SelfTest.run` exits before the run loop turns
    /// — but can check that leaving the tile cancelled it.
    var hasPendingShowForTesting: Bool {
        guard let showWork else { return false }
        return !showWork.isCancelled
    }

    // MARK: - Hover

    /// - Parameter timings: the hover timings, read fresh so Settings changes
    ///   apply at once. The delay before appearing is the same one a thumbnail
    ///   uses, so passing the pointer along the strip doesn't flash a panel for
    ///   every stack crossed.
    func hover(bundleID: String, name: String, windows: [WindowInfo],
               anchor: CGRect, entering: Bool, timings: HoverTimings) {
        guard entering else {
            // Sliding from one tile to the next, SwiftUI delivers the new tile's
            // enter *before* the old tile's exit — so a stale exit must not
            // cancel work just scheduled for somewhere else. `current` has
            // already moved on in that case and this returns, which is right.
            Trace.debug(.preview,
                        "stack exit \(bundleID) current=\(current ?? "-") visible=\(panel.isVisible)")
            guard current == bundleID else { return }
            current = nil

            // Always drop the pending show. This is the line whose absence made
            // the panel appear after the pointer had left: the guard above could
            // not match, so nothing ever cancelled it.
            showWork?.cancel()
            showWork = nil

            // Only a panel that is actually up gets the grace period, which
            // exists so the pointer can travel from the tile onto the list.
            // Nothing on screen has nothing to travel to.
            if panel.isVisible { scheduleHide() } else { hide() }
            return
        }

        warmWindow = timings.warmWindow
        hideWork?.cancel()
        showWork?.cancel()

        // Already showing this stack — don't restart it, or moving the pointer
        // within the tile would rebuild the list under the cursor.
        if current == bundleID, panel.isVisible { return }
        current = bundleID

        // Already scanning the strip, so the wait has already been earned
        // somewhere else on the bar — show at once. Without this the row was
        // instant tile after tile and then stalled at a stacked app, which reads
        // as the stack being broken rather than as a deliberate delay.
        let warm = StripWarmth.shared.isWarm
        Trace.debug(.preview,
                    "stack enter \(bundleID) windows=\(windows.count) warm=\(warm) "
                    + "delay=\(warm ? 0 : timings.thumbnailDelay)")
        if warm {
            present(bundleID: bundleID, name: name, windows: windows, anchor: anchor)
            return
        }

        let work = DispatchWorkItem { [weak self] in
            self?.present(bundleID: bundleID, name: name, windows: windows, anchor: anchor)
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timings.thumbnailDelay, execute: work)
    }

    private func present(bundleID: String, name: String,
                         windows: [WindowInfo], anchor: CGRect) {
        StripWarmth.shared.hold("appStack")
        model.bundleID = bundleID
        model.appName = name
        model.windows = windows
        model.refreshImages()

        let count = max(windows.count, 1)
        let content = CGFloat(count) * Self.tileWidth
            + CGFloat(count - 1) * Self.tileSpacing
            + Self.plateInset * 2
        let screenLimit = (NSScreen.main?.visibleFrame.width ?? Self.maxWidth) - 40
        let width = min(content, Self.maxWidth, screenLimit)
        let height = Self.tileHeight + AppStackModel.headerHeight + Self.plateInset * 2
        panel.setContentSize(NSSize(width: width, height: height))

        // Centred over the tile, then held inside the screen. The strip is
        // leading-aligned and a stack near either edge would otherwise put half
        // the panel off-screen.
        var origin = NSPoint(x: anchor.midX - width / 2, y: anchor.maxY + 6)
        if let screen = NSScreen.main {
            origin.x = min(max(screen.visibleFrame.minX + 8, origin.x),
                           screen.visibleFrame.maxX - width - 8)
            origin.y = min(origin.y, screen.visibleFrame.maxY - height - 8)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        watchForDismissal()
    }

    /// Captures a window the panel is showing that has no image yet — typically
    /// one never visited this session.
    ///
    /// Bounded by the panel being a deliberate act: it only appears after the
    /// hover delay, so a pointer merely crossing the strip issues nothing. That
    /// is the same reasoning the hover thumbnail's 90ms settle relies on — a
    /// discarded capture still ran, so the cost has to be avoided rather than
    /// thrown away.
    private func captureIfNeeded(_ window: WindowInfo) {
        guard model.images[window.id] == nil,
              !pendingCaptures.contains(window.id) else { return }
        pendingCaptures.insert(window.id)

        Task { [weak self] in
            guard let self else { return }
            let image = await PreviewService.shared.image(
                for: window,
                maxSize: CGSize(width: Self.tileWidth, height: Self.tileHeight),
                maxAge: PreviewService.switcherMaxAge
            )
            pendingCaptures.remove(window.id)
            guard panel.isVisible, let image else { return }
            model.images[window.id] = image
        }
    }

    private func scheduleHide() {
        hideWork?.cancel()
        // Warmth is deliberately *not* released here. An earlier version did,
        // reasoning that the pointer has already left the tile — but the panel
        // is still on screen, and releasing hands the answer over to the user's
        // linger, which is zero for anyone who set it that way. The next tile
        // then waited the full delay with a panel still up in front of them.
        // Holding until the panel actually goes says the same thing without
        // depending on a setting: something is on screen, so the strip is warm.
        //
        // Long enough to cross the gap between the tile and the panel above it.
        // Without it the list vanishes the instant the pointer leaves the icon,
        // which makes the rows unreachable.
        let work = DispatchWorkItem { [weak self] in
            guard let self, !isOverPanel else { return }
            hide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func hide() {
        // The linger is only earned by a panel that was actually up. Crossing a
        // stacked icon without pausing comes through here too, and granting it
        // warmth would let a pointer merely sweeping the bar make the next tile
        // instant — the wait this exists to impose.
        StripWarmth.shared.release("appStack", staying: panel.isVisible ? warmWindow : 0)
        showWork?.cancel()
        showWork = nil
        hideWork?.cancel()
        hideWork = nil
        stopWatching()
        isOverPanel = false
        current = nil
        pendingCaptures.removeAll()
        model.bundleID = nil
        panel.orderOut(nil)
    }

    private func watchForDismissal() {
        stopWatching()
        if let m = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in self?.hide() } {
            dismissMonitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { self?.hide() }   // Escape
            return event
        } {
            dismissMonitors.append(m)
        }
    }

    private func stopWatching() {
        for monitor in dismissMonitors { NSEvent.removeMonitor(monitor) }
        dismissMonitors.removeAll()
    }
}

@MainActor
@Observable
final class AppStackModel {

    static let headerHeight: CGFloat = 22

    var bundleID: String?
    var appName: String = ""
    var windows: [WindowInfo] = []
    var images: [CGWindowID: NSImage] = [:]

    @ObservationIgnored var onSelect: ((WindowInfo) -> Void)?
    @ObservationIgnored var onHoverPanel: ((Bool) -> Void)?
    /// Asked to capture a window with no image yet.
    @ObservationIgnored var onNeedsImage: ((WindowInfo) -> Void)?

    /// Thumbnails already captured, at the *switcher's* tolerance rather than
    /// hover's.
    ///
    /// A stack's windows are mostly not the one you were just in, so demanding
    /// an image under three seconds old — what a hover thumbnail insists on —
    /// would mean no images at all for every row but one. Ten minutes is what
    /// the switcher accepts for exactly this situation, and captures are taken
    /// when a window loses focus, so they are as fresh as the content is final.
    func refreshImages() {
        var found: [CGWindowID: NSImage] = [:]
        for window in windows {
            if let image = PreviewService.shared.cachedImage(
                for: window.id, maxAge: PreviewService.switcherMaxAge
            ) {
                found[window.id] = image
            }
        }
        images = found
    }
}

private struct AppStackContent: View {
    @Bindable var model: AppStackModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(model.appName) — \(model.windows.count) windows")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(height: AppStackModel.headerHeight, alignment: .leading)

            // One row, scrolling sideways when it overflows.
            //
            // Deliberately not wrapping to a second row: a second row pushes the
            // first one upward as the panel grows, so the tile being reached for
            // moves while it is being reached for. Scrolling leaves every tile
            // where it was.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppStackPanel.tileSpacing) {
                    ForEach(model.windows) { window in
                        AppStackTileView(window: window, image: model.images[window.id]) {
                            model.onSelect?(window)
                        }
                        .onAppear { 
                            if model.images[window.id] == nil { model.onNeedsImage?(window) }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The switcher's ground, for the same reason it has one: a definite dark
        // backing rather than whatever is behind the panel, so thumbnails read
        // consistently instead of taking their contrast from the desktop.
        .background {
            ZStack {
                VisualEffectBackground(material: .hudWindow)
                Color.black.opacity(0.34)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        )
        .onHover { model.onHoverPanel?($0) }
    }
}

/// One window: its thumbnail, with the title beneath.
///
/// The title is under *every* tile rather than only the hovered one, so the
/// whole set can be read without sweeping the pointer along it.
private struct AppStackTileView: View {
    let window: WindowInfo
    let image: NSImage?
    let onSelect: () -> Void

    @State private var isHovering = false

    private var thumbWidth: CGFloat { AppStackPanel.tileWidth - 22 }
    private var thumbHeight: CGFloat { AppStackPanel.tileHeight - 46 }

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(0.06))

                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: thumbWidth, height: thumbHeight)
                            .clipped()
                    } else if let icon = window.icon {
                        // No capture yet, or Screen Recording refused. The icon
                        // stands in rather than the panel refusing to open.
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 32, height: 32)
                    }
                }
                .frame(width: thumbWidth, height: thumbHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text(window.displayTitle.truncated(to: 30))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(isHovering ? 1 : 0.72))
                    .lineLimit(1)
                    // Middle, not tail: two Chrome windows on the same site share
                    // a prefix, so the tail is what tells them apart.
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity)
            }
            .padding(7)
            .frame(width: AppStackPanel.tileWidth, height: AppStackPanel.tileHeight)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.white.opacity(isHovering ? 0.16 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(.white.opacity(isHovering ? 0.9 : 0), lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
