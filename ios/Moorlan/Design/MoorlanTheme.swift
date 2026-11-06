import SwiftUI

/// Prototype accent families. Layout, type, and chrome stay HIG-native; accents tint the canvas.
enum ThemeID: String, CaseIterable, Identifiable {
    case orbField
    case softSignal
    case posterMark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .orbField: return "Sky"
        case .softSignal: return "Peach"
        case .posterMark: return "Mint"
        }
    }
}

/// How atmospheric wash sits behind the status graphic.
enum ThemeHeroStyle {
    case orb
    case badge
    case arc
}

/// Visual connection state shared by Home and themed heroes.
enum StatusLinkState: Equatable {
    case idle
    case connecting
    case connectedSplit
    case connectedExit
    case unreachable
    case atHome
}

/// HIG-first tokens: system type and semantic colors, plus a light playful wash.
struct MoorlanTheme: Equatable {
    var id: ThemeID
    var heroStyle: ThemeHeroStyle

    /// Soft accent for canvas wash (low opacity over system background).
    var wash: Color
    var orbBreathe: Bool
    var quietMotion: Bool

    // Fixed status language (playful, readable for kids).
    static let pathGreen = Color(red: 0.20, green: 0.72, blue: 0.42)
    static let pathBlue = Color(red: 0.35, green: 0.48, blue: 0.92)
    static let pathRed = Color(red: 0.90, green: 0.28, blue: 0.28)
    static let pathGrey = Color(red: 0.62, green: 0.64, blue: 0.68)

    static let orbField = MoorlanTheme(
        id: .orbField,
        heroStyle: .orb,
        wash: Color(red: 0.45, green: 0.72, blue: 0.95),
        orbBreathe: true,
        quietMotion: false
    )

    static let softSignal = MoorlanTheme(
        id: .softSignal,
        heroStyle: .badge,
        wash: Color(red: 1.0, green: 0.72, blue: 0.58),
        orbBreathe: false,
        quietMotion: true
    )

    static let posterMark = MoorlanTheme(
        id: .posterMark,
        heroStyle: .arc,
        wash: Color(red: 0.30, green: 0.72, blue: 0.62),
        orbBreathe: false,
        quietMotion: false
    )

    static func theme(for id: ThemeID) -> MoorlanTheme {
        switch id {
        case .orbField: return .orbField
        case .softSignal: return .softSignal
        case .posterMark: return .posterMark
        }
    }

    func accent(for state: StatusLinkState) -> Color {
        switch state {
        case .atHome, .idle: return Self.pathGrey
        case .connectedSplit, .connectedExit: return Self.pathGreen
        case .connecting: return Self.pathBlue
        case .unreachable: return Self.pathRed
        }
    }

    /// SF Pro text styles — Dynamic Type friendly, HIG-default.
    func headlineFont() -> Font {
        .title2.weight(.semibold)
    }

    func detailFont() -> Font {
        .subheadline
    }

    func buttonFont() -> Font {
        .body.weight(.semibold)
    }

    /// Grouped-list style surface for cards / rows.
    var chipFill: Color { Color(.secondarySystemGroupedBackground) }
    var canvasMid: Color { Color(.systemGroupedBackground) }
    var primaryText: Color { .primary }
    var secondaryText: Color { .secondary }
    var chipText: Color { .primary }
    var buttonFill: Color { Color.primary }
    var buttonText: Color { Color(.systemBackground) }
    var disconnectFill: Color { Self.pathGreen }
    var disconnectText: Color { .white }

    // Legacy accent names used by empty hero washes.
    var home: Color { wash }
    var split: Color { Self.pathGreen }
    var exit: Color { wash.opacity(0.85) }
    var connecting: Color { Self.pathBlue }
}

extension MoorlanTheme {
    static let `default` = orbField
}

/// Standard Apple-ish spacing (points), matching inset grouped lists.
enum MoorlanSpacing {
    static let screen: CGFloat = 16
    static let section: CGFloat = 24
    static let row: CGFloat = 12
    static let tight: CGFloat = 8
    static let cardRadius: CGFloat = 12
    static let controlRadius: CGFloat = 10
}
