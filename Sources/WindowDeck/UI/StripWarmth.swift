import Foundation

/// Whether the pointer is already scanning the strip.
///
/// The hover delay exists to stop a panel firing as the pointer merely passes
/// over the bar. Once something *is* up, that question has been settled — so the
/// next tile shows immediately, and the strip reads as one continuous surface
/// rather than making you wait again at every icon.
///
/// It is shared because the state belongs to the strip, not to a panel. The
/// window preview and the app-stack list are separate panels with separate
/// timers, and each keeping its own warmth meant crossing from one to the other
/// re-imposed the full delay: sliding along the bar was instant until it reached
/// a stacked app, which then sat there doing nothing. Two panels, one answer to
/// "are we already scanning".
///
/// `hold` covers the time something is actually on screen, which a plain
/// expiring timestamp cannot: resting on a panel for longer than the warm window
/// would otherwise go cold while it was still visible.
@MainActor
final class StripWarmth {
    static let shared = StripWarmth()

    private var holders: Set<String> = []
    private var until: Date?

    var isWarm: Bool {
        if !holders.isEmpty { return true }
        if let until, Date() < until { return true }
        return false
    }

    /// Something is on screen and stays warm until it says otherwise.
    func hold(_ owner: String) {
        let inserted = holders.insert(owner).inserted
        until = nil
        if inserted { Trace.debug(.preview, "warmth hold \(owner) holders=\(holders.sorted())") }
    }

    /// It went away. Warmth lingers so a short hop between tiles doesn't reset
    /// the wait.
    ///
    /// A release can only ever *extend* the lingering window, never cut it
    /// short. A panel that was never on screen still runs this path — the
    /// app-stack list does it whenever the pointer crosses a stacked icon
    /// without pausing, and the preview does it whenever it got no further than
    /// the title bar — and with a plain assignment that `staying: 0` threw away
    /// warmth another panel had genuinely earned. The strip then made you wait
    /// the full delay again halfway along a sweep you had already started, which
    /// is exactly the wait this type exists to remove. Going cold on purpose is
    /// `chill()`.
    func release(_ owner: String, staying interval: TimeInterval) {
        let held = holders.remove(owner) != nil
        guard holders.isEmpty else {
            Trace.debug(.preview, "warmth release \(owner) staying=\(interval) still-held-by=\(holders.sorted())")
            return
        }
        let candidate = Date().addingTimeInterval(interval)
        if until == nil || candidate > until! { until = candidate }
        Trace.debug(.preview,
                    "warmth release \(owner) held=\(held) staying=\(interval) "
                    + "warm-for=\(String(format: "%.2f", until!.timeIntervalSinceNow))s")
    }

    /// Deliberately cold: the strip is no longer being scanned at all.
    func chill() {
        guard !holders.isEmpty || until != nil else { return }
        holders.removeAll()
        until = nil
        Trace.debug(.preview, "warmth chilled")
    }
}
