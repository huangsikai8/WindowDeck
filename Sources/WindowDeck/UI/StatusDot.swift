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
/// * **Tinted with the capsule's colour** — the application is running. A window
///   drawn in that capsule and a launcher for an app with no windows at all get
///   the same dot, deliberately: the Dock draws one indicator for "running" and
///   says nothing about how many windows are behind it.
/// * **Neutral** — the window you are actually *in*. Its tile is filled with the
///   capsule's own colour, so a dot of that colour on top of it would vanish.
/// * **No dot** — not running at all.
///
/// The dot answers "is this alive", and the *plate* answers "is there a window
/// here" — a launcher draws unlit until its app is running. Splitting the two
/// questions across two signals is what lets the dot match the Dock exactly
/// without losing the distinction. An earlier version put both on the dot, which
/// made an app you had merely closed look like a lesser kind of thing than one
/// with a window open.
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
        // Contrast is against the *plate directly underneath*, not against the
        // capsule, and the plate changes colour when the tile is focused — so
        // the dot has to change with it.
        //
        // A focused tile is filled with its capsule's own colour, and a dot of
        // that same colour on top of it simply disappeared: the blue window you
        // were in had no visible dot while the green one beside it did. Focused
        // therefore goes neutral, which reads on any group colour in either
        // appearance. Unfocused sits on a near-neutral plate and takes the
        // capsule's colour instead.
        // Retained for a caller with no capsule to take a colour from; every
        // tile in the strip passes one.
        guard let tint else { return .primary.opacity(0.45) }
        if isFocused { return .primary.opacity(0.9) }
        // Markedly denser than the capsule's own 0.13–0.22 tint or it vanishes
        // into the bed. Tried at 0.6, which did.
        return tint.opacity(0.85)
    }
}
