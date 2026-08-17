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
    let onActivate: () -> Void
    let onSeparate: () -> Void
    let onRename: () -> Void
    let onRemove: (WindowInfo) -> Void
    let onHover: (Bool, CGRect) -> Void

    @State private var isHovering = false
    @State private var frame: CGRect = .zero

    /// More than three overlapped icons is mush; the badge carries the real count.
    private var shown: [WindowInfo] { Array(members.prefix(3)) }

    var body: some View {
        Button(action: onActivate) {
            ZStack(alignment: .bottomTrailing) {
                stack
                countBadge
            }
            .frame(width: width, height: DeckMetrics.tileHeight)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(isHovering ? 0.16 : 0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.primary.opacity(0.18), lineWidth: 1)
            )
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
    private var stack: some View {
        ZStack {
            ForEach(Array(shown.enumerated().reversed()), id: \.offset) { index, member in
                if let icon = member.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: iconSize, height: iconSize)
                        .offset(x: CGFloat(index) * iconSize * 0.30 - iconSize * 0.30,
                                y: CGFloat(index) * -1.5)
                        .shadow(color: .black.opacity(0.25), radius: 0.5, x: -0.5, y: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var countBadge: some View {
        Text("\(members.count)")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 3)
            .frame(minWidth: 12, minHeight: 12)
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
