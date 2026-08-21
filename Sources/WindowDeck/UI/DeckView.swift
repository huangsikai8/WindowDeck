import SwiftUI
import UniformTypeIdentifiers

struct DeckView: View {
    @Bindable var store: AppStore
    let onActivate: (WindowInfo) -> Void
    let onClose: (WindowInfo) -> Void
    let onNewGroup: () -> Void
    let onEditGroups: () -> Void
    let onHover: (WindowInfo, Bool, CGRect) -> Void
    let onActivateAll: ([WindowInfo]) -> Void
    let onRenameCluster: (WindowCluster) -> Void
    /// Opens the panel showing every group, folded ones included.
    var onShowAllGroups: () -> Void = {}
    /// Hovering a stacked app. A separate channel from `onHover` on purpose:
    /// the preview panel escalates title → thumbnail → peek for a *single*
    /// window, so routing a stack through it would put two panels on screen.
    var onStackHover: (String, String, [WindowInfo], Bool, CGRect) -> Void = { _, _, _, _, _ in }

    @State private var dragging: String?
    /// Which capsule the current drag started in, so a drop elsewhere moves the
    /// window between groups rather than merely reordering it.
    @State private var draggingFromGroup: UUID?

    var body: some View {
        // Computed once and threaded through: the spacing it chooses has to be
        // the spacing actually rendered, or the width it reserved won't match
        // what the strip draws and the last entries clip.
        let layout = self.layout

        return Group {
            if store.isTrusted {
                content(layout)
            } else {
                permissionPrompt
            }
        }
        .frame(height: DeckMetrics.height)
        // The frosted material samples whatever is behind the strip, so a
        // wallpaper that is bright on one side and dark on the other drags the
        // bar's contrast with it and icons get lost. A solid layer on top of the
        // blur keeps the background even across the whole width, in both
        // appearances.
        .background {
            ZStack {
                VisualEffectBackground(material: .popover)
                Color(nsColor: .windowBackgroundColor).opacity(0.62)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DeckMetrics.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DeckMetrics.cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func content(_ layout: DeckLayout.Result) -> some View {
        HStack(spacing: layout.spacing) {
            GroupSelector(store: store, onNewGroup: onNewGroup, onEditGroups: onEditGroups)

            Divider().frame(height: 26)

            // Nothing animates here. The row used to slide when the group
            // changed, which is the one event that no longer exists — every
            // group is on screen at once. `layout()` also runs on every window
            // open and close, and animating those left the bar breathing.
            pills(layout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DeckMetrics.padding)
    }

    /// The strip: one capsule per group, Main first.
    ///
    /// Sizing is done on the flattened list so every tile in the row is measured
    /// together — a capsule must not get its own width budget, or the row stops
    /// fitting. The slots are then handed back out to their sections in order.
    ///
    /// Deliberately split into small functions with explicit return types. Written
    /// as one nested expression it type-checked for minutes without finishing,
    /// which reads exactly like a hung build.
    private func pills(_ layout: DeckLayout.Result) -> some View {
        HStack(spacing: layout.spacing) {
            ForEach(drawnSections(layout), id: \.section.id) { entry in
                if entry.section.dividerBefore {
                    Divider().frame(height: 22)
                }
                pill(entry.section, slots: entry.slots, spacing: layout.spacing)
            }
            overflowCluster(spacing: layout.spacing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            if layout.slots.isEmpty {
                Text("No open windows")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// Groups folded away, gathered at the right as coloured dots.
    ///
    /// Pressing anywhere on the cluster shows the whole bar above the strip. It
    /// is one control rather than a dot each: the point is to get several groups
    /// out of the way, not to open them one at a time.
    @ViewBuilder
    private func overflowCluster(spacing: CGFloat) -> some View {
        let collapsed = store.collapsedGroups
        let hiddenWindows = collapsed.reduce(0) { $0 + $1.count }
        if !collapsed.isEmpty {
            Divider().frame(height: 22)
            Button {
                onShowAllGroups()
            } label: {
                HStack(spacing: DeckLayout.collapsedGap) {
                    // Overlapping circles, one per folded group — count them for
                    // groups, read the number for windows. Each carries a ring in
                    // the bar's own colour so neighbours stay separable where they
                    // overlap.
                    HStack(spacing: -4) {
                        ForEach(collapsed) { group in
                            Circle()
                                .fill(group.color)
                                .frame(width: DeckLayout.collapsedDotSize,
                                       height: DeckLayout.collapsedDotSize)
                                .overlay(
                                    Circle().strokeBorder(
                                        Color(nsColor: .windowBackgroundColor), lineWidth: 1.5)
                                )
                        }
                    }

                    Text("\(hiddenWindows)")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        // Exactly as wide as its digits, so the number sits
                        // against the dots instead of floating in a reserved slot.
                        .frame(width: DeckLayout.collapsedCountWidth(hiddenWindows),
                               alignment: .trailing)
                }
                .padding(.horizontal, DeckLayout.collapsedPadding)
                .frame(height: DeckMetrics.tileHeight + 6)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(.primary.opacity(0.06))
                )
            }
            .buttonStyle(.plain)
            .help(collapsed.count == 1
                  ? "\(collapsed[0].name) is collapsed — show all groups"
                  : "\(collapsed.count) groups collapsed — show all groups")
        }
    }

    private struct SectionSlots: Identifiable {
        let section: DeckSection
        let slots: [DeckLayout.Slot]
        var id: String { section.id }
    }

    /// Hands the flat slot list back out to the sections that produced it.
    private func drawnSections(_ layout: DeckLayout.Result) -> [SectionSlots] {
        var remaining = layout.slots[...]
        var result: [SectionSlots] = []
        for section in store.sections {
            var take = Array(remaining.prefix(section.items.count))
            remaining = remaining.dropFirst(section.items.count)
            // Stamp the section onto each slot: the same window is drawn once per
            // group it belongs to, and those copies must not share an identity.
            for index in take.indices { take[index].sectionID = section.id }
            result.append(SectionSlots(section: section, slots: take))
        }
        return result
    }

    private func pill(_ section: DeckSection,
                      slots: [DeckLayout.Slot],
                      spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(slots) { slot in
                draggableSlot(slot, section: section)
            }
        }
        .padding(.horizontal, section.isPill ? DeckLayout.pillInset : 0)
        .frame(height: DeckMetrics.tileHeight + 6)
        .background(pillBackground(section))
        .contextMenu {
            if let groupID = section.groupID,
               let group = store.groups.first(where: { $0.id == groupID }) {
                if !group.isMain {
                    Button("Collapse \(group.name)") { store.setCollapsed(true, for: groupID) }
                }
                Button("Edit Groups…", action: onEditGroups)
                Button("New Group…", action: onNewGroup)
            }
        }
    }

    /// The capsule's own tint, and a brighter ring on the one being worked in.
    ///
    /// Which capsule that is comes from the focused window, so the ring says
    /// where the next window you open will land. Nothing else marks it: there is
    /// no selection to show, because there is nothing to select.
    @ViewBuilder
    private func pillBackground(_ section: DeckSection) -> some View {
        if let color = section.color {
            let isActive = section.groupID == store.activeGroupID
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(color.opacity(isActive ? 0.22 : 0.13))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(color.opacity(isActive ? 0.75 : 0.30),
                                      lineWidth: isActive ? 1.5 : 1)
                )
        } else {
            Color.clear
        }
    }

    /// One drag implementation for both views. `groupID` is the pill the slot is
    /// drawn in, so a drop can tell a reorder from a move between groups.
    @ViewBuilder
    private func draggableSlot(_ slot: DeckLayout.Slot, section: DeckSection) -> some View {
        slotView(slot, section: section)
            .onDrag {
                dragging = slot.item.orderKey
                draggingFromGroup = section.groupID
                armDragSafety()
                // The payload is unused — reordering is driven by the in-process
                // `dragging` state — but a provider is required for the drag to
                // start at all.
                return NSItemProvider(object: slot.item.orderKey as NSString)
            }
            .onDrop(
                of: [UTType.text],
                delegate: EntryDropDelegate(
                    target: slot.item.orderKey,
                    targetWindowID: slot.item.primaryWindowID,
                    targetGroupID: section.groupID,
                    sourceGroupID: draggingFromGroup,
                    dragging: $dragging,
                    move: { key, target in
                        guard let groupID = section.groupID else { return }
                        store.moveItem(key, before: target, in: groupID)
                    },
                    moveBetweenGroups: { store.moveItem($0, from: $1, to: $2) }
                )
            )
    }

    /// Clears the drag state if the drag never lands anywhere.
    ///
    /// A dragged tile is drawn at 35% to show it is in flight, and `dragging` is
    /// only reset by a drop. SwiftUI gives no callback for a drag that is
    /// abandoned — released over the desktop, or cancelled — so the tile stayed
    /// faded indefinitely and looked like a rendering glitch. Watching for the
    /// mouse coming up ends the session wherever it happens.
    private func armDragSafety() {
        var monitors: [Any] = []
        let finish = {
            dragging = nil
            draggingFromGroup = nil
            for monitor in monitors { NSEvent.removeMonitor(monitor) }
            monitors.removeAll()
        }
        // Global for the usual case — the pointer is over another application
        // while dragging — and local for a drag that stays over the strip.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { _ in finish() } {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { event in
            finish(); return event
        } {
            monitors.append(m)
        }
    }

    /// The colour of the capsule a slot is drawn in. Taken from the section
    /// rather than looked up per item, so a cluster and the windows beside it
    /// cannot disagree about which capsule they are in.
    private func sectionTint(_ section: DeckSection) -> Color {
        section.color ?? store.main.displayColor
    }

    @ViewBuilder
    private func slotView(_ slot: DeckLayout.Slot, section: DeckSection) -> some View {
        // The capsule the slot is drawn in, which is what every operation on it
        // acts on. Never "the current group": that distinction is the one this
        // file got wrong four times.
        let sectionGroupID = section.groupID
        switch slot.item {
        case .window(let window):
            EntryTile(
                window: window,
                width: slot.width,
                showsTitle: slot.showsTitle,
                iconSize: slot.iconSize,
                groups: store.assignableGroups,
                memberGroupID: store.group(of: window.id).id,
                isDragging: dragging == slot.item.orderKey,
                isFocused: store.focusedWindowID == window.id,
                tint: store.group(of: window.id).displayColor,
                onActivate: { onActivate(window) },
                // Filing into a capsule *moves* the window, so picking the one
                // it is already in would be a no-op — `add` handles that.
                onToggleGroup: { store.add(window.id, to: $0) },
                onClose: { onClose(window) },
                onHover: { hovering, frame in onHover(window, hovering, frame) },
                onPin: { groupID in
                    guard let bundleID = window.bundleID else { return }
                    store.togglePin(bundleID, in: groupID)
                },
                isPinnedIn: { groupID in
                    guard let bundleID = window.bundleID else { return false }
                    return store.isPinned(bundleID, in: groupID)
                },
                pinTargets: [store.pinTarget(for: window.id)],
                groupWithTargets: store.groupWithTargets(for: window.id, in: sectionGroupID),
                onGroupWith: { store.combine($0, into: window.id, in: sectionGroupID) },
                stackableCount: window.bundleID.flatMap {
                    store.stackableWindowCount(for: $0, in: sectionGroupID)
                },
                onStack: {
                    guard let bundleID = window.bundleID else { return }
                    store.stackApp(bundleID: bundleID, in: sectionGroupID)
                }
            )

        case .pinned(let app):
            PinnedTile(
                app: app,
                width: slot.width,
                iconSize: slot.iconSize,
                isDragging: dragging == slot.item.orderKey,
                isRunning: store.runningApps.all.contains(app.bundleID),
                tint: sectionTint(section),
                // Clicking a launcher inside a capsule makes that capsule active,
                // so the window it opens lands there by the ordinary placement
                // rule rather than by an exception to it.
                onOpen: {
                    section.groupID.map(store.noteWorkingIn)
                    AppLauncher.open(app)
                },
                onTogglePin: { store.togglePin(app.bundleID, in: $0) },
                isPinnedIn: { store.isPinned(app.bundleID, in: $0) },
                pinTargets: store.pinTargets(forApp: app.bundleID),
                onUnpin: { store.unpin(app.bundleID) }
            )

        case .running(let app, _, let instance):
            PinnedTile(
                app: app,
                width: slot.width,
                iconSize: slot.iconSize,
                isDragging: dragging == slot.item.orderKey,
                isPinned: false,
                // Reaching this case at all means the app is running.
                isRunning: true,
                tint: sectionTint(section),
                // The copy *this* process came from, so a second installation
                // reopens itself rather than its namesake.
                onOpen: {
                    section.groupID.map(store.noteWorkingIn)
                    AppLauncher.open(url: instance?.url ?? app.url)
                },
                onTogglePin: { store.togglePin(app.bundleID, in: $0) },
                isPinnedIn: { store.isPinned(app.bundleID, in: $0) },
                pinTargets: store.pinTargets(forApp: app.bundleID),
                // Right-clicking promotes it to a real pin, so an app you keep
                // reaching for stops depending on it happening to be running.
                onUnpin: { store.pin(app) }
            )

        case .cluster(let cluster, let members):
            ClusterTile(
                cluster: cluster,
                members: members,
                width: slot.width,
                iconSize: slot.iconSize,
                isDragging: dragging == slot.item.orderKey,
                tint: sectionTint(section),
                isFocused: members.contains { $0.id == store.focusedWindowID },
                onActivate: { onActivateAll(members) },
                onSeparate: { store.dissolveCluster(cluster.id) },
                onRename: { onRenameCluster(cluster) },
                onRemove: { store.removeFromCluster($0.id) },
                onHover: { hovering, frame in
                    // The first member stands in for the cluster on hover.
                    if let first = members.first { onHover(first, hovering, frame) }
                }
            )

        case .appStack(let bundleID, let members):
            // Recency order is resolved here rather than in the fold, so the
            // *row* keeps the leftmost member's position while the menu and the
            // hover list read most-recent-first.
            let byRecency = store.stackWindowsByRecency(members)
            AppStackTile(
                name: members.first?.appName ?? bundleID,
                icon: members.first?.icon,
                count: members.count,
                width: slot.width,
                iconSize: slot.iconSize,
                isDragging: dragging == slot.item.orderKey,
                isFocused: members.contains { $0.id == store.focusedWindowID },
                // Its own capsule's colour, like an entry tile's. Reading "the
                // active capsule's colour" instead would tint a stack in Work
                // with Main's colour whenever focus happened to sit elsewhere.
                tint: sectionTint(section),
                windows: byRecency,
                // One window, not all of them — the whole point of the feature.
                onActivate: { if let first = byRecency.first { onActivate(first) } },
                onActivateWindow: { onActivate($0) },
                onUnstack: { store.unstackApp(bundleID: bundleID, in: sectionGroupID) },
                onHover: { hovering, frame in
                    onStackHover(bundleID, members.first?.appName ?? bundleID,
                                 byRecency, hovering, frame)
                }
            )
        }
    }

    private var layout: DeckLayout.Result {
        // Always measured on the flattened list, so the whole row is sized in one
        // pass regardless of how it is bucketed. A capsule that budgeted its own
        // width would let the row grow past the strip's edge.
        let sections = store.sections
        return DeckLayout.compute(
            items: sections.flatMap(\.items),
            pinnedCount: 0,
            titlesEnabled: store.showTitles,
            maxWidth: DeckMetrics.maxWidth(),
            pillCount: sections.filter(\.isPill).count,
            collapsedCount: store.collapsedGroups.count,
            collapsedWindows: store.collapsedGroups.reduce(0) { $0 + $1.count },
            sectionCount: sections.count,
            dividerCount: sections.filter(\.dividerBefore).count
        )
    }

    private var permissionPrompt: some View {
        Button {
            Permissions.openSettingsPane()
        } label: {
            Label("Grant Accessibility access to WindowDeck…", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DeckMetrics.padding)
    }
}

enum DeckMetrics {
    static let height: CGFloat = 56
    static let cornerRadius: CGFloat = 16
    static let padding: CGFloat = 10
    // 44 inside a 56pt strip: the icon carries the information, so the bar
    // should not be mostly padding. Neither number may grow to make icons
    // bigger — the strip's height is screen the user does not get back, and the
    // tile's width is how many windows fit before the layout tightens. The way
    // the Dock gets a large icon is not a large tile, it is a tile that is
    // almost entirely icon, so growth comes out of this tile's own slack.
    static let tileHeight: CGFloat = 44
    static let pinnedTileWidth: CGFloat = 40
    static let tileSpacing: CGFloat = 6
    /// The groups button. Narrow because it no longer names a current group —
    /// there is nothing to switch, so it is a menu and not a selector.
    static let selectorWidth: CGFloat = 40
    /// Status dots — group membership on a window tile, running state on a
    /// launcher. Shared so the two kinds line up along the bottom of the row.
    static let statusDotSize: CGFloat = 4
    static let statusDotInset: CGFloat = 1.5
    /// Space kept clear at the bottom of a tile for the dot, so the icon can
    /// take everything above it.
    ///
    /// Centring the icon in the whole tile is what wasted the room: it split the
    /// slack evenly top and bottom and then the dot had to be drawn *over* the
    /// bottom half of it, so the icon could never grow into either. Reserving
    /// the dot's band explicitly gives the icon one contiguous space instead of
    /// two useless margins, which is the arrangement the Dock has — icon, then a
    /// thin strip with the indicator in it, and nothing else.
    static let dotClearance: CGFloat = 5
    static let dividerWidth: CGFloat = 1
    /// Gap between the strip and the screen edge.
    static let edgeInset: CGFloat = 8
    /// Breathing room so the strip never spans the full display.
    static let screenMargin: CGFloat = 40
    /// Width reserved for the "nothing here yet" hint.
    static let emptyHintWidth: CGFloat = 380

    static func maxWidth(screen: NSScreen? = NSScreen.main) -> CGFloat {
        guard let screen else { return 1200 }
        return screen.frame.width - screenMargin
    }
}
