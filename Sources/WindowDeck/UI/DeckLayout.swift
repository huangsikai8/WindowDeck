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

    // MARK: - The cluster stack
    //
    // Its geometry is defined once and read by both the layout and `ClusterTile`,
    // for the same reason the overflow control's is: sizing the icon here against
    // one overlap and drawing it there against another is how a tile ends up with
    // its artwork adrift in a box measured for something else.

    /// Most icons a cluster tile draws. Beyond this the badge alone carries the
    /// count — a seventh icon in a tile of fixed width is a sliver of a sliver.
    static let clusterStackDepth = 6

    /// How far each further icon is stepped across, as a fraction of the icon, so
    /// the stack reads as depth rather than as a row.
    ///
    /// **Fixed, and the icon is what gives instead.** A cluster is charged
    /// `clusterWidthUnits` whatever it holds, so a deeper stack has to come out of
    /// something; taking it out of the overlap keeps the icons large and turns the
    /// back of a six-stack into a 3pt sliver, which is not a sixth application so
    /// much as a smear. Taking it out of the icon is what the user asked for and
    /// is also what keeps the *separation* legible: every icon shows the same
    /// 30% of itself however many there are.
    static let clusterOverlapStep: CGFloat = 0.30

    /// The stack travels up as well as across, and that is worth more than it
    /// looks. The tile is charged 1.4 entries and its icon band is nearly square,
    /// so a stack fanned along one axis leaves the other entirely unused — and it
    /// is the *unused* axis that a deep stack is starving for.
    ///
    /// Two things come out of it, and the second is the larger. The icon grows a
    /// little, because the step's length is now spread over two axes and costs
    /// less width apiece. And each icon behind the front one shows an **L** of
    /// itself — its right edge and its top — instead of a vertical strip of the
    /// same width, which at six members is 34% more of it visible for the same
    /// separation. Measured at 1.15x, against the horizontal fan this replaced:
    ///
    /// | members | icon | exposed per icon |
    /// |---|---|---|
    /// | 3 | 40.1 → 40.8 | +10% |
    /// | 4 | 33.2 → 34.6 | +21% |
    /// | 5 | 28.3 → 30.1 | +28% |
    /// | 6 | 24.7 → 26.7 | +34% |
    ///
    /// A stack of two degenerates back to a horizontal pair on its own and must
    /// not be special-cased into one: its icon reaches `preferredIconSize`, which
    /// leaves no vertical slack, and the rule below then hands it a rise of zero.

    /// The steepest the stack may lean, as a rise over the run — 0.36 is about
    /// 20°.
    ///
    /// Left to find its own angle the fan gets steeper as it deepens, because a
    /// deeper stack has to climb harder to make each step up to length: 16° at
    /// three members, 23° at four, 28° at six. That is both too steep to read as
    /// a row of icons and *inconsistent*, so two clusters of different sizes lean
    /// differently side by side. Capping it holds four, five and six members at a
    /// flat 20° apiece and costs about a point of icon at the deepest.
    static let clusterRiseSlope: CGFloat = 0.36

    /// The median measured icon ink ratio, against `inkHeadroom`'s worst case.
    ///
    /// The worst case is what guarantees nothing ever spills; the median is what
    /// the row actually *looks* like. So safety is derived from one and margins
    /// from the other, and using the worst case for both is what put a cluster's
    /// icons hard against the tile's own border — the no-spill ceiling is, by
    /// definition, the width at which the artwork touches the edge.
    static let medianInk: CGFloat = 0.844

    /// How many icons a cluster tile actually draws — its members, capped at the
    /// depth. Zero for anything that is not a cluster.
    ///
    /// The layout has to ask rather than assume the cap: the tile is one width at
    /// every depth, so the depth is the only thing that decides how much of it one
    /// icon may have.
    static func stackDepth(of item: DeckItem) -> Int {
        guard case .cluster(_, let members) = item else { return 0 }
        return max(1, min(members.count, clusterStackDepth))
    }

    /// The stack's extent along one axis, in points: `depth - 1` steps of `step`,
    /// plus one whole icon's artwork at the given ink ratio.
    static func clusterSpan(depth: Int, iconSize: CGFloat, ink: CGFloat,
                            step: CGFloat) -> CGFloat {
        CGFloat(depth - 1) * step + iconSize * ink
    }

    /// The share of its tile a plain entry's artwork occupies at the preferred
    /// size, and therefore the share a cluster's stack should take of its own.
    ///
    /// This is what makes a cluster sit on the row with the same margin as the
    /// tiles either side of it, at any scale and any depth, without a hand-tuned
    /// inset: a plain icon is a `preferredIconSize` frame in an `iconOnlyWidth`
    /// tile, of which `medianInk` is artwork — about 0.90 at every step of the
    /// slider.
    static func plainInkShare(_ metrics: DeckMetrics) -> CGFloat {
        metrics.preferredIconSize * medianInk / metrics.iconOnlyWidth
    }

    /// The room a cluster's stack has, across and up. Both are ink, not frames.
    ///
    /// Across, it is the share of the tile a plain icon's artwork takes of its own
    /// (`plainInkShare`), which is what gives a cluster the same margin as the
    /// tiles either side. Up, it is the icon band — but never less than a plain
    /// icon's own ink, because a plain tile fills 0.92 of that band and squeezing
    /// a cluster into 0.90 of it would make the deepest stack shorter than the
    /// single icon it is standing in for.
    static func clusterRoom(width: CGFloat, metrics: DeckMetrics) -> CGSize {
        let share = plainInkShare(metrics)
        let band = metrics.tileHeight - metrics.dotClearance
        return CGSize(width: width * share,
                      height: max(band * share, metrics.preferredIconSize * medianInk))
    }

    /// The largest icon whose whole stack still fits, in both directions at once.
    ///
    /// The stack is bounded twice — `(depth - 1)·dx + ink ≤ W` and
    /// `(depth - 1)·dy + ink ≤ H` — while the step itself must stay
    /// `clusterOverlapStep` of the icon *long*, since that is what keeps each
    /// icon's exposed corner the same fraction of itself however many there are.
    /// Both bounds are tight at the best icon, and the step's length is
    /// `sqrt(dx² + dy²)`, so the largest `i` is the one satisfying
    ///
    ///     (W - m·i)² + (H - m·i)² ≥ (c·i)²
    ///
    /// with `m = medianInk` and `c = (depth - 1)·clusterOverlapStep` — a quadratic
    /// in `i`, `(2m² - c²)i² - 2m(W + H)i + (W² + H²) ≥ 0`, whose first root is
    /// the answer. Solving it rather than picking an angle is what lets the fan
    /// flatten by itself as the stack gets shallower: a large icon has no vertical
    /// slack to spend, and a fixed angle would make a stack of three *smaller*
    /// than the horizontal fan it replaced.
    ///
    /// Capped at `ceiling`, which is **the plain tile's own icon**, not the
    /// preferred size. The vertical room does not shrink when the row fills up —
    /// only the tile's width does — so a crowded strip at 1.6x let the solver
    /// lean the whole step upward and grow a cluster's icons to 51pt beside 35pt
    /// neighbours, with its artwork spilling the tile. A cluster's icon may match
    /// the tiles either side of it and must never outgrow them, at any crowding.
    static func clusterIconSize(depth: Int, width: CGFloat, ceiling: CGFloat,
                                metrics: DeckMetrics) -> CGFloat {
        guard depth > 1 else { return ceiling }

        let room = clusterRoom(width: width, metrics: metrics)
        let m = medianInk
        let c = CGFloat(depth - 1) * clusterOverlapStep
        let a = 2 * m * m - c * c
        let b = -2 * m * (room.width + room.height)
        let k = room.width * room.width + room.height * room.height
        let discriminant = b * b - 4 * a * k

        // No real root with `a` positive: the stack is short enough that nothing
        // this tile could hold is bounded by it, so the preferred size governs.
        let bound = discriminant < 0
            ? ceiling                                   // `a` positive, no real root
            : (abs(a) < 0.0001
                ? k / -b                                // the step is exactly m√2
                : (-b - sqrt(discriminant)) / (2 * a))

        // And the lean, which binds instead once the stack is deep enough to want
        // a steeper one than `clusterRiseSlope` allows. With the angle fixed, the
        // step's horizontal share is fixed too — `cos` of it — so this is the flat
        // horizontal rule with a shorter effective stride, and no trigonometry.
        let run = 1 / (1 + clusterRiseSlope * clusterRiseSlope).squareRoot()
        let leaning = room.width / (m + c * run)

        return max(metrics.minimumIconSize, min(ceiling, bound, leaning))
    }

    /// How far apart the icons are drawn, across and up.
    ///
    /// **Across first, and always the whole way.** The stack spans exactly the
    /// room the tile allows, which is what gives every cluster the same margin as
    /// its neighbours at every depth. Only then, if that leaves the step shorter
    /// than `clusterOverlapStep` of the icon, does it climb — by just enough to
    /// make the step up to length, and no further.
    ///
    /// Spending *all* the leftover on both axes is the tempting version and is
    /// wrong: an icon held down by a ceiling has slack it does not need, and a
    /// crowded pair at 1.6x was drawn with a 29pt rise between two icons, fanned
    /// halfway up the tile for no reason. Slack in a direction is only worth
    /// taking while something still needs it.
    static func clusterStep(depth: Int, width: CGFloat, iconSize: CGFloat,
                            metrics: DeckMetrics) -> CGSize {
        guard depth > 1 else { return .zero }
        let room = clusterRoom(width: width, metrics: metrics)
        let ink = iconSize * medianInk
        let steps = CGFloat(depth - 1)

        let across = max(0, room.width - ink) / steps
        let wanted = iconSize * clusterOverlapStep
        guard across < wanted else { return CGSize(width: across, height: 0) }

        // No clamp to `clusterRiseSlope` here, and adding one would be misleading
        // rather than merely redundant: the *sizing* is what holds the angle, and
        // it holds it exactly. Where `leaning` is the bound that governs,
        // `across` works out to `wanted · cos` of the lean, so this climb is its
        // `sin` and the ratio is the slope on the nose; where a tighter bound
        // governs instead the icon is smaller, `across` larger and the lean
        // shallower still. A clamp would look like the thing enforcing the angle
        // while never once firing. `clusterIconsFillTheirTile` asserts the lean
        // against the drawn step, so it cannot come adrift unnoticed.
        let climb = (wanted * wanted - across * across).squareRoot()
        return CGSize(width: across,
                      height: min(climb, max(0, room.height - ink) / steps))
    }

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

        // What an ordinary tile in this row draws, and therefore the most a
        // cluster in it may draw. Taken from the untitled base width, since a
        // cluster never shows a title.
        let plainIcon = iconSize(forEntryWidth: baseWidth, showsTitle: false,
                                 metrics: metrics)

        let slots = zip(items, showTitles).map { item, showsTitle -> Slot in
            let width: CGFloat = showsTitle
                ? titledWidth
                : (item.isCluster ? baseWidth * clusterWidthUnits : baseWidth)
            let depth = stackDepth(of: item)
            return Slot(
                item: item,
                width: width,
                showsTitle: showsTitle,
                iconSize: depth > 0
                    ? clusterIconSize(depth: depth, width: width,
                                      ceiling: plainIcon, metrics: metrics)
                    : iconSize(forEntryWidth: width, showsTitle: showsTitle,
                               metrics: metrics)
            )
        }

        let contentWidth = slots.reduce(0) { $0 + $1.width } + gaps
        return Result(slots: slots, spacing: spacing,
                      totalWidth: min(chrome + contentWidth, maxWidth))
    }

    /// Icons hold their preferred size until the tile is too narrow to contain
    /// them, then shrink with it. A cluster's icons are smaller than a plain
    /// entry's — several are stacked inside one tile — but only by as much as
    /// the stacking actually costs.
    private static func iconSize(
        forEntryWidth width: CGFloat,
        showsTitle: Bool,
        metrics: DeckMetrics
    ) -> CGFloat {
        guard !showsTitle else { return metrics.preferredIconSize }
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
