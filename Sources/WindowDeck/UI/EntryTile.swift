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
    /// The one capsule this window is in. A window is drawn once, in one place,
    /// so this is a single group and not a set — the checkmark in the menu marks
    /// where it is, and picking another moves it.
    let memberGroupID: UUID
    let isDragging: Bool

    /// This window is frontmost — the one you're actually in.
    let isFocused: Bool
    /// Its capsule's colour. Fills the tile when focused, and tints the dot
    /// underneath it always.
    let tint: Color
    let onActivate: () -> Void
    let onToggleGroup: (UUID) -> Void
    let onClose: () -> Void
    /// Reports hover state plus the tile's frame, which the preview panel
    /// anchors to.
    let onHover: (Bool, CGRect) -> Void
    /// Toggles a pin for this window's application in one capsule.
    var onPin: ((UUID) -> Void)?
    /// Whether it is currently pinned there, for the tick.
    var isPinnedIn: ((UUID) -> Bool)?
    /// Capsules offered in the pin submenu. Every one of them is a real capsule:
    /// the menu used to lead with an "All" entry left over from the built-in
    /// group of that name, which has not existed since the strip became one row
    /// of capsules — it quietly pinned to Main, so the row it drew was a second,
    /// differently-named way to do what the Main row below it already did.
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

    /// Sizes come from the strip that is drawing this tile, so every tile in the
    /// row is built from the same scale the layout pass measured with.
    @Environment(\.deckMetrics) private var metrics

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
                        .font(.system(size: metrics.titleFontSize))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(window.isMinimized ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, showsTitle ? metrics.titlePadding : 0)
            // Keeps the dot's band clear so the icon owns everything above it.
            // Without this the icon is centred in the full tile and the dot is
            // drawn on top of its bottom edge, which is what capped the icon at
            // a size the tile had plenty of room for.
            .padding(.bottom, metrics.dotClearance)
            .frame(width: width, height: metrics.tileHeight,
                   alignment: showsTitle ? .leading : .center)
            .background(
                RoundedRectangle(cornerRadius: metrics.tileCornerRadius, style: .continuous)
                    .fill(tileFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: metrics.tileCornerRadius, style: .continuous)
                    .strokeBorder(isFocused ? tint.opacity(0.8) : .clear, lineWidth: 1)
            )
            // The Dock's running dot. Every tile in the row is an open window,
            // so this is not saying "running" — it is what makes the row read as
            // a Dock rather than as a strip of buttons, and it gives the icons a
            // baseline to sit on. A minimised window keeps it: minimised is not
            // closed, which is exactly the distinction the Dock draws too.
            .overlay(alignment: .bottom) {
                StatusDot(tint: tint, isFocused: isFocused)
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
    private func pinItem(_ name: String, groupID: UUID,
                         onPin: @escaping (UUID) -> Void) -> some View {
        Button {
            onPin(groupID)
        } label: {
            Label(name, systemImage: isPinnedIn?(groupID) == true ? "checkmark" : "")
        }
    }

    /// The focused tile is filled solidly enough to spot instantly in a row of
    /// thirty near-identical icons — that is the entire point of it.
    private var tileFill: some ShapeStyle {
        if isFocused {
            return AnyShapeStyle(tint.opacity(isHovering ? 0.62 : 0.50))
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

    /// The primary way a window is filed into another capsule.
    @ViewBuilder
    private var contextMenu: some View {
        if groups.isEmpty {
            Text("No groups yet")
        } else {
            ForEach(groups) { group in
                Button {
                    onToggleGroup(group.id)
                } label: {
                    // A checkmark reads better than "Add to"/"Remove from": one
                    // stable menu whose state you can see at a glance.
                    // A window lives in one capsule, so exactly one of these
                    // is ticked and picking another *moves* it rather than
                    // adding a second home.
                    Label(group.name, systemImage: group.id == memberGroupID ? "checkmark" : "")
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
    /// Which capsule this target is in, and which the drag began in. Every
    /// section has a group now — Main included — so the group ids answer
    /// reorder-versus-move on their own.
    var targetGroupID: UUID?
    var sourceGroupID: UUID?
    @Binding var dragging: String?
    let move: (String, String) -> Void
    /// Key, source group, target group.
    var moveBetweenGroups: ((String, UUID, UUID) -> Void)?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        // Reordering live as the drag passes only makes sense within one capsule.
        // Across capsules the row's order comes from the grouping, so a live
        // reorder would fight the layout and snap back.
        guard targetGroupID == sourceGroupID else { return }
        move(dragging, target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        // A drop in a different capsule moves the window between groups rather
        // than reordering: it joins the capsule it was dropped in and leaves the
        // one it came from, the way dragging a file between folders behaves.
        if let dragging, let source = sourceGroupID, let target = targetGroupID,
           source != target {
            moveBetweenGroups?(dragging, source, target)
            self.dragging = nil
            return true
        }

        dragging = nil
        return true
    }
}
