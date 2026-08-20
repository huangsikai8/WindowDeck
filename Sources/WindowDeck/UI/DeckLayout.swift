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
        /// Which capsule this slot was drawn for.
        var sectionID: String?
        /// The section takes part in the identity because a launcher can be
        /// pinned in more than one capsule, so the same item id genuinely
        /// appears twice in the row. Two views sharing one identity is what
        /// rendered the switcher rotated with two highlights the last time it
        /// happened, so this stays even though windows are now drawn once.
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
    ///
    /// It tracks `preferredIconSize`: a titled tile spends its width on padding
    /// (7 a side), the icon and the 6pt gap before the text, so raising the icon
    /// without raising this leaves literally no room for the title it is
    /// supposed to be guaranteeing.
    static let minimumTitledWidth: CGFloat = 64
    /// Absolute floor. Only reached on a genuinely extreme strip; the fair share
    /// governs long before this does.
    static let hardMinimumWidth: CGFloat = 14
    /// Close to `iconOnlyWidth` on purpose. The Dock's tile is very nearly all
    /// icon, and matching that is the only way to draw a Dock-sized icon without
    /// a Dock-sized tile — the margins are the thing that was making the strip
    /// look like a row of thumbnails. What is left, 2pt a side at full width, is
    /// the separation between neighbouring icons and nothing more.
    static let preferredIconSize: CGFloat = 36
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
    // The overflow control's geometry, defined once and read by both the layout
    // and the view. Estimating it here and drawing something else there made the
    // panel wider than its contents, and the surplus showed as dead space on the
    // right that the left edge did not have.
    static let collapsedPadding: CGFloat = 8
    static let collapsedDotSize: CGFloat = 11
    /// Each further dot overlaps its neighbour, so folding six groups costs about
    /// a tile rather than six.
    static let collapsedDotStep: CGFloat = 7
    static let collapsedGap: CGFloat = 5

    /// Sized to the digits actually shown rather than reserving room for three.
    /// A fixed slot left the number floating away from the dots with a gap on
    /// both sides — the count is the last thing in the control, so any surplus
    /// reads as the whole thing being badly spaced.
    static func collapsedCountWidth(_ total: Int) -> CGFloat {
        CGFloat(String(total).count) * 7 + 2
    }

    static func collapsedControlWidth(groups: Int, windows: Int) -> CGFloat {
        collapsedPadding * 2
            + collapsedDotSize + CGFloat(max(groups - 1, 0)) * collapsedDotStep
            + collapsedGap + collapsedCountWidth(windows)
    }

    static func compute(
        items: [DeckItem],
        pinnedCount: Int,
        titlesEnabled: Bool,
        maxWidth: CGFloat,
        pillCount: Int = 0,
        collapsedCount: Int = 0,
        collapsedWindows: Int = 0,
        sectionCount: Int = 1,
        dividerCount: Int = 0
    ) -> Result {

        let spacing = spacing(forCount: items.count)
        // Gaps *within* sections. The row draws one between neighbouring items in
        // the same section and one between sections — counting N-1 of the former
        // double-counts the joins, and since the row is leading-aligned the
        // surplus became dead space on the right that the left edge did not have.
        let sections = max(sectionCount, 1)
        let interSectionGaps = CGFloat(sections - 1) * spacing
        // The ghost entry is preceded by a separator, which costs width like
        // anything else — unaccounted, it pushes the row past the edge.
        // Each separator costs width like anything else — unaccounted, the row
        // runs past the strip's edge and the last icons clip.
        let dividerChrome = CGFloat(dividerCount) * (DeckMetrics.dividerWidth + spacing)
        // Each capsule costs its own padding on both sides plus the gap to its
        // neighbour. Unaccounted, a bucketed All runs past the strip's edge —
        // the same failure separators caused before they were charged for.
        // Only the capsules' own padding: the gaps between them are counted once,
        // above, as inter-section gaps.
        let pillChrome = CGFloat(pillCount) * (pillInset * 2)
        // The overflow cluster and the rule before it are chrome like anything
        // else — uncharged, the row runs past the strip's edge.
        let overflowChrome = collapsedCount > 0
            ? collapsedControlWidth(groups: collapsedCount, windows: collapsedWindows)
                + DeckMetrics.dividerWidth + spacing * 2
            : 0
        let chrome = chromeWidth(pinnedCount: pinnedCount, spacing: spacing)
            + dividerChrome + pillChrome + overflowChrome + interSectionGaps

        guard !items.isEmpty else {
            return Result(slots: [], spacing: spacing,
                          totalWidth: min(chrome + DeckMetrics.emptyHintWidth, maxWidth))
        }
        guard maxWidth > chrome else {
            return Result(slots: [], spacing: spacing, totalWidth: maxWidth)
        }

        // An app is "crowded" when more than one of its windows is loose on the
        // strip. Clustered and stacked windows don't count — they aren't
        // competing for recognition, they're already behind one icon. Stacks get
        // this for free by no longer being `.window` items, which is also what
        // stops a stacked app forcing titles onto its own single loose window in
        // some other group.
        var windowsPerApp: [pid_t: Int] = [:]
        for case .window(let window) in items {
            windowsPerApp[window.pid, default: 0] += 1
        }

        let wantsTitle: [Bool] = items.map { item in
            guard case .window(let window) = item else { return false }
            return titlesEnabled && (windowsPerApp[window.pid] ?? 0) > 1
        }
        let titledCount = wantsTitle.filter { $0 }.count

        let gaps = CGFloat(max(items.count - sections, 0)) * spacing
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
