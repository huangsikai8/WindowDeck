import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The whole bar, folded groups included, on a row above the strip.
///
/// Opened by pressing the overflow cluster. Deliberately not an expansion of the
/// strip itself: opening one in place would push every other capsule sideways,
/// so the tile you were reaching for moves as you reach for it. A separate row
/// leaves the strip exactly where it was.
///
/// One row per group rather than a literal copy of the strip. The strip is one
/// line because it must never scroll; this panel has no such constraint, and a
/// group per line is far easier to read than the same content squeezed edge to
/// edge.
@MainActor
final class AllGroupsPanel {

    private let panel: NSPanel
    private let hosting: NSHostingView<AllGroupsContent>
    let model = AllGroupsModel()

    /// Raise this window and close.
    var onSelect: ((WindowInfo) -> Void)?
    /// Bring a folded group back into the strip.
    var onExpand: ((UUID) -> Void)?

    private var dismissMonitors: [Any] = []

    init() {
        hosting = NSHostingView(rootView: AllGroupsContent(model: model))
        hosting.sizingOptions = []

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
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
        model.onExpand = { [weak self] groupID in
            self?.hide()
            self?.onExpand?(groupID)
        }
    }

    var isVisible: Bool { panel.isVisible }

    /// Rises from `anchor`, the strip's own frame.
    func show(anchor: NSRect) {
        let rows = max(model.groups.count, 1)
        let width = min(max(420, model.widestRowWidth), (NSScreen.main?.frame.width ?? 1280) - 80)
        let height = CGFloat(rows) * AllGroupsModel.rowHeight + 20
        panel.setContentSize(NSSize(width: width, height: height))

        var origin = NSPoint(x: anchor.maxX - width, y: anchor.maxY + 8)
        if let screen = NSScreen.main {
            origin.x = max(screen.visibleFrame.minX + 8, origin.x)
            origin.y = min(origin.y, screen.visibleFrame.maxY - height - 8)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        watchForDismissal()
    }

    func hide() {
        stopWatching()
        panel.orderOut(nil)
    }

    /// Closes on a click anywhere else, the way a menu does. The panel ignores
    /// nothing itself, so clicks *inside* it are handled before this sees them.
    private func watchForDismissal() {
        stopWatching()
        let handler: (NSEvent) -> Void = { [weak self] _ in self?.hide() }
        if let m = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
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
final class AllGroupsModel {
    struct Row: Identifiable {
        let id: UUID
        let name: String
        let color: Color
        let isCollapsed: Bool
        let windows: [WindowInfo]
    }

    static let rowHeight: CGFloat = 40

    var groups: [Row] = []
    @ObservationIgnored var onSelect: ((WindowInfo) -> Void)?
    @ObservationIgnored var onExpand: ((UUID) -> Void)?
    @ObservationIgnored var onClose: ((WindowInfo) -> Void)?
    /// The panel builds its own rows so a reorder or a membership change made
    /// from here is visible immediately. Without it the list is a snapshot taken
    /// when the panel opened, and a dragged icon springs back to where it was.
    @ObservationIgnored weak var store: AppStore?

    func reload() {
        guard let store else { return }
        // Every window, not `visibleWindows` — that intersects with the *active
        // group's* membership, and the panel can outlive the group it was opened
        // in (⌘↓ is a Carbon hotkey, so the dismissal monitor never sees it).
        // Each row filters by its own `memberIDs` a line below; the active group
        // has no business in that intersection.
        groups = store.groups.map { group in
            Row(id: group.id,
                name: group.name,
                color: group.displayColor,
                isCollapsed: group.isCollapsed,
                // Through the store, so Main's implicit membership — everything
                // no other capsule claims — is answered the same way here as on
                // the strip rather than being worked out a second time.
                windows: Self.ordered(store.windows(in: group), by: store.order(in: group.id)))
        }
    }

    /// The group's own arrangement, so the panel and the strip agree and a drag
    /// here means the same thing as a drag there.
    ///
    /// An unranked window is placed beside its own application's, exactly as
    /// `AppStore.applyManualOrder` does it — a newly opened window has no key in
    /// the arrangement, and trailing every one of them behind the ranked tiles
    /// is what scattered an app's windows down the list. A folded group shows
    /// the same list, so it needs the same rule or it shows the same mess.
    ///
    /// Windows only, so the app is the window's own. The strip's version has to
    /// answer for clusters, stacks and launchers as well, which is why the
    /// identity lives on `DeckItem` there rather than being shared with this.
    static func ordered(_ windows: [WindowInfo], by order: [String]) -> [WindowInfo] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) },
                              uniquingKeysWith: { first, _ in first })

        // The index tiebreak guards a group with no manual arrangement yet,
        // where every window ranks equally. `sorted(by:)` is not documented as
        // stable — though the current implementation is, measured at both 3 and
        // 40 elements, so removing the tiebreak does not currently change
        // anything observable. It stays because the contract, not the
        // implementation, is what a future toolchain will honour.
        var placed = windows.enumerated()
            .filter { rank["w\($0.element.id)"] != nil }
            .sorted { a, b in
                let ra = rank["w\(a.element.id)"] ?? Int.max
                let rb = rank["w\(b.element.id)"] ?? Int.max
                return ra == rb ? a.offset < b.offset : ra < rb
            }
            .map(\.element)

        func sameApp(_ a: WindowInfo, _ b: WindowInfo) -> Bool {
            if let one = a.bundleID, let other = b.bundleID { return one == other }
            return a.appName == b.appName
        }

