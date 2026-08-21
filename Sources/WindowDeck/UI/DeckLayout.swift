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
    /// supposed to be guaranteeing. Raised with the icon, by exactly the icon's
    /// growth, so the text allowance at the collapse threshold is unchanged.
    static let minimumTitledWidth: CGFloat = 71
    /// Absolute floor. Only reached on a genuinely extreme strip; the fair share
    /// governs long before this does.
    static let hardMinimumWidth: CGFloat = 14
    /// Deliberately *larger* than `iconOnlyWidth`, and that is not a mistake.
    ///
    /// A macOS application icon is drawn into a canvas that is mostly artwork but
    /// not entirely: measured across all 133 apps on this machine, the alpha
    /// bounding box is a median **0.844** of the frame and never more than
    /// **0.898** (Adobe Digital Editions; Safari 0.891). So roughly 15% of every
    /// icon frame is guaranteed-transparent margin the icon brings with it.
    ///
    /// The previous round of this work set the icon 4pt under the tile so that
    /// "what is left is the separation between neighbouring icons and nothing
    /// more". That reasoning is right and the number was wrong, because it
    /// treated the frame as fully inked. The real gap between two neighbours'
    /// *artwork* was 2 (tile margin) + ~3 (icon margin) + 6 (spacing) + ~3 + 2 =
    /// ~16.6pt — wider in absolute points than the Dock's ~9.9pt, while drawing
    /// icons a third the size. That is what made the row read as small icons
    /// floating in space, and no amount of bar height would have explained it.
    ///
    /// The frame therefore overhangs its tile and only the *ink* is bounded — see
    /// `iconSize`. Nothing clips, so the overhang costs nothing; it is transparent
    /// either way.
    static let preferredIconSize: CGFloat = 43
    /// The widest measured ink ratio, inverted. Multiplying a tile's width by this
    /// gives the largest icon *frame* whose artwork is still guaranteed to fit
    /// inside that width, for any application on the machine.
    static let inkHeadroom: CGFloat = 1.11
    /// Clusters stack several icons in one tile, so they stay at the size they
    /// were before the icon grew — pinned to a number rather than derived from
    /// `preferredIconSize`, which would have silently enlarged them too.
    static let clusterIconCap: CGFloat = 32
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
            return max(minimumIconSize, min(clusterIconCap, width * 0.42))
        }
        // Bounds the ink, not the frame. `width * inkHeadroom` is the largest
        // frame whose artwork still fits the tile: at the worst measured ratio,
        // ink = 0.898 * 1.11 * width = 0.997 * width, which holds at every width
        // down to `hardMinimumWidth`.
        //
        // This is *not* the "clamping a width up causes overflow" trap, and the
        // distinction matters: no width is being clamped at all. Every slot keeps
        // exactly the width `compute` gave it, and the row's total is unchanged.
        // What grows is the image drawn inside a slot, over margins that are
        // transparent.
        return max(minimumIconSize, min(preferredIconSize, width * inkHeadroom))
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
