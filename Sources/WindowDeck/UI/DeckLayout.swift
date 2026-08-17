import AppKit

/// Works out how wide each item gets.
///
/// Three rules drive this:
///
/// 1. A title only earns space when it disambiguates. An app with a single open
///    window is fully identified by its icon, so it renders icon-only. An app
///    with several windows shows titles, because that's the only way to tell
///    `Report.docx` from `Notes.docx`.
/// 2. The strip never scrolls. Everything visible fits in one bar, so titled
///    entries share whatever width is left and truncate as needed.
/// 3. **Crowding tightens rather than overflows.** As items multiply, spacing
///    closes up and tiles shrink — the way the Dock does it. Widths are never
///    clamped *up* to a floor: doing that is what made a busy strip spill past
///    its own edge and clip the last icons.
enum DeckLayout {

    struct Slot: Identifiable {
        let item: DeckItem
        let width: CGFloat
        let showsTitle: Bool
        let iconSize: CGFloat
        /// Which pill this slot was drawn for, or nil outside pill view.
        var sectionID: String?
        /// The section takes part in the identity because pill view draws the
        /// same window once per group it belongs to. Without it those copies
        /// share one id, and SwiftUI cannot reconcile two views claiming to be
        /// the same thing — which is what rendered the switcher rotated with two
        /// highlights the last time it happened.
        var id: String { sectionID.map { "\($0)/\(item.id)" } ?? item.id }
    }

    struct Result {
        let slots: [Slot]
        /// Gap between items, which narrows as the strip fills.
        let spacing: CGFloat
        /// Width the panel should adopt — natural size when everything fits,
        /// clamped to the display when it doesn't.
        let totalWidth: CGFloat
    }

    static let iconOnlyWidth: CGFloat = 40
    static let preferredTitledWidth: CGFloat = 150
    /// Below this a title is just an ellipsis, so entries collapse to icon-only
    /// instead — the same thing Chrome does when tabs get too narrow.
    static let minimumTitledWidth: CGFloat = 58
    /// Absolute floor. Only reached on a genuinely extreme strip; the fair share
    /// governs long before this does.
    static let hardMinimumWidth: CGFloat = 14
    static let preferredIconSize: CGFloat = 30
    static let minimumIconSize: CGFloat = 10
    static let preferredSpacing: CGFloat = 6

    /// A cluster is charged this many entry-widths. Expressing it as a multiple
    /// rather than a fixed size is what keeps the exact-fit guarantee: whatever
    /// the fair share works out to, a cluster stays proportionally wider and the
    /// row still totals the space available.
    static let clusterWidthUnits: CGFloat = 1.4

    /// Gaps close up before tiles start shrinking — the same order of sacrifice
    /// the Dock makes, and it buys a surprising amount of room.
    static func spacing(forCount count: Int) -> CGFloat {
        switch count {
        case ..<16: preferredSpacing
        case ..<24: 4
        case ..<32: 3
        default: 2
        }
    }

    /// Width a capsule adds around its contents, per side.
    static let pillInset: CGFloat = 5

