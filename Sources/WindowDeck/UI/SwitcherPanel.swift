import AppKit
import SwiftUI

@MainActor
@Observable
final class SwitcherModel {
    var candidates: [WindowInfo] = []
    var selection: Int = 0

    /// Selection expressed as a window, so the view can compare identities
    /// rather than positions — positions shift as the list reorders.
    var selectedWindowID: CGWindowID? {
        candidates.indices.contains(selection) ? candidates[selection].id : nil
    }
    var images: [CGWindowID: NSImage] = [:]
    /// Set from the screen width when the panel sizes itself.
    var columns: Int = 5
    /// Asked to capture a window that has no image yet. Only fired for tiles
    /// actually on screen, so a large group costs a screenful, not all of it.
    @ObservationIgnored var onNeedsImage: ((WindowInfo) -> Void)?
    /// The pointer moved onto a tile, or clicked one. Routed through the panel
    /// rather than straight to the controller so the "has the mouse actually
    /// moved yet" guard lives in one place.
    @ObservationIgnored var onHoverIndex: ((Int) -> Void)?
    @ObservationIgnored var onClickIndex: ((Int) -> Void)?
}

/// The switcher grid: as wide as the screen comfortably allows, about three rows
/// tall, scrolling beyond that rather than growing.
@MainActor
final class SwitcherPanel {

    private let panel: NSPanel
    private let hosting: NSHostingView<SwitcherContent>
    let model = SwitcherModel()

    static let tileWidth: CGFloat = 158
    static let tileHeight: CGFloat = 122
    /// Rows shown before it starts scrolling.
    static let maxVisibleRows = 3
    private static let padding: CGFloat = 14

    init() {
        hosting = NSHostingView(rootView: SwitcherContent(model: model))
        hosting.sizingOptions = []

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        // Clickable. It was `ignoresMouseEvents = true` on the argument that
        // this is keyboard-driven — true, and beside the point: the list is on
        // screen and the obvious thing to do with a thing on screen is click it.
        // The panel is non-activating, so a click commits without taking focus
        // from whatever is in front.
        panel.ignoresMouseEvents = false
        panel.animationBehavior = .none
        panel.contentView = hosting

        model.onHoverIndex = { [weak self] index in
            guard let self, self.pointerHasMoved else { return }
            self.onHoverIndex?(index)
        }
        model.onClickIndex = { [weak self] index in self?.onClickIndex?(index) }
    }

    /// Pointer selection, once the pointer has actually moved.
    var onHoverIndex: ((Int) -> Void)?
    var onClickIndex: ((Int) -> Void)?

    /// Where the pointer was when the panel appeared.
    ///
    /// SwiftUI reports a hover the moment a view appears *under* the cursor, so
    /// without this the tile that happened to open beneath the mouse would seize
    /// the selection from the keyboard before the first tap — and a switcher
    /// that starts somewhere arbitrary is worse than one that ignores the mouse.
    private var shownAt: NSPoint = .zero
    private var pointerHasMoved: Bool {
        hypot(NSEvent.mouseLocation.x - shownAt.x, NSEvent.mouseLocation.y - shownAt.y) > 4
    }

    var isVisible: Bool { panel.isVisible }

    /// Columns are derived from the screen rather than the window count, so
    /// tiles keep a readable size instead of the panel stretching to fit.
    static func columnCount(for screenWidth: CGFloat) -> Int {
        let usable = screenWidth * 0.82 - padding * 2
        return min(max(Int(usable / tileWidth), 3), 8)
    }

    func show() {
        resize()
        shownAt = NSEvent.mouseLocation
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        model.candidates = []
        model.images = [:]
    }

