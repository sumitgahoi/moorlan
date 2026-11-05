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
                    Text(tunnel.statusHeadline)
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)

                    profileLabel

                    Text(tunnel.statusDetail)
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
                        || tunnel.wifiIdentityMissing
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
                    .accessibilityLabel("Scan to pair")
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
                    Button {
                        Task {
                            await tunnel.selectProfile(server.id)
                            await tunnel.applyDesiredState()
                        }
                    } label: {
                        if server.id == tunnel.selectedServer?.id {
                            Label(server.displayName, systemImage: "checkmark")
                        } else {
                            Text(server.displayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(tunnel.selectedServer?.displayName ?? "Choose tunnel")
                        .font(.body.weight(.medium))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .disabled(tunnel.isUnpairing)
            .accessibilityLabel("Tunnel")
            .accessibilityValue(tunnel.selectedServer?.displayName ?? "None")
        } else if let name = tunnel.selectedServer?.displayName {
            Text(name)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var diagramState: ConnectionDiagramView.LinkState {
        if tunnel.wifiIdentityMissing { return .unreachable }
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
