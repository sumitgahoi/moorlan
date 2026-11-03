import SwiftUI
import PeerDoorCore

struct HomeView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    var onScan: () -> Void
    var onSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 12)
            statusOrb
            Spacer(minLength: 12)
            details
            Spacer(minLength: 20)
            connectButton
                .padding(.bottom, 28)
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("PeerDoor")
                    .font(PeerDoorTheme.display)
                    .foregroundStyle(PeerDoorTheme.paper)
                Menu {
                    ForEach(tunnel.servers) { server in
                        Button(server.displayName) { Task { await tunnel.selectProfile(server.id); await tunnel.applyDesiredState() } }
                    }
                } label: {
                    Label(tunnel.selectedServer?.displayName ?? "Choose profile", systemImage: "chevron.down")
                        .font(PeerDoorTheme.caption)
                        .foregroundStyle(PeerDoorTheme.mist)
                }
                .disabled(tunnel.isUnjoining)

            }
            Spacer()
            Button(action: onSettings) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(PeerDoorTheme.paper)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(PeerDoorTheme.panel))
            }
            Button(action: onScan) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(PeerDoorTheme.ink)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(PeerDoorTheme.accent))
            }
        }
    }

    private var statusOrb: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(orbGlow.opacity(0.22))
                    .frame(width: 220, height: 220)
                    .blur(radius: 18)
                Circle()
                    .stroke(orbGlow.opacity(0.55), lineWidth: 1.5)
                    .frame(width: 176, height: 176)
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [PeerDoorTheme.panel, PeerDoorTheme.ink],
                            center: .topLeading,
                            startRadius: 10,
                            endRadius: 120
                        )
                    )
                    .frame(width: 150, height: 150)
                    .shadow(color: orbGlow.opacity(0.35), radius: 24, y: 8)
                Image(systemName: orbIcon)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(orbGlow)
                    .symbolEffect(.pulse, options: .repeating, isActive: tunnel.status == .connecting)
            }
            VStack(spacing: 6) {
                Text(statusTitle)
                    .font(PeerDoorTheme.title)
                    .foregroundStyle(PeerDoorTheme.paper)
                Text(tunnel.statusReason ?? pathCaption)
                    .font(PeerDoorTheme.body)
                    .foregroundStyle(PeerDoorTheme.mist)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var details: some View {
        VStack(spacing: 12) {
            GlassPanel {
                LabeledValue(label: "Tunnel IP", value: tunnel.selectedServer?.lease.address ?? "—")
                Divider().overlay(PeerDoorTheme.panelStroke)
                LabeledValue(label: "Endpoint", value: tunnel.selectedServer?.lease.endpoint ?? "—")
                Divider().overlay(PeerDoorTheme.panelStroke)
                LabeledValue(label: "Mode", value: modeLabel)
            }
            Toggle(isOn: exitBinding) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Exit node")
                        .font(PeerDoorTheme.body)
                        .foregroundStyle(PeerDoorTheme.paper)
                    Text("Automatic: exit on other Wi-Fi; subnet access on trusted Wi-Fi and cellular.")
                        .font(PeerDoorTheme.caption)
                        .foregroundStyle(PeerDoorTheme.mist)
                }
            }
            .disabled(tunnel.pathKind == .serverLAN)
            .tint(PeerDoorTheme.accent)
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(PeerDoorTheme.panel.opacity(0.92))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(PeerDoorTheme.panelStroke, lineWidth: 1)
                    )
            )
            if tunnel.policy.mode != .automatic {
                Button("Use automatic network policy") {
                    tunnel.policy.mode = .automatic
                    tunnel.savePolicy()
                }
                .font(.footnote)
            }
        }
    }

    private var connectButton: some View {
        Button {
            Task { await tunnel.toggleDesiredConnection() }
        } label: {
            Text(buttonTitle)
                .font(PeerDoorTheme.title)
                .foregroundStyle(PeerDoorTheme.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(buttonFill)
                )
        }
        .disabled(tunnel.status == .connecting || tunnel.status == .disconnecting || tunnel.pathKind == .serverLAN || tunnel.isUnjoining)
    }

    private var exitBinding: Binding<Bool> {
        Binding(
            get: { tunnel.effectiveExit },
            set: {
                tunnel.setExit($0)
            }
        )
    }

    private var statusTitle: String {
        switch tunnel.status {
        case .connected: return "Protected"
        case .connecting: return "Connecting"
        case .disconnecting: return "Disconnecting"
        case .invalid: return "Needs permission"
        case .disconnected: return "Ready"
        }
    }

    private var orbIcon: String {
        switch tunnel.status {
        case .connected: return "lock.fill"
        case .connecting, .disconnecting: return "arrow.triangle.2.circlepath"
        default: return "lock.open"
        }
    }

    private var orbGlow: Color {
        switch tunnel.status {
        case .connected: return PeerDoorTheme.connected
        case .connecting: return PeerDoorTheme.accent
        case .invalid: return PeerDoorTheme.warn
        default: return PeerDoorTheme.mist
        }
    }

    private var buttonTitle: String {
        switch tunnel.status {
        case .connected, .connecting: return "Disconnect"
        default: return "Connect"
        }
    }

    private var buttonFill: Color {
        switch tunnel.status {
        case .connected, .connecting: return PeerDoorTheme.paper
        default: return PeerDoorTheme.accent
        }
    }

    private var modeLabel: String {
        if case .disconnect = tunnel.policy.decide(path: tunnel.pathKind) {
            return "Paused on server LAN"
        }
        if case .connect(let full) = tunnel.policy.decide(path: tunnel.pathKind) {
            return full ? "Full tunnel" : "Split tunnel"
        }
        return "—"
    }

    private var pathCaption: String {
        switch tunnel.pathKind {
        case .serverLAN: return "You're on the server LAN"
        case .cellular: return "Cellular · trusted by default"
        case .wifi(let id): return tunnel.policy.trustedNetworkIDs.contains(id) ? "Trusted Wi‑Fi" : "Untrusted Wi‑Fi"
        case .other: return "Current network"
        }
    }
}

private struct LabeledValue: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(PeerDoorTheme.caption)
                .foregroundStyle(PeerDoorTheme.mist)
            Spacer()
            Text(value)
                .font(PeerDoorTheme.body)
                .foregroundStyle(PeerDoorTheme.paper)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 4)
    }
}
