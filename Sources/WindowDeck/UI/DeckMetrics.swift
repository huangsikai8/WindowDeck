import AppKit
import SwiftUI

/// Every size the strip draws with, derived from one number.
///
/// The Dock has a single size slider and everything about it follows: a bigger
/// tile means a bigger icon, a taller bar and a longer row, and once the row
/// runs out of screen it tightens instead of overflowing. This copies that
/// shape, because the alternative — separate controls for height, tile and icon
/// — lets the three be set to combinations that cannot look right, and the
/// relationships between them are the whole reason the strip reads as a Dock.
///
/// It is a value rather than a namespace of constants so there is no global to
/// keep in step with the store: whoever draws or measures the strip builds one
/// from `AppStore.deckScale`, and SwiftUI redraws because reading that property
/// is an observed access. Two views measuring different metrics is exactly the
/// failure that makes the panel disagree with its own contents and clip the last
/// icons.
///
/// **Ratios do not live here.** `DeckLayout.clusterWidthUnits` is a multiple of
/// whatever the fair share works out to, so it is scale-free by construction and
/// scaling it would be applying the scale twice.
struct DeckMetrics: Equatable {

    /// The range the slider offers. The floor is where a 36pt icon becomes a
    /// 25pt one — below that the row stops being readable at a glance, which is
    /// the only thing the strip is for. The ceiling is where a busy strip starts
    /// tightening on a 13" display, so going further buys size by losing windows.
    static let minScale: CGFloat = 0.7
    static let maxScale: CGFloat = 1.6
    static let defaultScale: CGFloat = 1

    /// Always within `minScale...maxScale`. A value read from disk has been
    /// through `lenient`, which degrades a bad *shape* to the default but says
    /// nothing about range — so a hand-edited 40 would otherwise produce a strip
    /// taller than the screen, with the slider that fixes it off the bottom of it.
    let scale: CGFloat

    init(scale: CGFloat = DeckMetrics.defaultScale) {
        self.scale = DeckMetrics.clamped(scale)
    }

    static func clamped(_ scale: CGFloat) -> CGFloat {
        min(max(scale, minScale), maxScale)
    }

    /// Rounded to whole points, so tiles and their contents land on pixel
    /// boundaries rather than each picking up its own half-point of blur.
    private func whole(_ base: CGFloat) -> CGFloat { (base * scale).rounded() }
    /// Left unrounded: a 1.5pt inset or an 11.5pt font rounds away entirely at
    /// the small end, and these are the values that were tuned by eye.
    private func exact(_ base: CGFloat) -> CGFloat { base * scale }

    // MARK: - The strip

    var height: CGFloat { whole(56) }
    var cornerRadius: CGFloat { whole(16) }
    var padding: CGFloat { whole(10) }

    /// 44 inside a 56pt strip: the icon carries the information, so the bar
    /// should not be mostly padding. Neither number may grow *relative to the
    /// other* to make icons bigger — the way the Dock gets a large icon is not a
    /// large tile, it is a tile that is almost entirely icon, so growth within a
    /// scale comes out of this tile's own slack. Growing both together is what
    /// the scale is for.
    var tileHeight: CGFloat { whole(44) }
    var pinnedTileWidth: CGFloat { whole(40) }
    var tileSpacing: CGFloat { whole(6) }
    var tileCornerRadius: CGFloat { whole(8) }
    /// The groups button. Narrow because it no longer names a current group —
    /// there is nothing to switch, so it is a menu and not a selector.
    var selectorWidth: CGFloat { whole(40) }
    var selectorGlyphSize: CGFloat { exact(17) }
    var selectorCountSize: CGFloat { exact(11) }

