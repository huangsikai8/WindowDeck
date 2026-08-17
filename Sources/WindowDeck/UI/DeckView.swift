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

    @State private var dragging: String?
    /// Which pill the current drag started in, so a drop elsewhere can move the
    /// window between groups rather than merely reorder it.
    @State private var draggingFromGroup: UUID?
    /// Sections, not groups, decide whether a drop is a reorder or a move: two
    /// different sections can both have no group — the unfiled capsule and All's
    /// leading launchers — and comparing group ids alone would call that a
    /// reorder.
    @State private var draggingFromSection: String?

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

            // A ZStack rather than putting the entries straight in the HStack:
            // during the transition both the outgoing and incoming rows exist at
            // once, and in an HStack they would sit side by side and shove the
            // layout around. Stacked, they occupy the same cell and cross over
            // in place. The body's rounded clip keeps the travel inside the bar.
            ZStack(alignment: .leading) {
                // Pinned launchers are part of the row now, not a section of
                // their own — which is what stops them holding a fixed width
                // while the windows compress around them.
                pills(layout)
                    // Identity is the group, so switching replaces the row and
                    // gives the transition something to animate between.
                    .id(store.activeGroupID)
                    .transition(slide)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DeckMetrics.padding)
        .animation(store.animateGroupChanges && store.animateThisChange
                   ? .easeOut(duration: 0.22) : nil,
                   value: store.activeGroupID)
    }

    /// Leaves the way you were travelling and arrives from the opposite side, so
    /// the motion says which direction you moved through the list.
    private var slide: AnyTransition {
        let forward = store.switchedForward
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    /// Pill view: the same slots, drawn inside one capsule per group.
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            if layout.slots.isEmpty {
                Text(store.activeGroup.isAll
                     ? "No open windows"
                     : "Nothing in \(store.activeGroup.name) yet — right-click a window in All to add it")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
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
        let firstUngrouped = slots.first { $0.item.isUngrouped }?.id
        return HStack(spacing: spacing) {
            ForEach(slots) { slot in
                // Flat view is a single section, so its internal separators live
                // here: the off-group ghost, and the start of the unfiled run.
                if slot.item.isGhost {
                    Divider().frame(height: 22)
                }
                // Only before the *first* unfiled tile — there is at most one
                // ghost, but many unfiled windows, and a divider before each
                // would fence off every single one.
                if slot.id == firstUngrouped {
                    Divider().frame(height: 22)
                }
                draggableSlot(slot, section: section)
            }
        }
        .padding(.horizontal, section.isPill ? DeckLayout.pillInset : 0)
        .frame(height: DeckMetrics.tileHeight + 6)
        .background(pillBackground(section))
    }

    @ViewBuilder
    private func pillBackground(_ section: DeckSection) -> some View {
        if let color = section.color {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(color.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(color.opacity(0.38), lineWidth: 1)
                )
        } else {
            Color.clear
        }
    }

    /// One drag implementation for both views. `groupID` is the pill the slot is
    /// drawn in, so a drop can tell a reorder from a move between groups.
    @ViewBuilder
    private func draggableSlot(_ slot: DeckLayout.Slot, section: DeckSection) -> some View {
        slotView(slot, sectionGroupID: section.groupID)
            .onDrag {
                dragging = slot.item.orderKey
                draggingFromSection = section.id
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
                    targetSectionID: section.id,
                    sourceSectionID: draggingFromSection,
                    targetGroupID: section.groupID,
                    sourceGroupID: draggingFromGroup,
                    dragging: $dragging,
                    move: { store.moveItem($0, before: $1, in: section.groupID) },
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
            draggingFromSection = nil
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

    private func firstUngroupedSlotID(_ layout: DeckLayout.Result) -> String? {
        layout.slots.first { $0.item.isUngrouped }?.id
    }


    @ViewBuilder
    private func slotView(_ slot: DeckLayout.Slot, sectionGroupID: UUID?) -> some View {
        switch slot.item {
        case .window(let window), .ghost(let window), .ungrouped(let window):
            EntryTile(
                window: window,
                width: slot.width,
                showsTitle: slot.showsTitle,
                iconSize: slot.iconSize,
                groups: store.assignableGroups,
                memberships: store.groupsContaining(window.id),
                memberColors: store.colors(containing: window.id),
                isDragging: dragging == slot.item.orderKey,
                isFocused: store.focusedWindowID == window.id,
                isGhost: slot.item.isGhost,
                isUngrouped: slot.item.isUngrouped,
                focusTint: store.focusTint,
                onActivate: { onActivate(window) },
                onToggleGroup: { store.toggle(window.id, in: $0) },
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
                pinTargets: store.pinTargets(for: window.id),
                groupWithTargets: store.groupWithTargets(for: window.id, in: sectionGroupID),
                onGroupWith: { store.combine($0, into: window.id, in: sectionGroupID) }
            )

        case .pinned(let app):
            PinnedTile(
                app: app,
                width: slot.width,
                iconSize: slot.iconSize,
                isDragging: dragging == slot.item.orderKey,
                isRunning: store.runningApps.all.contains(app.bundleID),
                onOpen: { AppLauncher.open(app) },
                onTogglePin: { store.togglePin(app.bundleID, in: $0) },
                isPinnedIn: { store.isPinned(app.bundleID, in: $0) },
                pinTargets: store.pinTargets(forApp: app.bundleID),
                onUnpin: { store.unpin(app.bundleID) }
            )

        case .running(let app, let closedWindowID):
            PinnedTile(
                app: app,
                width: slot.width,
                iconSize: slot.iconSize,
                isDragging: dragging == slot.item.orderKey,
                isPinned: false,
                // Membership survives the window, so the dots do too.
                memberColors: closedWindowID.map { store.colors(containing: $0) } ?? [],
                // Reaching this case at all means the app is running.
                isRunning: true,
                onOpen: { AppLauncher.open(app) },
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
                onActivate: { onActivateAll(members) },
                onSeparate: { store.dissolveCluster(cluster.id) },
                onRename: { onRenameCluster(cluster) },
                onRemove: { store.removeFromCluster($0.id) },
                onHover: { hovering, frame in
                    // The first member stands in for the cluster on hover.
                    if let first = members.first { onHover(first, hovering, frame) }
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
            pillCount: sections.filter(\.isPill).count
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
    // should not be mostly padding. Width is deliberately untouched, so the same
    // number of windows still fit before the layout starts tightening.
    static let tileHeight: CGFloat = 44
    static let pinnedTileWidth: CGFloat = 40
    static let tileSpacing: CGFloat = 6
    static let selectorWidth: CGFloat = 108
    /// Status dots — group membership on a window tile, running state on a
    /// launcher. Shared so the two kinds line up along the bottom of the row.
    static let statusDotSize: CGFloat = 4
    static let statusDotInset: CGFloat = 1.5
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
