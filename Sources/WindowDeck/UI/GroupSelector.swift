import AppKit
import SwiftUI

/// Holds a reference to a real `NSView` so the menu has something to pop up
/// from, and acts as the target for menu item actions (SwiftUI structs can't be
/// Objective-C targets).
@MainActor
final class SelectorMenuController: NSObject {
    weak var anchorView: NSView?
    var onSelect: ((UUID) -> Void)?
    var onNewGroup: (() -> Void)?
    var onEditGroups: (() -> Void)?

    @objc func selectGroup(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onSelect?(id)
    }

    @objc func newGroup() { onNewGroup?() }
    @objc func editGroups() { onEditGroups?() }
}

private struct MenuAnchorView: NSViewRepresentable {
    let controller: SelectorMenuController

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        controller.anchorView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The drop-up group selector pinned at the left of the strip.
///
/// An `NSMenu` is used rather than SwiftUI's `Menu`: the strip lives in a
/// `.nonactivatingPanel`, where SwiftUI's menu presentation drops events.
/// `NSMenu` also brings keyboard navigation and type-to-select for free.
struct GroupSelector: View {
    @Bindable var store: AppStore
    let onNewGroup: () -> Void
    let onEditGroups: () -> Void

    @State private var controller = SelectorMenuController()
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            if !store.activeGroup.isAll {
                Circle()
                    .fill(store.activeGroup.color.color)
                    .frame(width: 7, height: 7)
            }
            Text(store.activeGroup.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Image(systemName: "chevron.up")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(width: DeckMetrics.selectorWidth, height: DeckMetrics.tileHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    store.activeGroup.isAll ? .clear : store.activeGroup.color.color.opacity(0.55),
                    lineWidth: 1
                )
        )
        .background(MenuAnchorView(controller: controller))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { showMenu() }
        .help("Switch arrangement")
    }

    /// A small colour dot for the drop-up menu. NSMenu takes an NSImage, so the
    /// swatch is drawn rather than expressed in SwiftUI.
    private static func swatch(_ color: GroupColor) -> NSImage {
        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(color.color).setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }

    /// The active group's colour, kept faint so the strip stays calm — it is a
    /// background tint, not a highlight.
    private var tint: Color {
        let group = store.activeGroup
        guard !group.isAll else { return .primary.opacity(isHovering ? 0.18 : 0.10) }
        return group.color.color.opacity(isHovering ? 0.32 : 0.20)
    }

    private func showMenu() {
        guard let anchor = controller.anchorView else { return }

        controller.onSelect = { store.selectGroup($0) }
        controller.onNewGroup = onNewGroup
        controller.onEditGroups = onEditGroups

        let menu = NSMenu()
        for group in store.groups {
            let item = NSMenuItem(
                title: group.name,
                action: #selector(SelectorMenuController.selectGroup(_:)),
                keyEquivalent: ""
            )
            item.target = controller
            item.representedObject = group.id
            item.state = (group.id == store.activeGroupID) ? .on : .off
            if !group.isAll {
                item.image = Self.swatch(group.color)
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let newItem = NSMenuItem(
            title: "New Group…",
            action: #selector(SelectorMenuController.newGroup),
            keyEquivalent: ""
        )
        newItem.target = controller
        menu.addItem(newItem)

        let editItem = NSMenuItem(
            title: "Edit Groups…",
            action: #selector(SelectorMenuController.editGroups),
            keyEquivalent: ""
        )
        editItem.target = controller
        menu.addItem(editItem)

        // Offsetting by the menu's own height makes it grow upward from the
        // button — a drop-up. Without this AppKit anchors the menu's top edge at
        // the point and then shoves it up to fit, which overlaps the strip.
        let origin = NSPoint(x: 0, y: anchor.bounds.height + 6 + menu.size.height)
        menu.popUp(positioning: nil, at: origin, in: anchor)
    }
}