    /// Status dots — group membership on a window tile, running state on a
    /// launcher. Shared so the two kinds line up along the bottom of the row.
    var statusDotSize: CGFloat { exact(4) }
    var statusDotInset: CGFloat { exact(1.5) }
    /// Space kept clear at the bottom of a tile for the dot, so the icon can
    /// take everything above it.
    ///
    /// Centring the icon in the whole tile is what wasted the room: it split the
    /// slack evenly top and bottom and then the dot had to be drawn *over* the
    /// bottom half of it, so the icon could never grow into either. Reserving
    /// the dot's band explicitly gives the icon one contiguous space instead of
    /// two useless margins, which is the arrangement the Dock has — icon, then a
    /// thin strip with the indicator in it, and nothing else.
    var dotClearance: CGFloat { whole(5) }

    /// A capsule's plate. Slightly taller than the tiles it holds, so the tint
    /// reads as a bed the row sits on rather than as a border around it.
    var pillCornerRadius: CGFloat { whole(11) }
    var pillHeight: CGFloat { tileHeight + whole(6) }
    /// The rule after the groups button, and the ones between capsules.
    var dividerHeight: CGFloat { whole(26) }
    var sectionDividerHeight: CGFloat { whole(22) }
    /// "No open windows", and the folded-window count in the overflow control.
    var hintFontSize: CGFloat { exact(11.5) }

    /// A count on a cluster or a stack.
    var badgeFontSize: CGFloat { exact(8) }
    var badgeMinSize: CGFloat { whole(12) }
    var badgePadding: CGFloat { whole(3) }

    /// A hairline stays a hairline. Scaling it turns the separators into bars,
    /// and it is charged to the width budget, so growing it costs tiles as well.
    var dividerWidth: CGFloat { 1 }

    /// Gap between the strip and the screen edge. Unscaled on purpose: it is the
    /// distance to something outside the strip rather than a part of it, and the
    /// zoom clamp reserves exactly this band plus the height.
    var edgeInset: CGFloat { 8 }
    /// Width reserved for the "nothing here yet" hint.
    var emptyHintWidth: CGFloat { whole(380) }

    // MARK: - Item widths

    var iconOnlyWidth: CGFloat { whole(40) }
    var preferredTitledWidth: CGFloat { whole(150) }
    /// Below this a title is just an ellipsis, so entries collapse to icon-only
    /// instead — the same thing Chrome does when tabs get too narrow.
    ///
    /// It tracks `preferredIconSize`: a titled tile spends its width on padding
    /// (7 a side), the icon and the 6pt gap before the text, so raising the icon
    /// without raising this leaves literally no room for the title it is
    /// supposed to be guaranteeing. Raised with the icon, by exactly the icon's
    /// growth, so the text allowance at the collapse threshold is unchanged.
    var minimumTitledWidth: CGFloat { whole(71) }
    /// Absolute floor. Only reached on a genuinely extreme strip; the fair share
    /// governs long before this does.
    ///
    /// **Deliberately not scaled**, and this is the one number here where that
    /// matters. It is the only value the layout ever clamps a width *up* to, and
    /// clamping up is what makes a busy strip spill past its own edge — a fair
    /// share of 15.75pt raised to a scaled floor of 17.5pt is 60 tiles each 1.75pt
    /// too wide. Scaling it looks obviously right and the self-test failed on it
    /// immediately: 60 windows at 1.25x needed 1251pt of a 1240pt bar.
    ///
    /// Leaving it absolute costs nothing the setting was offering. A larger scale
    /// still fills the row sooner, because every *other* width grew; it simply
    /// bottoms out in the same place, so the strip's capacity is the same at
    /// every size instead of shrinking exactly when the row is most crowded.
    var hardMinimumWidth: CGFloat { 14 }
    /// Deliberately *larger* than `iconOnlyWidth`, and that is not a mistake.
    ///
    /// A macOS application icon is drawn into a canvas that is mostly artwork but
    /// not entirely: measured across all 133 apps on this machine, the alpha
    /// bounding box is a median **0.844** of the frame and never more than
    /// **0.898**. So ~15% of every icon frame is transparent margin the icon
    /// brings with it, and sizing the *frame* to the tile — as this did at 36,
    /// 4pt under `iconOnlyWidth` — leaves the artwork far smaller than the space
    /// it was given. The real gap between two neighbours' ink was ~16.6pt against
    /// the Dock's ~9.9pt, while drawing icons a third the size.
    ///
    /// The frame therefore overhangs its tile and only the ink is bounded; see
    /// `DeckLayout.iconSize` and `DeckLayout.inkHeadroom`. Nothing clips, so the
    /// overhang costs nothing — it is transparent either way.
    ///
    /// Scaled, unlike the two floors below it: this is a *preferred* size the
    /// layout clamps down from, never up to, so it carries none of their risk.
    var preferredIconSize: CGFloat { whole(43) }
    /// Clusters stack several icons in one tile, so they stay at the size they
    /// were before the icon grew — a number of its own rather than derived from
    /// `preferredIconSize`, which would have silently enlarged them too.
    var clusterIconCap: CGFloat { whole(32) }
    /// Unscaled for the same reason as `hardMinimumWidth`: it is a floor the icon
    /// is clamped *up* to, and a tile at that floor is `hardMinimumWidth` wide —
    /// so a scaled minimum would draw a 16pt icon in a 14pt tile.
    var minimumIconSize: CGFloat { 10 }
    var preferredSpacing: CGFloat { whole(6) }

