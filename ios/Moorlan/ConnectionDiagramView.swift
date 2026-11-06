import SwiftUI

/// Phone ↔ house status graphic. Line style encodes routing:
/// solid green = exit, dotted green = split, grey = idle, red + cross = error.
/// Connecting uses a neutral arc loader (not green) until handshake succeeds.
struct ConnectionDiagramView: View {
    typealias LinkState = StatusLinkState

    var state: LinkState
    @Environment(\.moorlanTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            linkColor.opacity(glowOpacity),
                            linkColor.opacity(glowOpacity * 0.35),
                            .clear
                        ],
                        center: .center,
                        startRadius: 24,
                        endRadius: 180
                    )
                )
                .frame(width: 340, height: 340)
                .scaleEffect(glowPulse ? 1.06 : 1)
                .allowsHitTesting(false)

            HStack(spacing: 4) {
                node(systemName: "iphone", emphasized: state != .atHome)
                link
                node(systemName: "house.fill", emphasized: true)
            }
            .padding(.horizontal, 36)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 220)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .animation(.easeInOut(duration: 0.28), value: state)
        .onAppear { updateGlowPulse() }
        .onChange(of: state) { _, _ in updateGlowPulse() }
    }

    @State private var glowPulse = false

    private func updateGlowPulse() {
        let live = shouldAnimateGlow && !reduceMotion
        if live {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                glowPulse = true
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                glowPulse = false
            }
        }
    }

    private func node(systemName: String, emphasized: Bool) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 48, weight: .semibold))
            .foregroundStyle(emphasized ? linkColor : theme.secondaryText.opacity(0.35))
            .frame(width: 64, height: 64)
            .symbolRenderingMode(.hierarchical)
            .shadow(
                color: emphasized && shouldAnimateGlow ? linkColor.opacity(0.35) : .clear,
                radius: 10,
                y: 2
            )
    }

    private var link: some View {
        ZStack {
            switch state {
            case .connecting:
                ConnectingArcLoader(
                    color: Self.connectingBlue,
                    reduceMotion: reduceMotion
                )
            case .unreachable:
                AnimatedLink(
                    style: .solid,
                    color: linkColor,
                    flowing: false,
                    reduceMotion: reduceMotion
                )
                .padding(.horizontal, 4)
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(linkColor)
                    .background(Circle().fill(theme.canvasMid).padding(-3))
            default:
                AnimatedLink(
                    style: linkStyle,
                    color: linkColor,
                    flowing: shouldAnimateLink,
                    reduceMotion: reduceMotion
                )
                .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 72)
    }

    private var linkStyle: AnimatedLink.Style {
        switch state {
        case .connectedExit: return .solid
        case .connectedSplit: return .dotted
        case .connecting, .idle, .atHome, .unreachable: return .solid
        }
    }

    private var linkColor: Color {
        switch state {
        case .connectedExit, .connectedSplit:
            return Self.connectedGreen
        case .connecting:
            return Self.connectingBlue
        case .unreachable:
            return Self.errorRed
        case .idle, .atHome:
            return Self.idleGrey
        }
    }

    private var glowOpacity: Double {
        switch state {
        case .connectedExit, .connectedSplit: return 0.42
        case .connecting: return 0.18
        case .unreachable: return 0.2
        case .idle, .atHome: return 0.08
        }
    }

    private var shouldAnimateGlow: Bool {
        state == .connectedExit || state == .connectedSplit
    }

    private var shouldAnimateLink: Bool {
        // Solid exit stays still; only the dotted split link animates.
        state == .connectedSplit
    }

    private var accessibilityLabel: String {
        switch state {
        case .idle: return "Disconnected"
        case .connecting: return MoorlanCopy.connecting
        case .connectedSplit: return "Connected · Split"
        case .connectedExit: return "Connected · Full"
        case .unreachable: return "Can’t reach home"
        case .atHome: return MoorlanCopy.offOnNetwork
        }
    }

    private static let connectedGreen = Color(red: 0.20, green: 0.72, blue: 0.42)
    private static let connectingBlue = Color(red: 0.35, green: 0.48, blue: 0.92)
    private static let errorRed = Color(red: 0.90, green: 0.28, blue: 0.28)
    private static let idleGrey = Color(red: 0.62, green: 0.64, blue: 0.68)
}

/// Indeterminate arc loader — attempt to connect, not success (inspired by circular VPN loaders).
private struct ConnectingArcLoader: View {
    var color: Color
    var reduceMotion: Bool
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.18), lineWidth: 5)
                .frame(width: 56, height: 56)

            Circle()
                .trim(from: 0.08, to: 0.42)
                .stroke(
                    AngularGradient(
                        colors: [color.opacity(0.15), color],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .frame(width: 56, height: 56)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(
                    reduceMotion
                        ? nil
                        : .linear(duration: 0.9).repeatForever(autoreverses: false),
                    value: spin
                )
        }
        .onAppear { spin = !reduceMotion }
        .onChange(of: reduceMotion) { _, reduced in
            spin = !reduced
        }
    }
}

/// Moving solid or dotted link between phone and house.
private struct AnimatedLink: View {
    enum Style {
        case solid
        case dotted
    }

    var style: Style
    var color: Color
    var flowing: Bool
    var reduceMotion: Bool

    var body: some View {
        let animate = flowing && !reduceMotion
        TimelineView(.animation(minimumInterval: animate ? 1.0 / 30.0 : 1.0, paused: !animate)) { context in
            Canvas { canvas, size in
                let midY = size.height / 2
                var path = Path()
                path.move(to: CGPoint(x: 0, y: midY))
                path.addLine(to: CGPoint(x: size.width, y: midY))

                let t = context.date.timeIntervalSinceReferenceDate
                let phase: CGFloat = animate
                    ? CGFloat((-t * speed).truncatingRemainder(dividingBy: period))
                    : 0

                switch style {
                case .dotted:
                    canvas.stroke(
                        path,
                        with: .color(color.opacity(0.22)),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    canvas.stroke(
                        path,
                        with: .color(color),
                        style: StrokeStyle(
                            lineWidth: lineWidth,
                            lineCap: .round,
                            dash: [10, 9],
                            dashPhase: phase
                        )
                    )
                case .solid:
                    // Solid exit link — no traveling white pulse (distracting on green).
                    canvas.stroke(
                        path,
                        with: .color(color.opacity(0.3)),
                        style: StrokeStyle(lineWidth: lineWidth + 4, lineCap: .round)
                    )
                    canvas.stroke(
                        path,
                        with: .color(color),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                }
            }
        }
        .frame(height: lineWidth + 8)
        .frame(maxWidth: .infinity)
    }

    private var lineWidth: CGFloat { style == .solid ? 6 : 5 }
    private var speed: Double { style == .solid ? 34 : 38 }
    private var period: Double { style == .solid ? 22 : 19 }
}
