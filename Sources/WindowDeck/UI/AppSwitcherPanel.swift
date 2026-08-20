import AppKit
import SwiftUI

@MainActor
@Observable
final class AppSwitcherModel {
    var entries: [SwitchEntry] = []
    var selection: Int = 0

    /// Selection expressed as an identity rather than a position, for the same
    /// reason the window switcher does it: positions shift as the list is
    /// rebuilt, and a view comparing indices renders stale highlights.
    var selectedID: String? {
        entries.indices.contains(selection) ? entries[selection].id : nil
    }

    var selected: SwitchEntry? {
        entries.indices.contains(selection) ? entries[selection] : nil
    }

    /// Set from the screen width when the panel sizes itself.
    var columns: Int = 8
    /// The pointer moved onto a cell, or clicked one.
    @ObservationIgnored var onHoverIndex: ((Int) -> Void)?
    @ObservationIgnored var onClickIndex: ((Int) -> Void)?
}

/// ⌥Tab: a row of application icons, one per thing the strip draws.
///
/// Shaped like ⌘Tab because it is the same gesture aimed at a different list,
/// and drawn with icons rather than thumbnails — which means it needs no
/// captures and works with Screen Recording refused, unlike the window switcher.
@MainActor
final class AppSwitcherPanel {

    private let panel: NSPanel
    private let hosting: NSHostingView<AppSwitcherContent>
    let model = AppSwitcherModel()

    /// Wide enough for a capsule's name, which is what has to be readable — the
    /// icons alone cannot tell two Chrome entries apart. The icon shrinks inside
    /// the cell rather than the cell shrinking to the icon.
    static let cellWidth: CGFloat = 84
    static let cellHeight: CGFloat = 96
    static let maxVisibleRows = 4
    private static let padding: CGFloat = 16
    /// Room for the selected entry's title under the row.
    private static let captionHeight: CGFloat = 22

    init() {
        hosting = NSHostingView(rootView: AppSwitcherContent(model: model))
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
        // Clickable, like `SwitcherPanel`: the list is on screen, so the pointer
        // should be able to pick from it. Non-activating, so a click commits
        // without taking focus from whatever is in front.
        panel.ignoresMouseEvents = false
        panel.animationBehavior = .none
        panel.contentView = hosting

        model.onHoverIndex = { [weak self] index in
            guard let self, self.pointerHasMoved else { return }
            self.onHoverIndex?(index)
        }
        model.onClickIndex = { [weak self] index in self?.onClickIndex?(index) }
    }

    var onHoverIndex: ((Int) -> Void)?
    var onClickIndex: ((Int) -> Void)?

    /// Where the pointer was when the panel appeared — a hover fires the moment
    /// a cell appears *under* the cursor, and that must not steal the selection
    /// from the keyboard before the first tap.
    private var shownAt: NSPoint = .zero
    private var pointerHasMoved: Bool {
        hypot(NSEvent.mouseLocation.x - shownAt.x, NSEvent.mouseLocation.y - shownAt.y) > 4
    }

    var isVisible: Bool { panel.isVisible }

    /// Columns from the screen, not from the entry count: mirroring the strip
    /// means this list is as long as the bar is, and a row of forty icons across
    /// one screen would be unreadable. It wraps instead.
    static func columnCount(for screenWidth: CGFloat) -> Int {
        let usable = screenWidth * 0.86 - padding * 2
        return min(max(Int(usable / cellWidth), 4), 12)
    }

    func show() {
        resize()
        shownAt = NSEvent.mouseLocation
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        model.entries = []
    }