    /// Width from the column count, height clamped to `maxVisibleRows` — the
    /// panel never grows with the number of windows.
    private func resize() {
        guard let screen = NSScreen.main else { return }
        let count = max(model.candidates.count, 1)

        // Never wider than there are tiles to fill. Sizing to the screen's
        // column capacity regardless of content left a large empty area beside
        // a short list — four windows in a six-column panel.
        let columns = min(count, Self.columnCount(for: screen.frame.width))
        model.columns = columns

        let rows = min(Int(ceil(Double(count) / Double(columns))), Self.maxVisibleRows)

        let width = CGFloat(columns) * Self.tileWidth + Self.padding * 2
        let height = CGFloat(rows) * Self.tileHeight + Self.padding * 2

        panel.setFrame(
            NSRect(
                x: screen.frame.midX - width / 2,
                y: screen.frame.midY - height / 2,
                width: width,
                height: height
            ),
            display: true
        )
    }
}

struct SwitcherContent: View {
    @Bindable var model: SwitcherModel

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(SwitcherPanel.tileWidth), spacing: 0),
            count: max(model.columns, 1)
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                // Lazy on purpose: only tiles actually on screen render, so only
                // those ask for a capture. A 40-window group costs a screenful.
                LazyVGrid(columns: columns, spacing: 0) {
                    // Exactly one identity per tile: the window id, which ForEach
                    // supplies and scrollTo targets. Adding `.id(index)` on top
                    // gave each tile a second, competing identity — so when the
                    // list reordered between presses (which most-recently-used
                    // ordering guarantees) SwiftUI reused views in stale
                    // positions and their selected state never refreshed,
                    // rendering the row rotated with leftover highlights.
                    ForEach(Array(model.candidates.enumerated()), id: \.element.id) { index, window in
                        tile(window, isSelected: window.id == model.selectedWindowID)
                            .contentShape(Rectangle())
                            .onHover { if $0 { model.onHoverIndex?(index) } }
                            .onTapGesture { model.onClickIndex?(index) }
                            .onAppear {
                                if model.images[window.id] == nil {
                                    model.onNeedsImage?(window)
                                }
                            }
                    }
                }
            }
            .onChange(of: model.selection) { _, _ in
                // Keeps the selection visible so cycling past the last visible
                // row scrolls rather than running off the bottom. Not animated:
                // any easing here reads as the row sliding under the ring.
                guard let id = model.selectedWindowID else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The same plate as the hover preview and the app-stack list. This was
        // the last dark surface in the app, kept that way on the argument that a
        // keyboard mode taking over the screen should say so with a dark ground.
        // Three panels answering the same question — which window do you want —
        // in two different skins reads as two applications, and the argument
        // does not survive that: the strip is right there behind it either way.
        .background(VisualEffectBackground(material: .popover))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func tile(_ window: WindowInfo, isSelected: Bool) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.primary.opacity(0.06))

                if let image = model.images[window.id] {
                    // `.fit`, like the preview and the stack list: on a light
                    // plate a cropped thumbnail reads as a mistake, and the
                    // window's real proportions are what tell two windows of one
                    // application apart.
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else if let icon = window.icon {
                    // Windows never visited have no capture yet; the icon stands
                    // in rather than blocking the panel.
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 32, height: 32)
                }
            }
            .frame(width: SwitcherPanel.tileWidth - 22, height: SwitcherPanel.tileHeight - 46)

            HStack(spacing: 4) {
                if let icon = window.icon {
                    Image(nsImage: icon).resizable().frame(width: 12, height: 12)
                }
                Text(window.displayTitle)
                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary.opacity(isSelected ? 1 : 0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(7)
        .frame(width: SwitcherPanel.tileWidth, height: SwitcherPanel.tileHeight)
        // A thin ring and a slight lift of the tile — the previous heavy
        // accent-coloured block read as crude, and nothing scales or moves, so
        // stepping through is a ring jumping rather than tiles resizing.
        //
        // Drawn in `.primary`, not white: the panel no longer supplies its own
        // dark ground, and a white ring on a light popover is invisible.
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.primary.opacity(isSelected ? 0.14 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.primary.opacity(isSelected ? 0.75 : 0), lineWidth: 1.5)
        )
    }
}
