import AppKit
import SwiftUI

/// The whole bar, folded groups included, on a row above the strip.
///
/// Opened by pressing the overflow cluster. Deliberately not an expansion of the
/// strip itself: opening one in place would push every other capsule sideways,
/// so the tile you were reaching for moves as you reach for it. A separate row
/// leaves the strip exactly where it was.
///
/// One row per group rather than a literal copy of the strip. The strip is one
/// line because it must never scroll; this panel has no such constraint, and a
/// group per line is far easier to read than the same content squeezed edge to
/// edge.
@MainActor
final class AllGroupsPanel {

    private let panel: NSPanel
    private let hosting: NSHostingView<AllGroupsContent>
    let model = AllGroupsModel()

    /// Raise this window and close.
    var onSelect: ((WindowInfo) -> Void)?
    /// Bring a folded group back into the strip.
    var onExpand: ((UUID) -> Void)?

    private var dismissMonitors: [Any] = []

    init() {
        hosting = NSHostingView(rootView: AllGroupsContent(model: model))
        hosting.sizingOptions = []

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 200),
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
        panel.animationBehavior = .none
        panel.contentView = hosting

        model.onSelect = { [weak self] window in
            self?.hide()
            self?.onSelect?(window)
        }
        model.onExpand = { [weak self] groupID in
            self?.hide()
            self?.onExpand?(groupID)
        }
    }

    var isVisible: Bool { panel.isVisible }

    /// Rises from `anchor`, the strip's own frame.
    func show(anchor: NSRect) {
        let rows = max(model.groups.count, 1)
        let width = min(max(420, model.widestRowWidth), (NSScreen.main?.frame.width ?? 1280) - 80)
        let height = CGFloat(rows) * AllGroupsModel.rowHeight + 20
        panel.setContentSize(NSSize(width: width, height: height))

        var origin = NSPoint(x: anchor.maxX - width, y: anchor.maxY + 8)
        if let screen = NSScreen.main {
            origin.x = max(screen.visibleFrame.minX + 8, origin.x)
            origin.y = min(origin.y, screen.visibleFrame.maxY - height - 8)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        watchForDismissal()
    }

    func hide() {
        stopWatching()
        panel.orderOut(nil)
    }

    /// Closes on a click anywhere else, the way a menu does. The panel ignores
    /// nothing itself, so clicks *inside* it are handled before this sees them.
    private func watchForDismissal() {
        stopWatching()
        let handler: (NSEvent) -> Void = { [weak self] _ in self?.hide() }
        if let m = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
            dismissMonitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { self?.hide() }   // Escape
            return event
        } {
            dismissMonitors.append(m)
        }
    }

    private func stopWatching() {
        for monitor in dismissMonitors { NSEvent.removeMonitor(monitor) }
        dismissMonitors.removeAll()
    }
}

@MainActor
@Observable
final class AllGroupsModel {
    struct Row: Identifiable {
        let id: UUID
        let name: String
        let color: Color
        let isCollapsed: Bool
        let windows: [WindowInfo]
    }

    static let rowHeight: CGFloat = 40

    var groups: [Row] = []
    @ObservationIgnored var onSelect: ((WindowInfo) -> Void)?
    @ObservationIgnored var onExpand: ((UUID) -> Void)?

    /// Enough for the busiest row, so nothing is clipped.
    var widestRowWidth: CGFloat {
        let labels = groups.map { row -> CGFloat in
            let name = (row.name as NSString)
                .size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width
            return 190 + name + CGFloat(row.windows.count) * 34
        }
        return (labels.max() ?? 420) + 40
    }
}

private struct AllGroupsContent: View {
    @Bindable var model: AllGroupsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.groups) { row in
                HStack(spacing: 8) {
                    Circle().fill(row.color).frame(width: 8, height: 8)
                    Text(row.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .frame(width: 110, alignment: .leading)

                    // The same count the drop-up shows, in the same right-aligned
                    // pill, so the two ways of listing groups agree.
                    Text("\(row.windows.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 18)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.primary.opacity(0.08)))

                    ForEach(row.windows) { window in
                        Button {
                            model.onSelect?(window)
                        } label: {
                            if let icon = window.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 26, height: 26)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(window.displayTitle)
                    }

                    Spacer(minLength: 8)

                    // Only a folded group offers this; an expanded one is already
                    // in the strip.
                    if row.isCollapsed {
                        Button("Show in bar") { model.onExpand?(row.id) }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: AllGroupsModel.rowHeight)
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VisualEffectBackground(material: .menu))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.primary.opacity(0.10), lineWidth: 1)
        )
    }
}
