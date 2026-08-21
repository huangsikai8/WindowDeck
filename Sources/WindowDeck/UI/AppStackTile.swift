import AppKit
import SwiftUI

/// Every window of one application behind that application's own icon.
///
/// Deliberately modelled on `PinnedTile` rather than `ClusterTile`: what this
/// draws is **one app**, so it shows one icon at full size. A cluster overlaps
/// three icons because its members are genuinely different applications and the
/// tile has to say which; here they are all the same icon and overlapping them
/// would only make it blurry.
///
/// The count badge is what tells the two apart at 40pt, so it must not reuse the
/// cluster's blue capsule — that colour already means "cluster". A neutral badge
/// on the tile's own plate reads as "this app, several windows" rather than as a
/// second kind of cluster.
struct AppStackTile: View {
    let name: String
    let icon: NSImage?
    let count: Int
    let width: CGFloat
    let iconSize: CGFloat
    let isDragging: Bool
    /// One of this stack's windows is frontmost.
    let isFocused: Bool
    /// Its capsule's colour, for the plate and the dot.
    let tint: Color
    /// Windows in most-recently-used order, for the menu.
    let windows: [WindowInfo]
    let onActivate: () -> Void
    let onActivateWindow: (WindowInfo) -> Void
    let onUnstack: () -> Void
    let onHover: (Bool, CGRect) -> Void

    @State private var isHovering = false
    @State private var frame: CGRect = .zero

    /// Sizes come from the strip that is drawing this tile, so every tile in the
    /// row is built from the same scale the layout pass measured with.
    @Environment(\.deckMetrics) private var metrics

    var body: some View {
        Button(action: onActivate) {
            iconLayer
                .padding(.bottom, metrics.dotClearance)
                .frame(width: width, height: metrics.tileHeight)
                .overlay(alignment: .topTrailing) { badge }
                // One dot, not one per window: the badge already says how many.
                .overlay(alignment: .bottom) { StatusDot(tint: tint, isFocused: isFocused) }
                .background(
                    RoundedRectangle(cornerRadius: metrics.tileCornerRadius, style: .continuous)
                        .fill(plateFill)
                )
                .background(frameReader)
                // Hit-testing is the tile's rectangle and nothing else.
                //
                // Without this the badge decided it: it was drawn with an
                // `offset` that put it ~13pt beyond a 40pt tile, and SwiftUI
                // hit-tests an offset view where it was offset *to*, not where it
                // was laid out. The tile therefore answered hover over its
                // neighbour, so the panel appeared for a stack the pointer was
                // merely near. Keeping the badge inside the frame fixes the
                // drawing; this makes the hover area independent of decoration.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isDragging ? 0.35 : 1)
        .onHover { hovering in
            isHovering = hovering
            onHover(hovering, frame)
        }
        .help("\(name) — \(count) windows")
        .contextMenu {
            Button("Open Most Recent Window", action: onActivate)
            Menu("Windows") {
                ForEach(windows) { window in
                    Button(window.displayTitle) { onActivateWindow(window) }
                }
            }
            Divider()
            Button("Unstack \(name)", action: onUnstack)
        }
    }

    private var iconLayer: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Top-trailing, not bottom-trailing like the cluster's, which keeps the
    /// bottom edge of every tile in the row clear.
    ///
    /// Drawn as an `overlay` on the tile frame with inset padding rather than
    /// offset out of a `ZStack`. An offset puts it outside the tile, and a view
    /// outside the tile is still hovered *as* the tile — which is what made the
    /// panel open for a stack the pointer was only near.
    private var badge: some View {
        Text("\(count)")
            .font(.system(size: metrics.badgeFontSize, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.background)
            .padding(.horizontal, metrics.badgePadding)
            .frame(minWidth: metrics.badgeMinSize, minHeight: metrics.badgeMinSize)
            .background(Capsule().fill(.primary.opacity(0.75)))
            .padding(.top, 1)
            .padding(.trailing, 1)
    }

    private var plateFill: Color {
        if isFocused { return tint }
        return .primary.opacity(isHovering ? 0.16 : 0.09)
    }

    private var frameReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { frame = geo.frame(in: .global) }
                .onChange(of: geo.frame(in: .global)) { _, new in frame = new }
        }
    }
}
