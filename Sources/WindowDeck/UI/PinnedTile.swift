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
    /// False for an app shown only because it is running with no windows. It
    /// looks identical — the distinction is what the context menu offers, since
    /// there is nothing to unpin.
    var isPinned: Bool = true
    /// Groups this app's closed window belongs to. Non-empty only for a member
    /// whose window was closed — it shows the same dots the window showed, so
    /// closing a window changes nothing about how the tile reads.
    var memberColors: [Color] = []
    /// Passed in from the store's sampled snapshot. Asking
    /// `NSRunningApplication` here meant a lookup per launcher per redraw.
    let isRunning: Bool
    let onOpen: () -> Void
    /// Toggles the pin in a group; nil means All.
    var onTogglePin: ((UUID?) -> Void)?
    var isPinnedIn: ((UUID?) -> Bool)?
    /// Groups offered alongside All.
    var pinTargets: [DeckGroup] = []
    let onUnpin: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: iconSize, height: iconSize)
                        // Unlit when the app isn't open. Drawing it at full
                        // strength claimed the app was here, which is the one
                        // thing a launcher must not say.
                        .opacity(isRunning ? 1 : (isHovering ? 0.85 : 0.5))
                }
            }
            .frame(width: width, height: DeckMetrics.tileHeight)
            // Running indicator, same idea as the Dock's dot.
            //
            // Anchored to the *tile*, matching `DeckMetrics.statusDotSize` and
            // `statusDotInset` exactly as the group dots on a window tile do.
            // It used to hang off the bottom of the icon inside a ZStack, which
            // put it 2.5pt higher than its neighbours and half a point smaller —
            // a whole row of dots that visibly failed to line up.
            .overlay(alignment: .bottom) {
                if !memberColors.isEmpty {
                    // A member whose window is closed keeps its group dots. The
                    // grey running dot would say "this is a launcher now", and
                    // it isn't — it is the same member it was a moment ago.
                    HStack(spacing: 2.5) {
                        ForEach(Array(memberColors.enumerated()), id: \.offset) { _, color in
                            Circle()
                                .fill(color)
                                .frame(width: DeckMetrics.statusDotSize,
                                       height: DeckMetrics.statusDotSize)
                        }
                    }
                    .padding(.bottom, DeckMetrics.statusDotInset)
                } else if isRunning {
                    Circle()
                        .fill(.primary.opacity(0.65))
                        .frame(width: DeckMetrics.statusDotSize,
                               height: DeckMetrics.statusDotSize)
                        .padding(.bottom, DeckMetrics.statusDotInset)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(plateOpacity(isRunning: isRunning)))
            )
        }
        .buttonStyle(.plain)
        .opacity(isDragging ? 0.35 : 1)
        .onHover { isHovering = $0 }
        .help(isPinned
              ? (isRunning ? "\(app.name) — running, no window here" : "Open \(app.name)")
              : "\(app.name) — running, no windows open")
        .contextMenu {
            if let onTogglePin {
                // The same toggle a window offers, so the menu shows where this
                // app is pinned and changes it — rather than a one-way "remove"
                // that says nothing about the other groups.
                Menu("Pin \(app.name) to") {
                    pinItem("All", groupID: nil, onTogglePin: onTogglePin)
                    if !pinTargets.isEmpty { Divider() }
                    ForEach(pinTargets) { group in
                        pinItem(group.name, groupID: group.id, onTogglePin: onTogglePin)
                    }
                }
            } else {
                Button(isPinned ? "Remove from Deck" : "Pin to this group", action: onUnpin)
            }
        }
    }

    @ViewBuilder
    private func pinItem(_ name: String, groupID: UUID?,
                         onTogglePin: @escaping (UUID?) -> Void) -> some View {
        Button {
            onTogglePin(groupID)
        } label: {
            Label(name, systemImage: isPinnedIn?(groupID) == true ? "checkmark" : "")
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
