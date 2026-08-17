import Foundation

/// What hovering an entry escalates to.
///
/// The instant title chip is deliberately not part of this: it needs no
/// permission and no capture, so it stays on in every mode.
enum PreviewMode: String, Codable, CaseIterable, Identifiable {
    /// Title chip only. Nothing else is shown and Screen Recording is never
    /// requested.
    case off
    /// Title chip, then a thumbnail. Needs Screen Recording.
    case thumbnail
    /// Title chip, thumbnail, then hovering the thumbnail shows the window at
    /// full size in its real position. Needs Screen Recording.
    case thumbnailAndPeek

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "Title only"
        case .thumbnail: "Title, then thumbnail"
        case .thumbnailAndPeek: "Title, thumbnail, then peek"
        }
    }

    var explanation: String {
        switch self {
        case .off:
            "Hovering names the window and nothing more. No Screen Recording permission is requested."
        case .thumbnail:
            "Hovering names the window, then shows a thumbnail of it. Needs Screen Recording permission. Nothing on your desktop moves."
        case .thumbnailAndPeek:
            "Hovering names the window, then shows a thumbnail. Moving onto that thumbnail shows the window at full size where it really sits, so you can see it even when it's buried. Nothing actually moves until you click the thumbnail. Needs Screen Recording permission."
        }
    }

    var wantsThumbnail: Bool { self != .off }
    var wantsPeek: Bool { self == .thumbnailAndPeek }

    /// Lenient so a saved value from an older build — the removed `peek` mode,
    /// say — falls back instead of throwing. A strict decode would fail the
    /// whole state file and silently discard the user's groups and pinned apps.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PreviewMode(rawValue: raw) ?? .thumbnailAndPeek
    }
}
