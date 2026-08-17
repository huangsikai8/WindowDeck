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

    /// Fires with the direction of a horizontal swipe made over the strip.
    var onHorizontalSwipe: ((GroupCycleDirection) -> Void)?

    private var scrolled: CGFloat = 0
    private var hasFired = false

    /// Points of horizontal travel before a switch, set from the sensitivity
    /// slider. Trackpads report large deltas, so even the least sensitive end is
    /// a flick rather than a sweep.
    var threshold: CGFloat = 47

    /// Scrolling over our own window needs no permission at all — the events are
    /// delivered to us because the pointer is here, not because we asked to
    /// watch the system. That is the entire reason this path exists alongside
    /// the global event tap.
    override func scrollWheel(with event: NSEvent) {
        guard onHorizontalSwipe != nil else { return super.scrollWheel(with: event) }

        switch event.phase {
        case .began:
            scrolled = 0
            hasFired = false
        case .ended, .cancelled:
            scrolled = 0
            hasFired = false
            return
        default:
            break
        }

        // Momentum is the trackpad coasting after the fingers left; acting on it
        // would turn one flick into several switches.
        guard event.momentumPhase == [] else { return }

        // Vertical intent shouldn't switch groups sideways.
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return }

        scrolled += event.scrollingDeltaX
        guard !hasFired, abs(scrolled) >= threshold else { return }

        hasFired = true
        // Content pushed left brings the next group in from the right.
        onHorizontalSwipe?(scrolled < 0 ? .next : .previous)
    }
}
