import AppKit
import SwiftUI

/// One window in the strip: app icon, optional truncated title, click to raise.
///
/// Width and whether the title shows are decided by `DeckLayout`, not here — the
/// whole row has to be sized together for it to fit without scrolling.
struct EntryTile: View {
    let window: WindowInfo
    let width: CGFloat
    let showsTitle: Bool
    let iconSize: CGFloat
    let groups: [DeckGroup]
    let memberships: Set<UUID>
    /// Colours of the groups this window belongs to, in group order.
    let memberColors: [Color]
    let isDragging: Bool

    /// This window is frontmost — the one you're actually in.
    let isFocused: Bool
    /// Focused but not a member of the group on show.
    let isGhost: Bool
    /// Belongs to no group at all — shown in All after the separator.
    let isUngrouped: Bool
    /// The active group's colour, used to fill the focused tile.
    let focusTint: Color
    let onActivate: () -> Void
    let onToggleGroup: (UUID) -> Void
    let onClose: () -> Void
    /// Reports hover state plus the tile's frame, which the preview panel
    /// anchors to.
    let onHover: (Bool, CGRect) -> Void
    /// Toggles a pin for this window's application. Nil means All.
    var onPin: ((UUID?) -> Void)?
    /// Whether it is currently pinned there, for the tick.
    var isPinnedIn: ((UUID?) -> Bool)?
    /// Groups offered in the pin submenu: the ones this window belongs to, plus
    /// whichever group is on screen. In All the first is the only useful list —
    /// there is no "current group" to pin to there.
    var pinTargets: [DeckGroup] = []
    /// What this window can be merged with, and the action that does it.
    var groupWithTargets: [AppStore.GroupWithTarget] = []
    var onGroupWith: ((CGWindowID) -> Void)?
    /// How many windows of this application are on show here, or nil when there
    /// is nothing worth stacking. A plain count rather than a list of windows:
    /// building a per-tile menu model on every redraw was once measured at 46%
    /// of this app's CPU, and the stack menu needs only the number.
    var stackableCount: Int?
    var onStack: (() -> Void)?

