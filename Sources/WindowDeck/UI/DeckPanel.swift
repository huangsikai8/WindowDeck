import AppKit

/// The strip itself.
///
/// `.nonactivatingPanel` is the load-bearing flag: clicking an entry must raise
/// the target window without WindowDeck stealing keyboard focus on the way.
final class DeckPanel: NSPanel {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        // Follow the user across Spaces and sit alongside fullscreen apps rather
        // than being swallowed by them.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    // A panel that never takes key or main status is what keeps focus with
    // whatever app the user is actually working in.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

}
