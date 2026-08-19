import SwiftUI

/// The Dock's running indicator: one small dot centred under the icon.
///
/// Shared rather than drawn per tile, because the last time each tile placed its
/// own the row visibly failed to line up — one sat 2.5pt higher than its
/// neighbours and half a point smaller. Every dot on the strip comes through
/// here, so they line up by construction.
///
/// What the colour means is the whole of the vocabulary:
///
/// * **Tinted with the capsule's colour** — this is an open window, drawn in
///   that capsule. Solid for the window you are actually in.
/// * **Neutral grey** — the application is running, but has no window here. That
///   is what a launcher is: the plate says "clickable", the dot says "already
///   open somewhere else".
/// * **No dot** — not running at all.
///
/// It reads as the Dock does, which is the point: a bar of icons along the
/// bottom of the screen with a dot under the live ones is a shape every Mac user
/// already knows how to read.
struct StatusDot: View {
    /// The capsule's colour for an open window, or nil for the neutral
    /// running-but-not-here dot.
    var tint: Color?
    /// The window this stands for is frontmost.
    var isFocused: Bool = false

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: DeckMetrics.statusDotSize, height: DeckMetrics.statusDotSize)
            .padding(.bottom, DeckMetrics.statusDotInset)
    }

    private var fill: Color {
        guard let tint else { return .primary.opacity(0.45) }
        // The dot sits on a bed of its own hue — the capsule is tinted at 0.13
        // to 0.22 alpha — so it has to be markedly denser than that bed or it
        // disappears into it. Measured by eye at 0.6, which vanished.
        return tint.opacity(isFocused ? 1 : 0.85)
    }
}