    static func compute(
        items: [DeckItem],
        pinnedCount: Int,
        titlesEnabled: Bool,
        maxWidth: CGFloat,
        pillCount: Int = 0
    ) -> Result {

        let spacing = spacing(forCount: items.count)
        // The ghost entry is preceded by a separator, which costs width like
        // anything else — unaccounted, it pushes the row past the edge.
        // Each separator costs width like anything else — unaccounted, the row
        // runs past the strip's edge and the last icons clip.
        var ghostChrome: CGFloat = 0
        if items.contains(where: \.isGhost) { ghostChrome += DeckMetrics.dividerWidth + spacing }
        if items.contains(where: \.isUngrouped) { ghostChrome += DeckMetrics.dividerWidth + spacing }
        // Each capsule costs its own padding on both sides plus the gap to its
        // neighbour. Unaccounted, a bucketed All runs past the strip's edge —
        // the same failure separators caused before they were charged for.
        let pillChrome = CGFloat(pillCount) * (pillInset * 2 + spacing)
        let chrome = chromeWidth(pinnedCount: pinnedCount, spacing: spacing)
            + ghostChrome + pillChrome

        guard !items.isEmpty else {
            return Result(slots: [], spacing: spacing,
                          totalWidth: min(chrome + DeckMetrics.emptyHintWidth, maxWidth))
        }
        guard maxWidth > chrome else {
            return Result(slots: [], spacing: spacing, totalWidth: maxWidth)
        }

        // An app is "crowded" when more than one of its windows is loose on the
        // strip. Clustered windows don't count — they aren't competing for
        // recognition, they're already behind one icon.
        var windowsPerApp: [pid_t: Int] = [:]
        for case .window(let window) in items {
            windowsPerApp[window.pid, default: 0] += 1
        }

        let wantsTitle: [Bool] = items.map { item in
            guard case .window(let window) = item else { return false }
            return titlesEnabled && (windowsPerApp[window.pid] ?? 0) > 1
        }
        let titledCount = wantsTitle.filter { $0 }.count

        let gaps = CGFloat(items.count - 1) * spacing
        let available = maxWidth - chrome - gaps

        // Total cost in entry-widths, with clusters charged more.
        let units = items.reduce(CGFloat(0)) { $0 + ($1.isCluster ? clusterWidthUnits : 1) }
        let fairUnit = min(iconOnlyWidth, available / max(units, 1))

        var titledWidth = preferredTitledWidth
        var baseWidth = fairUnit
        var showTitles = wantsTitle

        if titledCount > 0 {
            let untitledUnits = zip(items, wantsTitle).reduce(CGFloat(0)) { total, pair in
                pair.1 ? total : total + (pair.0.isCluster ? clusterWidthUnits : 1)
            }
            let fairTitled = (available - untitledUnits * iconOnlyWidth) / CGFloat(titledCount)

            if fairTitled < minimumTitledWidth {
                // Not enough room to say anything useful — drop to icon-only
                // across the board rather than render a row of ellipses.
                showTitles = Array(repeating: false, count: items.count)
                baseWidth = fairUnit
            } else {
                titledWidth = min(preferredTitledWidth, fairTitled)
                baseWidth = iconOnlyWidth
            }
        }

        baseWidth = max(hardMinimumWidth, baseWidth)

        let slots = zip(items, showTitles).map { item, showsTitle -> Slot in
            let width: CGFloat = showsTitle
                ? titledWidth
                : (item.isCluster ? baseWidth * clusterWidthUnits : baseWidth)
            return Slot(
                item: item,
                width: width,
                showsTitle: showsTitle,
                iconSize: iconSize(forEntryWidth: width, showsTitle: showsTitle, isCluster: item.isCluster)
            )
        }

        let contentWidth = slots.reduce(0) { $0 + $1.width } + gaps
        return Result(slots: slots, spacing: spacing,
                      totalWidth: min(chrome + contentWidth, maxWidth))
    }

    /// Icons hold their preferred size until the tile is too narrow to contain
    /// them, then shrink with it. Cluster icons are smaller — several are
    /// stacked inside one tile.
    private static func iconSize(
        forEntryWidth width: CGFloat,
        showsTitle: Bool,
        isCluster: Bool
    ) -> CGFloat {
        guard !showsTitle else { return preferredIconSize }
        if isCluster {
            return max(minimumIconSize, min(preferredIconSize - 4, width * 0.42))
        }
        return max(minimumIconSize, min(preferredIconSize, width - 4))
    }

    /// Everything that isn't an item: padding, selector, dividers, pins.
    private static func chromeWidth(pinnedCount: Int, spacing: CGFloat) -> CGFloat {
        let pinned = pinnedCount == 0
            ? 0
            : CGFloat(pinnedCount) * DeckMetrics.pinnedTileWidth
                + CGFloat(pinnedCount - 1) * 2
                + spacing * 2
                + DeckMetrics.dividerWidth

        return DeckMetrics.padding * 2
            + DeckMetrics.selectorWidth
            + spacing * 2
            + DeckMetrics.dividerWidth
            + pinned
    }
}
