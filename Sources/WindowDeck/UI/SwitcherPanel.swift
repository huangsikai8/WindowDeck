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
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.contentView = hosting
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
                    ForEach(model.candidates) { window in
                        tile(window, isSelected: window.id == model.selectedWindowID)
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
        .background {
            ZStack {
                VisualEffectBackground(material: .hudWindow)
                // A definite dark ground rather than whatever is behind the
                // panel, so thumbnails read consistently and the HUD looks like
                // a system component rather than a form.
                Color.black.opacity(0.34)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        )
    }

    private func tile(_ window: WindowInfo, isSelected: Bool) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(0.06))

                if let image = model.images[window.id] {
                    // Fills its tile rather than floating inside a grey box.
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: SwitcherPanel.tileWidth - 22,
                               height: SwitcherPanel.tileHeight - 46)
                        .clipped()
                } else if let icon = window.icon {
                    // Windows never visited have no capture yet; the icon stands
                    // in rather than blocking the panel.
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 32, height: 32)
                }
            }
            .frame(width: SwitcherPanel.tileWidth - 22, height: SwitcherPanel.tileHeight - 46)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 4) {
                if let icon = window.icon {
                    Image(nsImage: icon).resizable().frame(width: 12, height: 12)
                }
                Text(window.displayTitle)
                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.72))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(7)
        .frame(width: SwitcherPanel.tileWidth, height: SwitcherPanel.tileHeight)
        // A thin bright ring and a slight lift of the tile — the previous heavy
        // accent-coloured block read as crude, and nothing scales or moves, so
        // stepping through is a ring jumping rather than tiles resizing.
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.white.opacity(isSelected ? 0.16 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(.white.opacity(isSelected ? 0.9 : 0), lineWidth: 1.5)
        )
    }
}
