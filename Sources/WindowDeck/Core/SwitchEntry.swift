import AppKit
import SwiftUI

/// One thing ⌥Tab can switch to: an item the strip draws, in the capsule it is
/// drawn in.
///
/// The grouping is deliberately **not** its own idea of what an application is.
/// It is whatever the strip already decided — a stacked app is one entry with a
/// count, a cluster is one entry, a loose window is its own — so stacking an app
/// on the bar is also how you collapse it here, and the switcher can never offer
/// a grouping that is not on screen. `id` is the strip's own slot identity,
/// section included, which is what keeps Chrome-in-Main and Chrome-in-Work
/// distinct without any extra rule.
struct SwitchEntry: Identifiable {
    let id: String
    let item: DeckItem
    let groupID: UUID
    let groupName: String
    /// The capsule's colour, drawn as a chip under every icon. With entries in
    /// most-recently-used order the capsules interleave, so two icons of one
    /// application side by side are otherwise indistinguishable.
    let groupColor: Color
    /// What the entry is called: the application, or a cluster's own name.
    let title: String
    let icon: NSImage?
    /// The windows behind it — empty for a launcher, which is an application
    /// running with nothing open. Drives both the recency ranking and what
    /// committing does.
    let windows: [WindowInfo]

    var count: Int { windows.count }

    /// What committing this entry does. An enum rather than a closure so the
    /// self-test can assert the choice without driving the switcher, which needs
    /// a run loop it does not have.
    enum Commit: Equatable {
        /// Raise one window: a plain entry, or a stack's most recent.
        case focus(CGWindowID)
        /// Raise every window together, which is what clicking a cluster does.
        case focusAll([CGWindowID])
        /// Ask the application to show itself, the way clicking a launcher does.
        case open(String)
        /// Nothing to do — a stack whose windows all closed between the list
        /// being built and the key being released.
        case none
    }
}