    private func resize() {
        guard let screen = NSScreen.main else { return }
        let count = max(model.entries.count, 1)

        // Never wider than there are cells to fill — sizing to the screen's
        // capacity regardless of content leaves a large empty area beside a
        // short list, which the window switcher had to learn too.
        let columns = min(count, Self.columnCount(for: screen.frame.width))
        model.columns = columns

        let rows = min(Int(ceil(Double(count) / Double(columns))), Self.maxVisibleRows)
        let width = CGFloat(columns) * Self.cellWidth + Self.padding * 2
        let height = CGFloat(rows) * Self.cellHeight + Self.padding * 2 + Self.captionHeight

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

struct AppSwitcherContent: View {
    @Bindable var model: AppSwitcherModel

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(AppSwitcherPanel.cellWidth), spacing: 0),
            count: max(model.columns, 1)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: columns, spacing: 0) {
                        // One identity per cell, and it is the strip's own slot
                        // id — section included, so the same application in two
                        // capsules is two cells rather than two views claiming
                        // to be the same thing.
                        ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                            cell(entry, isSelected: entry.id == model.selectedID)
                                .contentShape(Rectangle())
                                .onHover { if $0 { model.onHoverIndex?(index) } }
                                .onTapGesture { model.onClickIndex?(index) }
                        }
                    }
                }
                .onChange(of: model.selection) { _, _ in
                    // Keeps the selection on screen when the list wraps past the
                    // visible rows. Not animated: easing here reads as the row
                    // sliding under the highlight.
                    guard let id = model.selectedID else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
            }

            // The selected entry spelled out, where there is room for words: the
            // chip under each icon says which capsule, this says which window.
            Text(model.selected.map { caption(for: $0) } ?? "")
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(height: 22)
                .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The same plate as every other panel in the app.
        .background(VisualEffectBackground(material: .popover))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func caption(for entry: SwitchEntry) -> String {
        switch entry.count {
        case 0: "\(entry.title) — \(entry.groupName)"
        case 1: "\(entry.windows[0].displayTitle) — \(entry.groupName)"
        default: "\(entry.title) — \(entry.count) windows in \(entry.groupName)"
        }
    }

    private func cell(_ entry: SwitchEntry, isSelected: Bool) -> some View {
        VStack(spacing: 5) {
            iconLayer(entry)
            chip(entry, isSelected: isSelected)
        }
        .padding(6)
        .frame(width: AppSwitcherPanel.cellWidth, height: AppSwitcherPanel.cellHeight)
        // Selection is a plate and a ring that jump between cells — nothing
        // scales, slides or fades, matching the window switcher exactly.
        //
        // `.primary`, not white: on the popover material a white ring is
        // invisible in light appearance.
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.primary.opacity(isSelected ? 0.14 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.primary.opacity(isSelected ? 0.75 : 0), lineWidth: 1.5)
        )
    }

    private func iconLayer(_ entry: SwitchEntry) -> some View {
        Group {
            if let icon = entry.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 40, height: 40)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(0.08))
                    .frame(width: 40, height: 40)
            }
        }
        // The count badge, in the same place and shape the strip's stack tile
        // uses — this is the same idea, so it should not look like a new one.
        // An overlay with inset padding rather than an offset: an offset view is
        // hit-tested and laid out outside its parent, which has bitten this app
        // once already.
        .overlay(alignment: .topTrailing) {
            if entry.count > 1 {
                Text("\(entry.count)")
                    .font(.system(size: 8, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.background)
                    .padding(.horizontal, 3)
                    .frame(minWidth: 12, minHeight: 12)
                    .background(Capsule().fill(.primary.opacity(0.75)))
                    .offset(x: 6, y: -3)
            }
        }
        .frame(height: 42)
    }

    /// Which capsule this entry lives in, under every icon rather than only the
    /// selected one. The list is in most-recently-used order, so capsules
    /// interleave and two icons of one application are otherwise identical.
    private func chip(_ entry: SwitchEntry, isSelected: Bool) -> some View {
        Text(entry.groupName)
            .font(.system(size: 9, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(entry.groupColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity)
            .background(
                Capsule().fill(entry.groupColor.opacity(isSelected ? 0.28 : 0.18))
            )
    }
}
