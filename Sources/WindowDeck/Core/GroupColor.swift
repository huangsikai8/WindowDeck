import SwiftUI

/// The accent assigned to a group.
///
/// A fixed palette indexed by number rather than free-form hex: it keeps the
/// set visually coherent, makes the picker a row of swatches, and means the
/// stored value is a small stable integer.
enum GroupColor: Int, CaseIterable, Identifiable {
    case neutral = 0
    case blue
    case green
    case orange
    case purple
    case red
    case teal
    case pink
    case yellow

    var id: Int { rawValue }

    /// Chosen to stay legible as a small dot and as a tint behind text in both
    /// light and dark appearance.
    var color: Color {
        switch self {
        case .neutral: .secondary
        case .blue: Color(red: 0.20, green: 0.52, blue: 0.94)
        case .green: Color(red: 0.20, green: 0.68, blue: 0.38)
        case .orange: Color(red: 0.94, green: 0.56, blue: 0.18)
        case .purple: Color(red: 0.60, green: 0.40, blue: 0.92)
        case .red: Color(red: 0.90, green: 0.30, blue: 0.30)
        case .teal: Color(red: 0.16, green: 0.68, blue: 0.70)
        case .pink: Color(red: 0.92, green: 0.40, blue: 0.66)
        case .yellow: Color(red: 0.85, green: 0.72, blue: 0.20)
        }
    }

    var name: String {
        switch self {
        case .neutral: "None"
        case .blue: "Blue"
        case .green: "Green"
        case .orange: "Orange"
        case .purple: "Purple"
        case .red: "Red"
        case .teal: "Teal"
        case .pink: "Pink"
        case .yellow: "Yellow"
        }
    }

    /// Assignable colours — `neutral` is reserved for the built-in All group.
    static var selectable: [GroupColor] {
        allCases.filter { $0 != .neutral }
    }

    /// Cycles the palette so a run of new groups gets distinct colours.
    static func suggested(forGroupCount count: Int) -> GroupColor {
        let options = selectable
        return options[count % options.count]
    }

    static func from(index: Int) -> GroupColor {
        GroupColor(rawValue: index) ?? .neutral
    }
}