    @State private var isHovering = false
    @State private var frame: CGRect = .zero

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: 6) {
                if let icon = window.icon {
                    Image(nsImage: icon)
                        // Every window icon draws at full strength. Holding the
                        // unfocused ones slightly back made the row look
                        // unevenly rendered, and it competed with the one thing
                        // that should mean "not here": a launcher whose app
                        // isn't open. Focus is carried by the tile's fill, and
                        // a minimized window by its greyed title.
                        .resizable()
                        .frame(width: iconSize, height: iconSize)
                }

                if showsTitle {
                    Text(window.displayTitle)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(window.isMinimized ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, showsTitle ? 7 : 0)
            .frame(width: width, height: DeckMetrics.tileHeight,
                   alignment: showsTitle ? .leading : .center)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tileFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        (isGhost || isFocused) ? markTint.opacity(0.8) : .clear,
                        lineWidth: isGhost ? 1.5 : 1
                    )
            )
            .overlay(alignment: .topTrailing) {
                if isGhost {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 7, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 11, height: 11)
                        .background(Circle().fill(Self.offGroupTint))
                        .offset(x: 3, y: -3)
                }
            }
            // Which groups this window belongs to, readable at a glance from
            // inside All without opening anything.
            .overlay(alignment: .bottom) {
                if !memberColors.isEmpty {
                    HStack(spacing: 2.5) {
                        ForEach(Array(memberColors.enumerated()), id: \.offset) { _, color in
                            Circle()
                                .fill(color)
                                .frame(width: DeckMetrics.statusDotSize,
                                       height: DeckMetrics.statusDotSize)
                        }
                    }
                    .padding(.bottom, DeckMetrics.statusDotInset)
                }
            }
            .background(frameReader)
        }
        .buttonStyle(.plain)
        .opacity(isDragging ? 0.35 : 1)
        .onHover { hovering in
            isHovering = hovering
            onHover(hovering, frame)
        }
        // No .help() here on purpose: its ~1.5s system delay is exactly the
        // problem. The title chip shown from HoverController names the window
        // instantly instead.
        .contextMenu { contextMenu }
    }

    /// A checkmark reads better than separate add and remove commands: one
    /// stable menu whose state you can see at a glance, matching how group
    /// membership is already presented.
    @ViewBuilder
    private func pinItem(_ name: String, groupID: UUID?,
                         onPin: @escaping (UUID?) -> Void) -> some View {
        Button {
            onPin(groupID)
        } label: {
            Label(name, systemImage: isPinnedIn?(groupID) == true ? "checkmark" : "")
        }
    }

    /// Red, deliberately outside the group palette. Tinting the off-group window
    /// with the active group's colour said "belongs here", which is the opposite
    /// of what it means.
    private static let offGroupTint = Color(red: 0.90, green: 0.30, blue: 0.30)

    private var markTint: Color {
        isGhost ? Self.offGroupTint : focusTint
    }

    /// The focused tile is filled solidly enough to spot instantly in a row of
    /// thirty near-identical icons — that is the entire point of it.
    private var tileFill: some ShapeStyle {
        if isGhost {
            return AnyShapeStyle(Self.offGroupTint.opacity(isHovering ? 0.46 : 0.34))
        }
        if isFocused {
            return AnyShapeStyle(focusTint.opacity(isHovering ? 0.62 : 0.50))
        }
        // Ungrouped windows sit at full brightness — being unfiled isn't a
        // fault, unlike the off-group warning — but on a slightly lighter bed,
        // so adjacent ones read as one band rather than needing a container
        // behind a slice of the row.
        if isUngrouped {
            return AnyShapeStyle(.primary.opacity(isHovering ? 0.20 : 0.13))
        }
        return AnyShapeStyle(.primary.opacity(isHovering ? 0.14 : 0.06))
    }

    private var frameReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { frame = geo.frame(in: .global) }
                .onChange(of: geo.frame(in: .global)) { _, new in frame = new }
        }
    }

    /// The primary way windows get copied from "All" into another arrangement.
    @ViewBuilder
    private var contextMenu: some View {
        if isGhost {
            Text("Not in this group")
            Divider()
        }
        if groups.isEmpty {
            Text("No groups yet")
        } else {
            ForEach(groups) { group in
                Button {
                    onToggleGroup(group.id)
                } label: {
                    // A checkmark reads better than "Add to"/"Remove from": one
                    // stable menu whose state you can see at a glance.
                    Label(group.name, systemImage: memberships.contains(group.id) ? "checkmark" : "")
                }
            }
        }

        // Below the rule, with pinning: these are actions on the window, while
        // the checkmarks above are its membership. Sitting flush against that
        // list made this read as one more group to tick.
        Divider()

        // Merging windows behind one icon. A menu rather than a drag gesture:
        // dragging reorders the row live, so a dwell-to-combine target moved out
        // from under the pointer and the gesture could not be completed.
        if let onGroupWith, !groupWithTargets.isEmpty {
            Menu("Group with") {
                ForEach(groupWithTargets) { target in
                    Button {
                        onGroupWith(target.windowID)
                    } label: {
                        // Icon and app name: a bare "Downloads" or "PR.md" says
                        // little without knowing which application it belongs to.
                        if let icon = target.icon {
                            Image(nsImage: icon)
                        }
                        // Said in words rather than left to the dimming: a greyed
                        // row otherwise reads as "unavailable" rather than "this
                        // is where you are".
                        Text(target.isCluster
                             ? "Add to \(target.name) (\(target.detail))"
                             : "\(target.detail) — \(target.name)"
                             + (target.isSelf ? "   (this window)" : ""))
                    }
                    // Shown, not selectable: you can see where you are in the
                    // order without being able to group a window with itself.
                    .disabled(target.isSelf)
                }
            }
        }

        // Collapsing this app's windows behind one icon. Distinct from "Group
        // with" directly above it, which merges *chosen* windows of any
        // applications and opens all of them — this one names an application and
        // opens a single window. Saying the app and the count in the label is
        // what keeps the two apart at the moment of choosing.
        if let onStack, let stackableCount {
            Button("Stack \(window.appName)'s \(stackableCount) Windows", action: onStack)
        }

        // Pinning from here is the natural place to reach for it: you are already
        // right-clicking the app you want a launcher for.
        if let onPin {
            Menu("Pin \(window.appName) to") {
                pinItem("All", groupID: nil, onPin: onPin)
                if !pinTargets.isEmpty { Divider() }
                ForEach(pinTargets) { group in
                    pinItem(group.name, groupID: group.id, onPin: onPin)
                }
            }
            Divider()
        }

        Button("Close Window", action: onClose)
    }
}

/// Reordering, and moving items between capsules.
///
/// It used to arm a *combine* as well, when a drag dwelled on one tile for
/// `combineDelay`. That could never work: passing over a tile reorders the row
/// immediately, so the tile being dwelled on slid away and the timer was
/// repeatedly cancelled. Merging is a menu action now, and this handles movement
/// only.
struct EntryDropDelegate: DropDelegate {
    /// Ordering key — windows and pins share one namespace.
    let target: String
    /// Only windows can be combined into a cluster; a pin has none.
    let targetWindowID: CGWindowID?
    /// Which section this target is in, and which the drag began in. Sections
    /// rather than groups decide reorder-versus-move: two sections can both have
    /// no group — unfiled windows and All's leading launchers — and comparing
    /// group ids alone would mistake a move between them for a reorder.
    var targetSectionID: String?
    var sourceSectionID: String?
    var targetGroupID: UUID?
    var sourceGroupID: UUID?
    @Binding var dragging: String?
    let move: (String, String) -> Void
    /// Key, source group, target group. Either group may be nil: dropping into
    /// the unfiled capsule removes the source membership without adding one.
    var moveBetweenGroups: ((String, UUID?, UUID?) -> Void)?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        // Reordering live as the drag passes only makes sense within one pill.
        // Across pills the row's order comes from the grouping, so a live
        // reorder would fight the layout and snap back.
        guard targetSectionID == sourceSectionID else { return }
        move(dragging, target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        // A drop in a different pill moves the window between groups rather than
        // reordering: it joins the pill it was dropped in and leaves the one it
        // came from, the way dragging a file between folders behaves.
        if let dragging, targetSectionID != sourceSectionID {
            moveBetweenGroups?(dragging, sourceGroupID, targetGroupID)
            self.dragging = nil
            return true
        }

        dragging = nil
        return true
    }
}