    var titleFontSize: CGFloat { exact(11.5) }
    var titlePadding: CGFloat { whole(7) }

    /// Width a capsule adds around its contents, per side.
    var pillInset: CGFloat { whole(5) }

    // MARK: - The overflow control

    // Its geometry is defined once and read by both the layout and the view.
    // Estimating it here and drawing something else there made the panel wider
    // than its contents, and the surplus showed as dead space on the right that
    // the left edge did not have.
    var collapsedPadding: CGFloat { whole(8) }
    var collapsedDotSize: CGFloat { whole(11) }
    /// Each further dot overlaps its neighbour, so folding six groups costs about
    /// a tile rather than six.
    var collapsedDotStep: CGFloat { whole(7) }
    var collapsedGap: CGFloat { whole(5) }

    /// Sized to the digits actually shown rather than reserving room for three.
    /// A fixed slot left the number floating away from the dots with a gap on
    /// both sides — the count is the last thing in the control, so any surplus
    /// reads as the whole thing being badly spaced.
    func collapsedCountWidth(_ total: Int) -> CGFloat {
        CGFloat(String(total).count) * whole(7) + whole(2)
    }

    func collapsedControlWidth(groups: Int, windows: Int) -> CGFloat {
        collapsedPadding * 2
            + collapsedDotSize + CGFloat(max(groups - 1, 0)) * collapsedDotStep
            + collapsedGap + collapsedCountWidth(windows)
    }

    // MARK: - The display

    /// Breathing room so the strip never spans the full display. Unscaled: it is
    /// a margin on the screen rather than part of the strip, and scaling it would
    /// take room away from the tiles at exactly the size that needs the most.
    static let screenMargin: CGFloat = 40

    static func maxWidth(screen: NSScreen? = NSScreen.main) -> CGFloat {
        guard let screen else { return 1200 }
        return screen.frame.width - screenMargin
    }
}

/// How subviews of the strip reach the metrics. Every tile draws itself from the
/// same value the layout pass measured with, and a change to the scale
/// propagates as an ordinary environment change — with no global to keep in step.
///
/// The default is the unscaled strip, so anything drawn outside `DeckView` — the
/// switcher panels, the all-groups list — is unaffected by it.
private struct DeckMetricsKey: EnvironmentKey {
    static let defaultValue = DeckMetrics()
}

extension EnvironmentValues {
    var deckMetrics: DeckMetrics {
        get { self[DeckMetricsKey.self] }
        set { self[DeckMetricsKey.self] = newValue }
    }
}
