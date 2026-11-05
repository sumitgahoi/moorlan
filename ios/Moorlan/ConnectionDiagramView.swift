import SwiftUI

/// Phone ↔ house status graphic. Connected states use a flowing dashed link.
struct ConnectionDiagramView: View {
    enum LinkState: Equatable {
        case idle
        case connecting
        case connectedSplit
        case connectedExit
        case unreachable
        case atHome
    }

    var state: LinkState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            node(systemName: "iphone", emphasized: state != .atHome)
            link
            node(systemName: "house.fill", emphasized: true)
        }
        .padding(.horizontal, 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private func node(systemName: String, emphasized: Bool) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 36, weight: .regular))
            .foregroundStyle(emphasized ? nodeTint : Color.secondary.opacity(0.45))
            .frame(width: 56, height: 56)
            .symbolRenderingMode(.hierarchical)
    }

    private var link: some View {
        ZStack {
            FlowingDashLink(
                color: linkTrack,
                flowing: !reduceMotion && (state == .connectedSplit || state == .connectedExit),
                speed: state == .connectedExit ? 36 : 22
            )
            .padding(.horizontal, 8)

            if state == .unreachable {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .background(Circle().fill(Color(.systemBackground)).padding(-2))
            } else if state == .connecting {
                ProgressView()
                    .controlSize(.small)
                    .background(Circle().fill(Color(.systemBackground)).padding(-6))
            } else if state == .connectedSplit || state == .connectedExit {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                    .symbolEffect(
                        .pulse,
                        options: .repeating,
                        isActive: !reduceMotion && state == .connectedExit
                    )
                    .background(Circle().fill(Color(.systemBackground)).padding(-2))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
    }

    private var linkTrack: Color {
        switch state {
        case .idle: return Color.secondary.opacity(0.35)
        case .connecting: return Color.accentColor.opacity(0.55)
        case .connectedSplit, .connectedExit: return .green
        case .unreachable: return .orange
        case .atHome: return Color.secondary.opacity(0.2)
        }
    }

    private var nodeTint: Color {
        switch state {
        case .unreachable: return .orange
        case .connectedSplit, .connectedExit: return .primary
        case .connecting: return .accentColor
        case .atHome, .idle: return .secondary
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .idle: return "Not connected to home"
        case .connecting: return "Connecting to home"
        case .connectedSplit: return "Connected to home network"
        case .connectedExit: return "Connected; all traffic via home"
        case .unreachable: return "Home not reachable"
        case .atHome: return "On home Wi-Fi; tunnel off"
        }
    }
}

private struct FlowingDashLink: View {
    var color: Color
    var flowing: Bool
    /// Points of dash-phase travel per second.
    var speed: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: flowing ? 1.0 / 30.0 : 1.0, paused: !flowing)) { context in
            Canvas { canvas, size in
                let midY = size.height / 2
                var path = Path()
                path.move(to: CGPoint(x: 0, y: midY))
                path.addLine(to: CGPoint(x: size.width, y: midY))

                let phase: CGFloat
                if flowing {
                    let t = context.date.timeIntervalSinceReferenceDate
                    phase = CGFloat((-t * speed).truncatingRemainder(dividingBy: 11))
                } else {
                    phase = 0
                }

                canvas.stroke(
                    path,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 6], dashPhase: phase)
                )
            }
        }
        .frame(height: 2)
        .frame(maxWidth: .infinity)
    }
}
