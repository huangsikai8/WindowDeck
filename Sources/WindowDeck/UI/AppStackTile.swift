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
    let isFocused: Bool
    let memberColors: [Color]
    let focusTint: Color
    /// Windows in most-recently-used order, for the menu.
    let windows: [WindowInfo]
    let onActivate: () -> Void
    let onActivateWindow: (WindowInfo) -> Void
    let onUnstack: () -> Void
    let onHover: (Bool, CGRect) -> Void

    @State private var isHovering = false
    @State private var frame: CGRect = .zero

    var body: some View {
        Button(action: onActivate) {
            iconLayer
                .frame(width: width, height: DeckMetrics.tileHeight)
                .overlay(alignment: .topTrailing) { badge }
                .overlay(alignment: .bottom) { dots }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
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

    /// Top-trailing, not bottom-trailing like the cluster's. The bottom of every
    /// tile is where the group dots live, and a badge there would sit on top of
    /// them — a stacked window still belongs to groups and still has to show it.
    ///
    /// Drawn as an `overlay` on the tile frame with inset padding rather than
    /// offset out of a `ZStack`. An offset puts it outside the tile, and a view
    /// outside the tile is still hovered *as* the tile — which is what made the
    /// panel open for a stack the pointer was only near.
    private var badge: some View {
        Text("\(count)")
            .font(.system(size: 8, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.background)
            .padding(.horizontal, 3)
            .frame(minWidth: 12, minHeight: 12)
            .background(Capsule().fill(.primary.opacity(0.75)))
            .padding(.top, 1)
            .padding(.trailing, 1)
    }

    @ViewBuilder
    private var dots: some View {
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

    private var plateFill: Color {
        if isFocused { return focusTint }
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
