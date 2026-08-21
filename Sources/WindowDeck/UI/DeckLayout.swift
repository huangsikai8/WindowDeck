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
///
/// Every size it works from comes in as `DeckMetrics`, so the user's size
/// setting needs nothing here: a bigger tile simply reaches the point where the
/// row tightens sooner, which is rule 3 doing its job rather than a special case.
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

    /// A cluster is charged this many entry-widths. Expressing it as a multiple
    /// rather than a fixed size is what keeps the exact-fit guarantee: whatever
    /// the fair share works out to, a cluster stays proportionally wider and the
    /// row still totals the space available. It is scale-free for the same
    /// reason, which is why it lives here and not in `DeckMetrics`.
    static let clusterWidthUnits: CGFloat = 1.4

    /// The widest measured icon ink ratio, inverted: multiplying a tile's width by
    /// this gives the largest icon *frame* whose artwork is still guaranteed to
    /// fit that width, for any application on the machine.
    ///
    /// A ratio, so it is scale-free by construction and lives here rather than in
    /// `DeckMetrics` — for the same reason `clusterWidthUnits` does. Scaling it
    /// would apply the scale twice.
    static let inkHeadroom: CGFloat = 1.11

    /// Gaps close up before tiles start shrinking — the same order of sacrifice
    /// the Dock makes, and it buys a surprising amount of room. The tightened
    /// steps are fractions of the preferred gap rather than fixed points, so a
    /// larger strip closes up by the same proportion instead of slamming shut.
    static func spacing(forCount count: Int, metrics: DeckMetrics) -> CGFloat {
        let preferred = metrics.preferredSpacing
        switch count {
        case ..<16: return preferred
        case ..<24: return max(1, (preferred * 4 / 6).rounded())
        case ..<32: return max(1, (preferred * 3 / 6).rounded())
        default: return max(1, (preferred * 2 / 6).rounded())
        }
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
        dividerCount: Int = 0,
        metrics: DeckMetrics = DeckMetrics()
    ) -> Result {

        let spacing = spacing(forCount: items.count, metrics: metrics)
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
        let dividerChrome = CGFloat(dividerCount) * (metrics.dividerWidth + spacing)
        // Each capsule costs its own padding on both sides plus the gap to its
        // neighbour. Unaccounted, a bucketed All runs past the strip's edge —
        // the same failure separators caused before they were charged for.
        // Only the capsules' own padding: the gaps between them are counted once,
        // above, as inter-section gaps.
        let pillChrome = CGFloat(pillCount) * (metrics.pillInset * 2)
        // The overflow cluster and the rule before it are chrome like anything
        // else — uncharged, the row runs past the strip's edge.
        let overflowChrome = collapsedCount > 0
            ? metrics.collapsedControlWidth(groups: collapsedCount, windows: collapsedWindows)
                + metrics.dividerWidth + spacing * 2
            : 0
        let chrome = chromeWidth(pinnedCount: pinnedCount, spacing: spacing, metrics: metrics)
            + dividerChrome + pillChrome + overflowChrome + interSectionGaps

        guard !items.isEmpty else {
            return Result(slots: [], spacing: spacing,
                          totalWidth: min(chrome + metrics.emptyHintWidth, maxWidth))
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
        let fairUnit = min(metrics.iconOnlyWidth, available / max(units, 1))

        var titledWidth = metrics.preferredTitledWidth
        var baseWidth = fairUnit
        var showTitles = wantsTitle

        if titledCount > 0 {
            let untitledUnits = zip(items, wantsTitle).reduce(CGFloat(0)) { total, pair in
                pair.1 ? total : total + (pair.0.isCluster ? clusterWidthUnits : 1)
            }
            let fairTitled = (available - untitledUnits * metrics.iconOnlyWidth) / CGFloat(titledCount)

            if fairTitled < metrics.minimumTitledWidth {
                // Not enough room to say anything useful — drop to icon-only
                // across the board rather than render a row of ellipses.
                showTitles = Array(repeating: false, count: items.count)
                baseWidth = fairUnit
            } else {
                titledWidth = min(metrics.preferredTitledWidth, fairTitled)
                baseWidth = metrics.iconOnlyWidth
            }
        }

        baseWidth = max(metrics.hardMinimumWidth, baseWidth)

        let slots = zip(items, showTitles).map { item, showsTitle -> Slot in
            let width: CGFloat = showsTitle
                ? titledWidth
                : (item.isCluster ? baseWidth * clusterWidthUnits : baseWidth)
            return Slot(
                item: item,
                width: width,
                showsTitle: showsTitle,
                iconSize: iconSize(forEntryWidth: width, showsTitle: showsTitle,
                                   isCluster: item.isCluster, metrics: metrics)
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
        isCluster: Bool,
        metrics: DeckMetrics
    ) -> CGFloat {
        guard !showsTitle else { return metrics.preferredIconSize }
        if isCluster {
            return max(metrics.minimumIconSize,
                       min(metrics.clusterIconCap, width * 0.42))
        }
        // Bounds the ink, not the frame. A macOS icon is drawn into a canvas that
        // is ~15% transparent margin — measured across all 133 applications on
        // this machine, the alpha bounding box is a median 0.844 of the frame and
        // at most 0.898 — so sizing the *frame* to the tile leaves the artwork
        // far smaller than the space it was given.
        //
        // `width * inkHeadroom` is the largest frame whose artwork still fits: at
        // the worst measured ratio, ink = 0.898 * 1.11 * width = 0.997 * width,
        // which holds at every width down to `hardMinimumWidth`.
        //
        // This is *not* the "clamping a width up causes overflow" trap, and the
        // distinction matters: no width is being clamped at all. Every slot keeps
        // exactly the width `compute` gave it and the row's total is unchanged.
        // What grows is the image drawn inside a slot, over margins that are
        // transparent either way.
        return max(metrics.minimumIconSize,
                   min(metrics.preferredIconSize, width * inkHeadroom))
    }

    /// Everything that isn't an item: padding, selector, dividers, pins.
    private static func chromeWidth(pinnedCount: Int, spacing: CGFloat,
                                    metrics: DeckMetrics) -> CGFloat {
        let pinned = pinnedCount == 0
            ? 0
            : CGFloat(pinnedCount) * metrics.pinnedTileWidth
                + CGFloat(pinnedCount - 1) * 2
                + spacing * 2
                + metrics.dividerWidth

        return metrics.padding * 2
            + metrics.selectorWidth
            + spacing * 2
            + metrics.dividerWidth
            + pinned
    }
}