        for window in windows where rank["w\(window.id)"] == nil {
            if let anchor = placed.lastIndex(where: { sameApp($0, window) }) {
                placed.insert(window, at: anchor + 1)
            } else {
                placed.append(window)
            }
        }
        return placed
    }

    /// Enough for the busiest row, so nothing is clipped.
    var widestRowWidth: CGFloat {
        let labels = groups.map { row -> CGFloat in
            let name = (row.name as NSString)
                .size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width
            return 190 + name + CGFloat(row.windows.count) * 34
        }
        return (labels.max() ?? 420) + 40
    }
}

private struct AllGroupsContent: View {
    @Bindable var model: AllGroupsModel

    /// The window being dragged, and the row it started in. Membership is not
    /// changed from here by dragging — a drop onto a different group is refused,
    /// so the only thing a drag can do is reorder within the row it began in.
    /// Moving a window between groups is what the right-click checkmarks are
    /// for, where it is deliberate rather than a slip of the pointer.
    @State private var dragging: CGWindowID?
    @State private var draggingFrom: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.groups) { row in
                HStack(spacing: 8) {
                    Circle().fill(row.color).frame(width: 8, height: 8)
                    Text(row.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .frame(width: 110, alignment: .leading)

                    // The same count the drop-up shows, in the same right-aligned
                    // pill, so the two ways of listing groups agree.
                    Text("\(row.windows.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 18)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.primary.opacity(0.08)))

                    ForEach(row.windows) { window in
                        icon(window, in: row)
                    }

                    Spacer(minLength: 8)

                    // Only a folded group offers this; an expanded one is already
                    // in the strip.
                    if row.isCollapsed {
                        Button("Show in bar") { model.onExpand?(row.id) }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: AllGroupsModel.rowHeight)
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VisualEffectBackground(material: .menu))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.primary.opacity(0.10), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func icon(_ window: WindowInfo, in row: AllGroupsModel.Row) -> some View {
        Button {
            model.onSelect?(window)
        } label: {
            if let image = window.icon {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: 26, height: 26)
            }
        }
        .buttonStyle(.plain)
        .help(window.displayTitle)
        .opacity(dragging == window.id ? 0.35 : 1)
        .contextMenu { menu(for: window, in: row) }
        .onDrag {
            dragging = window.id
            draggingFrom = row.id
            armDragSafety()
            // Unused — the reorder is driven by `dragging` — but a drag will not
            // begin without a provider.
            return NSItemProvider(object: "w\(window.id)" as NSString)
        }
        .onDrop(of: [.text], isTargeted: nil) { _ in
            defer { dragging = nil; draggingFrom = nil }
            guard let source = dragging, source != window.id,
                  // Refused across groups on purpose: a drag here reorders, it
                  // never refiles.
                  draggingFrom == row.id else { return false }
            model.store?.moveItem("w\(source)", before: "w\(window.id)", in: row.id)
            model.reload()
            return true
        }
    }

    /// A drag released over nothing leaves no callback, so the faded icon would
    /// stay faded. Same shape as the strip's own safety net.
    private func armDragSafety() {
        var monitors: [Any] = []
        let finish = {
            dragging = nil
            draggingFrom = nil
            for monitor in monitors { NSEvent.removeMonitor(monitor) }
            monitors.removeAll()
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { _ in finish() } {
            monitors.append(m)
        }
        // Deferred by one runloop turn on purpose. A drop released *over the
        // panel* delivers mouse-up to this app, so a local monitor that cleared
        // the state immediately would win the race against `onDrop` and every
        // in-panel reorder would silently do nothing. The global monitor above
        // handles the ordinary abandoned drag; this one only has to catch a
        // release over the panel that landed on no icon.
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { event in
            DispatchQueue.main.async { finish() }
            return event
        } {
            monitors.append(m)
        }
    }

    @ViewBuilder
    private func menu(for window: WindowInfo, in row: AllGroupsModel.Row) -> some View {
        if let store = model.store {
            let home = store.group(of: window.id).id
            ForEach(store.groups) { group in
                Button {
                    store.add(window.id, to: group.id)
                    model.reload()
                } label: {
                    Label(group.name, systemImage: group.id == home ? "checkmark" : "")
                }
            }

            Divider()

            let targets = store.groupWithTargets(for: window.id, in: row.id)
            if !targets.isEmpty {
                Menu("Group with") {
                    ForEach(targets) { target in
                        Button {
                            store.combine(target.windowID, into: window.id, in: row.id)
                            model.reload()
                        } label: {
                            if let image = target.icon { Image(nsImage: image) }
                            Text(target.isCluster
                                 ? "Add to \(target.name) (\(target.detail))"
                                 : "\(target.detail) — \(target.name)"
                                 + (target.isSelf ? "   (this window)" : ""))
                        }
                        .disabled(target.isSelf)
                    }
                }
            }

            if let bundleID = window.bundleID {
                Menu("Pin \(window.appName) to") {
                    ForEach(store.groups) { group in
                        pinItem(group.name, bundleID: bundleID, groupID: group.id, store: store)
                    }
                }
                Divider()
            }

            Button("Close Window") {
                model.onClose?(window)
                model.reload()
            }
        }
    }

    private func pinItem(_ name: String, bundleID: String,
                         groupID: UUID?, store: AppStore) -> some View {
        Button {
            store.togglePin(bundleID, in: groupID)
            model.reload()
        } label: {
            Label(name, systemImage: store.isPinned(bundleID, in: groupID) ? "checkmark" : "")
        }
    }
}
