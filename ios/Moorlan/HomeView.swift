import SwiftUI
import MoorlanCore

struct HomeView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    var onScan: () -> Void
    var onSettings: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer(minLength: 12)

                ConnectionDiagramView(state: diagramState)
                    .padding(.bottom, 28)

                VStack(spacing: 6) {
                    Text(statusTitle)
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)

                    profileLabel

                    Text(statusSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    if tunnel.status == .connected, let rates = tunnel.transferRates {
                        Text(rates)
                            .font(.subheadline.monospacedDigit().weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                            .accessibilityLabel(tunnel.transferRatesAccessibility)
                    }
                }
                .padding(.horizontal, 28)

                if showsExitToggle {
                    Toggle(isOn: exitBinding) {
                        Text("Exit Node")
                            .font(.body.weight(.medium))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 28)
                    .padding(.top, 28)
                    .disabled(tunnel.isUnpairing)
                    .accessibilityHint("When on, all traffic goes through home. When off, only your home network is reachable.")
                }

                Spacer(minLength: 24)

                Button {
                    Task { await tunnel.toggleDesiredConnection() }
                } label: {
                    Text(buttonTitle)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(buttonIsDisconnect ? Color.red.opacity(0.85) : nil)
                .disabled(
                    tunnel.status == .connecting
                        || tunnel.status == .disconnecting
                        || tunnel.onHomeWiFi
                        || tunnel.isUnpairing
                )
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Moorlan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onSettings) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                    .disabled(tunnel.isUnpairing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onScan) {
                        Image(systemName: "qrcode.viewfinder")
                    }
                    .accessibilityLabel("Scan QR")
                    .disabled(tunnel.isUnpairing)
                }
            }
        }
    }

    @ViewBuilder
    private var profileLabel: some View {
        if tunnel.servers.count > 1 {
            Menu {
                ForEach(tunnel.servers) { server in
                    Button(server.displayName) {
                        Task {
                            await tunnel.selectProfile(server.id)
                            await tunnel.applyDesiredState()
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(tunnel.selectedServer?.displayName ?? "Choose profile")
                        .font(.body.weight(.medium))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .disabled(tunnel.isUnpairing)
            .accessibilityLabel("Profile")
            .accessibilityValue(tunnel.selectedServer?.displayName ?? "None")
        } else if let name = tunnel.selectedServer?.displayName {
            Text(name)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var showsExitToggle: Bool {
        !tunnel.onHomeWiFi && (tunnel.status == .connected || tunnel.status == .connecting)
    }

    private var exitBinding: Binding<Bool> {
        Binding(
            get: { tunnel.effectiveExit },
            set: { tunnel.setExit($0) }
        )
    }

    private var diagramState: ConnectionDiagramView.LinkState {
        if tunnel.onHomeWiFi { return .atHome }
        switch tunnel.status {
        case .invalid: return .unreachable
        case .connecting, .disconnecting: return .connecting
        case .connected:
            return tunnel.effectiveExit ? .connectedExit : .connectedSplit
        case .disconnected:
            return .idle
        }
    }

    private var statusTitle: String {
        if tunnel.onHomeWiFi { return "Off · Home" }
        switch tunnel.status {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .disconnecting: return "Disconnecting"
        case .invalid: return "Needs Attention"
        case .disconnected: return "Disconnected"
        }
    }

    private var statusSubtitle: String {
        if tunnel.onHomeWiFi { return "Tunnel stays off here" }
        switch tunnel.status {
        case .connected:
            return tunnel.effectiveExit ? "All traffic via home" : "Home LAN only"
        case .connecting:
            return "Reaching your home…"
        case .disconnecting:
            return "Closing the tunnel…"
        case .invalid:
            return tunnel.statusReason ?? "Check VPN permission in Settings"
        case .disconnected:
            if tunnel.statusReason == "Waiting for a network" {
                return "Waiting for a network"
            }
            return "Tap Connect when you’re away from home"
        }
    }

    private var buttonTitle: String {
        switch tunnel.status {
        case .connected, .connecting: return "Disconnect"
        default: return "Connect"
        }
    }

    private var buttonIsDisconnect: Bool {
        tunnel.status == .connected || tunnel.status == .connecting
    }
}
