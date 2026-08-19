import Foundation

/// The order the window switcher offers candidates in.
///
/// The two answer different questions. Most-recently-used is right for a ⌘Tab
/// flip — "take me back where I was" — and is what the switcher has always done.
/// It is wrong for muscle memory: the list is rebuilt on every open, so the
/// window that was third last time is second now, and there is no position to
/// learn.
///
/// Strip order fixes the positions by reusing the arrangement the strip already
/// draws, which is also the answer to "can I rearrange it" — dragging a tile in
/// the strip moves it in the switcher too, because both read `DeckGroup.order`.
enum CycleOrder: String, Codable, CaseIterable, Identifiable {
    /// Most recently used, current window first.
    case recentlyUsed
    /// The strip's own left-to-right arrangement.
    case stripOrder

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recentlyUsed: "Most recently used"
        case .stripOrder: "Same order as the strip"
        }
    }

    var explanation: String {
        switch self {
        case .recentlyUsed:
            "The window you were in most recently comes first, like ⌘Tab. The list is rebuilt each time, so a window's position changes as you work."
        case .stripOrder:
            "The switcher lists windows in the same left-to-right order as the strip, so each one keeps its position between opens and can be learned. Drag a tile in the strip to rearrange it. Tapping once moves to the next window along."
        }
    }

    /// Lenient for the same reason `PreviewMode` is: a raw value written by a
    /// later build must fall back rather than throw, because a throw here fails
    /// the whole state file and takes every group with it.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CycleOrder(rawValue: raw) ?? .recentlyUsed
    }
}
