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
    let memberColors: [GroupColor]
    let isDragging: Bool
    /// Dwelling here with a drag will merge the two into a cluster.
    let isCombineTarget: Bool
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
                                .fill(color.color)
                                .frame(width: 4, height: 4)
                        }
                    }
                    .padding(.bottom, 1.5)
                }
            }
            .background(frameReader)
        }
        .buttonStyle(.plain)
        .opacity(isDragging ? 0.35 : 1)
        // Growing is the signal that releasing here combines rather than
        // reorders.
        .scaleEffect(isCombineTarget ? 1.12 : 1)
        .overlay {
            if isCombineTarget {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.blue, lineWidth: 2)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isCombineTarget)
        .onHover { hovering in
            isHovering = hovering
            onHover(hovering, frame)
        }
        // No .help() here on purpose: its ~1.5s system delay is exactly the
        // problem. The title chip shown from HoverController names the window
        // instantly instead.
        .contextMenu { contextMenu }
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

        Divider()

        Button("Close Window", action: onClose)
    }
}

/// Handles both gestures the strip supports with one drag.
///
/// Passing over a tile reorders, as before. *Dwelling* on one for
/// `combineDelay` arms a combine instead — the tile grows to say so, and
/// releasing there merges the two into a cluster. Same idea as dropping one app
/// onto another to make a folder on a phone, and it's the only way to tell
/// "I'm heading somewhere past this" apart from "I mean this one".
struct EntryDropDelegate: DropDelegate {
    /// Ordering key — windows and pins share one namespace.
    let target: String
    /// Only windows can be combined into a cluster; a pin has none.
    let targetWindowID: CGWindowID?
    @Binding var dragging: String?
    @Binding var combineTarget: String?
    let move: (String, String) -> Void
    let combine: (CGWindowID, CGWindowID) -> Void

    static let combineDelay: TimeInterval = 0.7

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        move(dragging, target)

        let source = dragging
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.combineDelay) {
            // Only arm if the same drag is still in progress and hasn't moved on.
            guard self.dragging == source else { return }
            combineTarget = target
        }
    }

    func dropExited(info: DropInfo) {
        if combineTarget == target { combineTarget = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        // Combining is window-to-window only; dropping a pin onto one reorders.
        if combineTarget == target,
           let dragging, dragging != target,
           dragging.hasPrefix("w"),
           let source = CGWindowID(dragging.dropFirst()),
           let targetWindowID {
            combine(source, targetWindowID)
        }
        dragging = nil
        combineTarget = nil
        return true
    }
}
