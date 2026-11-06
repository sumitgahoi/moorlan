import SwiftUI

/// Shared themed controls for Home / Empty.
struct ThemePrimaryButton: View {
    var title: String
    var isDestructive: Bool = false
    var disabled: Bool = false
    var action: () -> Void

    @Environment(\.moorlanTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressed = false

    var body: some View {
        Button {
            if !reduceMotion && !theme.quietMotion {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) {
                    pressed = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        pressed = false
                    }
                }
            }
            action()
        } label: {
            Text(title)
                .font(theme.buttonFont())
                .foregroundStyle(isDestructive ? theme.disconnectText : theme.buttonText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    Capsule(style: .continuous)
                        .fill(isDestructive ? theme.disconnectFill : theme.buttonFill)
                )
                .scaleEffect(pressed ? 0.97 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .accessibilityAddTraits(.isButton)
    }
}

struct ThemeChip: View {
    var text: String

    @Environment(\.moorlanTheme) private var theme

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(theme.chipText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(theme.chipFill, in: Capsule(style: .continuous))
    }
}

/// Big circular power control for connect / disconnect / cancel-connect.
struct PowerButton: View {
    enum Kind {
        case connect
        case disconnect
        /// Handshake / tunnel start in progress — tap cancels.
        case connecting
        case busy
    }

    var kind: Kind
    var disabled: Bool = false
    var action: () -> Void

    @Environment(\.moorlanTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressed = false
    @State private var spin = false

    private static let onGreen = Color(red: 0.20, green: 0.72, blue: 0.42)
    private static let connectingBlue = Color(red: 0.35, green: 0.48, blue: 0.92)

    var body: some View {
        Button {
            guard kind != .busy else { return }
            if !reduceMotion && !theme.quietMotion {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) {
                    pressed = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        pressed = false
                    }
                }
            }
            action()
        } label: {
            ZStack {
                Circle()
                    .fill(fill)
                    .frame(width: 88, height: 88)
                    .shadow(color: shadow, radius: pressed ? 6 : 14, y: pressed ? 2 : 8)

                if kind == .connecting {
                    Circle()
                        .stroke(Self.connectingBlue.opacity(0.2), lineWidth: 4)
                        .frame(width: 96, height: 96)
                    Circle()
                        .trim(from: 0.05, to: 0.35)
                        .stroke(
                            Self.connectingBlue,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .frame(width: 96, height: 96)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .animation(
                            reduceMotion
                                ? nil
                                : .linear(duration: 0.9).repeatForever(autoreverses: false),
                            value: spin
                        )
                } else {
                    Circle()
                        .strokeBorder(ring, lineWidth: 3)
                        .frame(width: 88, height: 88)
                }

                if kind == .busy {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(iconColor)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(iconColor)
                }
            }
            .scaleEffect(pressed ? 0.94 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled || kind == .busy)
        .opacity(disabled ? 0.4 : 1)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .onAppear { spin = kind == .connecting && !reduceMotion }
        .onChange(of: kind) { _, newKind in
            spin = newKind == .connecting && !reduceMotion
        }
    }

    private var fill: Color {
        switch kind {
        case .connect: return theme.buttonFill
        case .disconnect: return Self.onGreen
        case .connecting: return theme.chipFill
        case .busy: return theme.chipFill
        }
    }

    private var ring: Color {
        switch kind {
        case .connect: return theme.buttonFill.opacity(0.15)
        case .disconnect: return Color.white.opacity(0.35)
        case .connecting: return Self.connectingBlue.opacity(0.3)
        case .busy: return theme.secondaryText.opacity(0.2)
        }
    }

    private var iconColor: Color {
        switch kind {
        case .connect: return theme.buttonText
        case .disconnect: return .white
        case .connecting: return Self.connectingBlue
        case .busy: return theme.secondaryText
        }
    }

    private var shadow: Color {
        switch kind {
        case .connect: return theme.buttonFill.opacity(0.28)
        case .disconnect: return Self.onGreen.opacity(0.4)
        case .connecting: return Self.connectingBlue.opacity(0.22)
        case .busy: return .clear
        }
    }

    private var accessibilityLabel: String {
        switch kind {
        case .connect: return "Connect"
        case .disconnect: return "Disconnect"
        case .connecting: return "Cancel"
        case .busy: return "Working"
        }
    }
}

/// Cheerful pair/unpair completion splash (light theme accent).
struct PairSuccessView: View {
    var title: String
    @Environment(\.moorlanTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                theme.split.opacity(0.5),
                                theme.home.opacity(0.2),
                                .clear
                            ],
                            center: .center,
                            startRadius: 4,
                            endRadius: 90
                        )
                    )
                    .frame(width: 160, height: 160)
                    .scaleEffect(appeared ? 1 : 0.7)

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [theme.split, theme.home],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 88, height: 88)
                    .shadow(color: theme.split.opacity(0.35), radius: 12, y: 4)
                    .scaleEffect(appeared ? 1 : 0.6)

                Image(systemName: "checkmark")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)
                    .scaleEffect(appeared ? 1 : 0.4)
            }

            Text(title)
                .font(theme.headlineFont())
                .foregroundStyle(theme.primaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
                    appeared = true
                }
            }
        }
    }
}

#if DEBUG
struct ThemePickerMenu: View {
    @ObservedObject var store: ThemeStore

    var body: some View {
        Menu {
            ForEach(ThemeID.allCases) { id in
                Button {
                    store.select(id)
                } label: {
                    if id == store.selectedID {
                        Label(id.displayName, systemImage: "checkmark")
                    } else {
                        Text(id.displayName)
                    }
                }
            }
        } label: {
            Image(systemName: "paintpalette")
        }
        .accessibilityLabel("Prototype theme")
    }
}
#endif
