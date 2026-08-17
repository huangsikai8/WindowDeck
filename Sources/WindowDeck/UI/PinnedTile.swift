import AppKit
import SwiftUI

/// A launcher in the strip. An ordinary item in the row rather than a section of
/// its own, so it takes its width from the same layout pass as everything else —
/// which is what stops it holding a fixed size while the windows compress
/// around it.
struct PinnedTile: View {
    let app: PinnedApp
    let width: CGFloat
    let iconSize: CGFloat
    let isDragging: Bool
    let onOpen: () -> Void
    let onUnpin: () -> Void

    @State private var isHovering = false

    var body: some View {
        // Read per redraw rather than stored. The engine refreshes on every app
        // launch and quit, which are precisely the moments this changes, so the
        // strip is already being rebuilt when it matters.
        let isRunning = app.isRunning

        Button(action: onOpen) {
            ZStack(alignment: .bottom) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: iconSize, height: iconSize)
                        // Unlit when the app isn't open. Drawing it at full
                        // strength claimed the app was here, which is the one
                        // thing a launcher must not say.
                        .opacity(isRunning ? 1 : (isHovering ? 0.85 : 0.5))
                }
                // Running indicator, same idea as the Dock's dot. Reaching this
                // means the app is open but has no window in this group.
                if isRunning {
                    Circle()
                        .fill(.primary.opacity(0.65))
                        .frame(width: 3.5, height: 3.5)
                        .offset(y: 3)
                }
            }
            .frame(width: width, height: DeckMetrics.tileHeight)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(plateOpacity(isRunning: isRunning)))
            )
        }
        .buttonStyle(.plain)
        .opacity(isDragging ? 0.35 : 1)
        .onHover { isHovering = $0 }
        .help(isRunning ? "\(app.name) — running, no window here" : "Open \(app.name)")
        .contextMenu {
            Button("Remove from Deck", action: onUnpin)
        }
    }

    /// The lit plate is what says "this exists right now", so a launcher for
    /// something closed gets none and the row separates into open things and
    /// shortcuts without needing a second visual language. It still lights on
    /// hover, which is what keeps it reading as clickable rather than disabled.
    private func plateOpacity(isRunning: Bool) -> Double {
        if isRunning { return isHovering ? 0.14 : 0.06 }
        return isHovering ? 0.10 : 0
    }
}
