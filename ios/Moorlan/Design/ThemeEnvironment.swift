import SwiftUI

private struct MoorlanThemeKey: EnvironmentKey {
    static let defaultValue: MoorlanTheme = .default
}

extension EnvironmentValues {
    var moorlanTheme: MoorlanTheme {
        get { self[MoorlanThemeKey.self] }
        set { self[MoorlanThemeKey.self] = newValue }
    }
}

extension View {
    func moorlanTheme(_ theme: MoorlanTheme) -> some View {
        environment(\.moorlanTheme, theme)
    }

    /// System grouped background + a light playful wash (works in light and dark).
    func moorlanCanvas(theme: MoorlanTheme) -> some View {
        background {
            ZStack {
                Color(.systemGroupedBackground)
                RadialGradient(
                    colors: [theme.wash.opacity(0.22), .clear],
                    center: .topTrailing,
                    startRadius: 40,
                    endRadius: 380
                )
                RadialGradient(
                    colors: [theme.wash.opacity(0.12), .clear],
                    center: .bottomLeading,
                    startRadius: 20,
                    endRadius: 300
                )
            }
            .ignoresSafeArea()
        }
    }
}
