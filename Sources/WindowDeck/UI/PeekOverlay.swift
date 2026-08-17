import AppKit
import SwiftUI

/// Stage 2: the window appears at full size where it really sits.
///
/// This draws a *captured image* of the window at the window's own screen rect.
/// Nothing real is raised, activated, or reordered — the illusion is that the
/// window came forward, while the actual window stays exactly where it was. That
/// is what keeps a mis-hover free; only clicking the thumbnail changes anything.
///
/// Note the panel is sized to the window, not the screen: nothing outside the
/// window is blurred or dimmed, so peeking a window that is already fully
/// visible looks like nothing happened. The effect only reads when the window is
/// partly or wholly buried, which is the case that matters.
@MainActor
final class PeekOverlayController {

    private let panel: NSPanel
    private let hosting: NSHostingView<PeekOverlayContent>
    private let model = PeekOverlayModel()

    /// Above every ordinary application window (level 0), below the strip
    /// (.floating, 3) and the thumbnail (.popUpMenu), so both stay usable.
    private static let overlayLevel = NSWindow.Level(rawValue: 1)

    init() {
        hosting = NSHostingView(rootView: PeekOverlayContent(model: model))
        hosting.sizingOptions = []

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = Self.overlayLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        // Essential: the peek lives or dies by the cursor staying on the
        // thumbnail, so this panel must never intercept the pointer.
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.contentView = hosting
    }

    /// `rect` is the window's own frame in Cocoa screen coordinates.
    func show(image: NSImage, at rect: CGRect) {
        model.image = image
        panel.setFrame(rect, display: false)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        model.image = nil
    }

    var isVisible: Bool { panel.isVisible }
}

@MainActor
@Observable
final class PeekOverlayModel {
    var image: NSImage?
}

struct PeekOverlayContent: View {
    @Bindable var model: PeekOverlayModel

    var body: some View {
        if let image = model.image {
            Image(nsImage: image)
                .resizable()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear
        }
    }
}
