import AppKit
import SwiftUI

@MainActor
@Observable
final class GroupSwitcherModel {
    var groups: [DeckGroup] = []
    var selection: Int = 0
    /// The group that is actually active, drawn with a checkmark — distinct from
    /// the selection, which is only a proposal until the modifier is released.
    var activeGroupID: UUID?

    var selectedGroupID: UUID? {
        groups.indices.contains(selection) ? groups[selection].id : nil
    }
}

/// The keyboard-driven twin of the drop-up selector.
///
/// It deliberately mirrors that menu's appearance and position — same rows, same
/// colour swatches, same checkmark on the active group, rising from the same
/// chip — because it is the same choice being made a different way.
///
/// It cannot *be* that menu. `NSMenu.popUp` runs a modal tracking loop that
/// consumes the event stream, so the `flagsChanged` monitor never sees the
/// modifier being released and Carbon hotkeys stop firing while it is open. A
/// hold-and-release interaction is therefore impossible through NSMenu, and this
/// panel exists only to make it possible.
@MainActor
final class GroupSwitcherPanel {

    private let panel: NSPanel
    private let hosting: NSHostingView<GroupSwitcherContent>
    let model = GroupSwitcherModel()

    static let rowHeight: CGFloat = 24
    private static let padding: CGFloat = 6
    private static let minWidth: CGFloat = 168

    init() {
        hosting = NSHostingView(rootView: GroupSwitcherContent(model: model))
        // Or it fights setContentSize and the panel takes an arbitrary width.
        hosting.sizingOptions = []

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.minWidth, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Above the strip and the hover panel, like the menu it stands in for.
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        // Purely keyboard-driven; letting it take clicks would only give the
        // mouse a way to fight the selection the keys are setting.
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.contentView = hosting
    }

    var isVisible: Bool { panel.isVisible }

    /// Sizes to its contents and rises from `anchor`, a screen rect for the
    /// selector chip.
    func show(anchor: NSRect) {
        let height = CGFloat(model.groups.count) * Self.rowHeight + Self.padding * 2
        let width = max(Self.minWidth, widestRow())
        panel.setContentSize(NSSize(width: width, height: height))

        // Sits above the chip with the same 6pt gap the menu uses, and is held
        // on screen if the group list ever grows taller than the display.
        var origin = NSPoint(x: anchor.minX, y: anchor.maxY + 6)
        if let screen = NSScreen.main {
            origin.x = min(origin.x, screen.visibleFrame.maxX - width - 8)
            origin.y = min(origin.y, screen.visibleFrame.maxY - height - 8)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Menus size to their widest item; so does this, or a long group name
    /// would be clipped rather than the panel simply being wider.
    private func widestRow() -> CGFloat {
        let font = NSFont.systemFont(ofSize: 13)
        let widest = model.groups
            .map { ($0.name as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        // Checkmark column + swatch + name + trailing breathing room.
        return ceil(widest) + 68
    }
}

private struct GroupSwitcherContent: View {
    @Bindable var model: GroupSwitcherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.groups.enumerated()), id: \.element.id) { index, group in
                row(group, isSelected: index == model.selection)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VisualEffectBackground(material: .menu))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.primary.opacity(0.10), lineWidth: 1)
        )
    }

    private func row(_ group: DeckGroup, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            // Fixed-width column so every name starts at the same x, the way
            // menu items with a state column do.
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .opacity(group.id == model.activeGroupID ? 1 : 0)
                .frame(width: 12)

            Circle()
                .fill(group.isAll ? Color.clear : group.displayColor)
                .frame(width: 8, height: 8)

            Text(group.name)
                .font(.system(size: 13))
                .lineLimit(1)

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 8)
        .frame(height: GroupSwitcherPanel.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Menu-style highlight: a filled accent bar, not a border.
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? Color.accentColor : .clear)
                .padding(.horizontal, 4)
        )
        .foregroundStyle(isSelected ? Color.white : Color.primary)
    }
}
