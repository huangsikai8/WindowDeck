import Foundation

/// How quickly each stage of the hover escalation fires.
///
/// Exposed in Settings because the right values are a matter of feel, and
/// guessing them in code means a rebuild for every adjustment.
struct HoverTimings: Codable, Equatable {
    /// Zero by default: naming the window under the cursor is the whole point,
    /// and any delay defeats it.
    var titleDelay: TimeInterval = 0
    /// Long enough that sweeping along the strip doesn't fire a burst of
    /// captures, short enough to feel immediate when you pause.
    var thumbnailDelay: TimeInterval = 0.15
    var peekDelay: TimeInterval = 0
    /// Grace period before hiding. This is what lets the cursor travel from an
    /// entry to its thumbnail without the popup vanishing on the way.
    var hideGrace: TimeInterval = 0.12
    /// How long the panel stays "warm" after being shown. While warm, moving to
    /// another entry shows its thumbnail with no delay at all — the wait is
    /// there to avoid firing on a passing sweep, and once you're clearly
    /// scanning the strip that has already been established.
    var warmWindow: TimeInterval = 1.5

    static let defaults = HoverTimings()

    static let range: ClosedRange<Double> = 0...1.5
    static let warmRange: ClosedRange<Double> = 0...5

    init() {}

    /// Field-by-field fallback, for the same reason PersistedState does it: a
    /// partially-written file should never discard the settings it does contain.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = HoverTimings()
        titleDelay = try container.decodeIfPresent(TimeInterval.self, forKey: .titleDelay)
            ?? fallback.titleDelay
        thumbnailDelay = try container.decodeIfPresent(TimeInterval.self, forKey: .thumbnailDelay)
            ?? fallback.thumbnailDelay
        peekDelay = try container.decodeIfPresent(TimeInterval.self, forKey: .peekDelay)
            ?? fallback.peekDelay
        hideGrace = try container.decodeIfPresent(TimeInterval.self, forKey: .hideGrace)
            ?? fallback.hideGrace
        warmWindow = try container.decodeIfPresent(TimeInterval.self, forKey: .warmWindow)
            ?? fallback.warmWindow
    }
}
