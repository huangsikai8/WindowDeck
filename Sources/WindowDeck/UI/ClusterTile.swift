import AppKit
import SwiftUI

/// Several windows behind one icon: member app icons overlapped, with a count.
///
/// No setup required — it describes itself from its members, so combining two
/// windows produces something recognisable immediately.
struct ClusterTile: View {
    let cluster: WindowCluster
    let members: [WindowInfo]
    let width: CGFloat
    let iconSize: CGFloat
    let isDragging: Bool
    /// Its capsule's colour, for the dot beneath.
    let tint: Color
    /// One of its members is frontmost.
    var isFocused: Bool = false
    let onActivate: () -> Void
    let onSeparate: () -> Void
    let onRename: () -> Void
    let onRemove: (WindowInfo) -> Void
    let onHover: (Bool, CGRect) -> Void

    @State private var isHovering = false
    @State private var frame: CGRect = .zero

    /// Sizes come from the strip that is drawing this tile, so every tile in the
    /// row is built from the same scale the layout pass measured with.
    @Environment(\.deckMetrics) private var metrics

    /// One icon per member, up to `clusterStackDepth`; past that the badge alone
    /// carries the count. The layout sized `iconSize` against this exact number,
    /// so drawing one more here would put artwork outside the tile measured for it.
    private var shown: [WindowInfo] { Array(members.prefix(DeckLayout.clusterStackDepth)) }

    /// How far apart the icons are drawn, across and up. It comes from
    /// `DeckLayout`, which chose `iconSize` against exactly this — the step is
    /// what the layout could *not* spend on the icon, so it is derived from the
    /// icon rather than assumed. Reading a fixed step here would leave a stack
    /// bounded by the icon band sitting narrow in the middle of its own tile.
    private var stackStep: CGSize {
        DeckLayout.clusterStep(depth: shown.count, width: width,
                               iconSize: iconSize, metrics: metrics)
    }

    /// Filled with the capsule's colour when one of its windows is frontmost,
    /// exactly as a window tile is — a cluster is a window you are in, and it
    /// was the one tile kind that said nothing about it.
    private var plateFill: AnyShapeStyle {
        if isFocused { return AnyShapeStyle(tint.opacity(isHovering ? 0.62 : 0.50)) }
        return AnyShapeStyle(.primary.opacity(isHovering ? 0.16 : 0.09))
    }

    var body: some View {
        Button(action: onActivate) {
            ZStack(alignment: .bottomTrailing) {
                stack
                countBadge
            }
            .padding(.bottom, metrics.dotClearance)
            .frame(width: width, height: metrics.tileHeight)
            // The icon frame overhangs the tile by design — a macOS icon carries
            // ~15% transparent margin, so the frame is drawn larger than the box
            // to make the *artwork* fill it. Hit-testing must stay the tile's own
            // rectangle: SwiftUI would otherwise take the label's bounds, and a
            // tile that answers hover beyond its edge is the count-badge trap
            // again — a stack that opened for its neighbour.
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: metrics.tileCornerRadius, style: .continuous)
                    .fill(plateFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: metrics.tileCornerRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.18), lineWidth: 1)
            )
            .overlay(alignment: .bottom) { StatusDot(tint: tint, isFocused: isFocused) }
            .background(frameReader)
        }
        .buttonStyle(.plain)
        .opacity(isDragging ? 0.35 : 1)
        .onHover { hovering in
            isHovering = hovering
            onHover(hovering, frame)
        }
        .contextMenu {
            Button("Open All \(members.count) Windows", action: onActivate)
            Divider()
            Button("Rename…", action: onRename)
            Button("Separate", action: onSeparate)
            Divider()
            Menu("Remove from Group") {
                ForEach(members) { member in
                    Button(member.displayTitle) { onRemove(member) }
                }
            }
        }
    }

    /// Overlapped, most recent first, offset by a fraction of the icon so the
    /// stack reads as depth rather than a row.
    ///
    /// Offsets are measured from the **middle of the stack being drawn**, not from
    /// a fixed first slot. Stepping from index 0 centres a stack of exactly
    /// `clusterStackDepth`, and pulls every shorter one off to one side — a
    /// cluster of two sat 6.4pt left of its own tile at 1.15x, which is a third of
    /// its margin, and it read as the tile being wrong rather than the icons.
    private var stack: some View {
        ZStack {
            ForEach(Array(shown.enumerated().reversed()), id: \.offset) { index, member in
                if let icon = member.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: iconSize, height: iconSize)
                        .offset(x: step(index) * stackStep.width,
                                y: step(index) * -stackStep.height)
                        .shadow(color: .black.opacity(0.25), radius: 0.5, x: -0.5, y: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// How far this icon sits from the middle of the stack, in steps. Symmetric
    /// about zero, so the stack is centred whatever its depth — on both axes,
    /// since it now travels up as well as across.
    private func step(_ index: Int) -> CGFloat {
        CGFloat(index) - CGFloat(shown.count - 1) / 2
    }

    private var countBadge: some View {
        Text("\(members.count)")
            .font(.system(size: metrics.badgeFontSize, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, metrics.badgePadding)
            .frame(minWidth: metrics.badgeMinSize, minHeight: metrics.badgeMinSize)
            .background(Capsule().fill(.blue))
            .padding(.trailing, 1)
            .padding(.bottom, 1)
    }

    private var frameReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { frame = geo.frame(in: .global) }
                .onChange(of: geo.frame(in: .global)) { _, new in frame = new }
        }
    }
}
