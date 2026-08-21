import AppKit
import SwiftUI

/// Holds a reference to a real `NSView` so the menu has something to pop up
/// from, and acts as the target for menu item actions (SwiftUI structs can't be
/// Objective-C targets).
@MainActor
final class SelectorMenuController: NSObject {
    weak var anchorView: NSView?
    var onToggleCollapsed: ((UUID) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onNewGroup: (() -> Void)?
    var onEditGroups: (() -> Void)?

    @objc func toggleCollapsed(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onToggleCollapsed?(id)
    }

    @objc func deleteGroup(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onDelete?(id)
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

/// The groups control at the left of the strip.
///
/// It no longer *switches* anything — every group is on the bar at once — so it
/// is a menu for managing them rather than a selector with a current value. That
/// is also why it is narrow now: the row it used to label is the whole strip,
/// and the space is better spent on windows.
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

    /// Sizes come from the strip that is drawing this tile, so every tile in the
    /// row is built from the same scale the layout pass measured with.
    @Environment(\.deckMetrics) private var metrics

    var body: some View {
        // Icon over count, not side by side: the strip is 56pt tall and 40pt
        // wide per tile, so stacking keeps this the same width as everything
        // else in the row rather than stealing space from the windows.
        //
        // The two sit directly on top of each other with no gap, and both are
        // drawn as large as that leaves room for. A 12pt glyph with a 10pt
        // number spaced off it filled about half the tile's height, so this
        // button read as a smaller, fainter thing than the icons beside it while
        // the space it needed was already reserved. Nothing here got wider.
        VStack(spacing: -1) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: metrics.selectorGlyphSize, weight: .medium))
                .foregroundStyle(.secondary)
            // How many windows the strip is showing in total — the one number
            // that is not visible anywhere else, since each capsule shows only
            // its own and a busy session runs to dozens.
            Text("\(store.windows.count)")
                .font(.system(size: metrics.selectorCountSize, weight: .semibold))
                // Monospaced so the button does not twitch as windows open and
                // close, which it does several times a minute.
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(width: metrics.selectorWidth, height: metrics.tileHeight)
        .background(
            RoundedRectangle(cornerRadius: metrics.tileCornerRadius, style: .continuous)
                .fill(.primary.opacity(isHovering ? 0.18 : 0.10))
        )
        .background(MenuAnchorView(controller: controller))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { showMenu() }
        .help("\(store.windows.count) windows in \(store.groups.count) groups")
    }

    /// A small colour dot for the menu. NSMenu takes an NSImage, so the swatch is
    /// drawn rather than expressed in SwiftUI.
    private static func swatch(_ color: Color) -> NSImage {
        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(color).setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }

    private func showMenu() {
        guard let anchor = controller.anchorView else { return }

        controller.onToggleCollapsed = { id in
            guard let group = store.groups.first(where: { $0.id == id }) else { return }
            store.setCollapsed(!group.isCollapsed, for: id)
        }
        controller.onDelete = { store.deleteGroup($0) }
        controller.onNewGroup = onNewGroup
        controller.onEditGroups = onEditGroups

        let menu = NSMenu()
        for group in store.groups {
            let item = NSMenuItem(title: group.name, action: nil, keyEquivalent: "")
            item.image = Self.swatch(group.displayColor)
            // The native badge, the same right-aligned pill Apple uses for unread
            // counts. It aligns and dims itself, which hand-built tab stops in an
            // attributed title do not.
            // Built from a string rather than a count: `NSMenuItemBadge(count:)`
            // suppresses a zero, and an empty group showing nothing is
            // indistinguishable from a group whose badge failed to appear.
            item.badge = NSMenuItemBadge(string: "\(store.windowCount(of: group))")

            // Main is the fallback: it cannot be folded away or deleted, because
            // every window nothing else claims is drawn in it.
            if !group.isMain {
                let submenu = NSMenu()

                let fold = NSMenuItem(
                    title: group.isCollapsed ? "Expand" : "Collapse",
                    action: #selector(SelectorMenuController.toggleCollapsed(_:)),
                    keyEquivalent: ""
                )
                fold.target = controller
                fold.representedObject = group.id
                submenu.addItem(fold)

                submenu.addItem(.separator())

                let remove = NSMenuItem(
                    title: "Delete Group",
                    action: #selector(SelectorMenuController.deleteGroup(_:)),
                    keyEquivalent: ""
                )
                remove.target = controller
                remove.representedObject = group.id
                submenu.addItem(remove)

                item.submenu = submenu
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
