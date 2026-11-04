import SwiftUI
import MoorlanCore

struct HomeView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    var onScan: () -> Void
    var onSettings: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    statusHero
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }

                Section {
                    profilePicker
                }

                Section {
                    LabeledContent("Tunnel IP", value: tunnel.selectedServer?.lease.address ?? "—")
                    LabeledContent("Endpoint", value: tunnel.selectedServer?.lease.endpoint ?? "—")
                    LabeledContent("Mode", value: modeLabel)
                }

                Section {
                    Toggle(isOn: exitBinding) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Exit node")
                            Text("Automatic: exit on other Wi‑Fi; subnet access on trusted Wi‑Fi and cellular.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(tunnel.onHomeWiFi)

                    if tunnel.policy.mode != .automatic {
                        Button("Use automatic network policy") {
                            tunnel.policy.mode = .automatic
                            tunnel.savePolicy()
                        }
                    }
                } footer: {
                    Text(pathCaption)
                }

                Section {
                    Button {
                        Task { await tunnel.toggleDesiredConnection() }
                    } label: {
                        Text(buttonTitle)
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(
                        tunnel.status == .connecting
                            || tunnel.status == .disconnecting
                            || tunnel.onHomeWiFi
                            || tunnel.isUnpairing
                    )
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Moorlan")
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

    private var statusHero: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: statusSymbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(statusTint)
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.pulse, options: .repeating, isActive: tunnel.status == .connecting)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(statusTitle)
                    .font(.largeTitle.weight(.bold))
                Text(tunnel.statusReason ?? pathCaption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var profilePicker: some View {
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
            LabeledContent("Profile") {
                HStack(spacing: 4) {
                    Text(tunnel.selectedServer?.displayName ?? "Choose profile")
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .disabled(tunnel.isUnpairing)
        .accessibilityLabel("Profile")
        .accessibilityValue(tunnel.selectedServer?.displayName ?? "None")
    }

    private var exitBinding: Binding<Bool> {
        Binding(
            get: { tunnel.effectiveExit },
            set: { tunnel.setExit($0) }
        )
    }

    private var statusTitle: String {
        switch tunnel.status {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .disconnecting: return "Disconnecting"
        case .invalid: return "Needs Permission"
        case .disconnected: return "Disconnected"
        }
    }

    private var statusSymbol: String {
        switch tunnel.status {
        case .connected: return "lock.fill"
        case .connecting, .disconnecting: return "arrow.triangle.2.circlepath"
        case .invalid: return "exclamationmark.triangle.fill"
        case .disconnected: return "lock.open"
        }
    }

    private var statusTint: Color {
        switch tunnel.status {
        case .connected: return .green
        case .connecting: return .accentColor
        case .invalid: return .orange
        default: return .secondary
        }
    }

    private var buttonTitle: String {
        switch tunnel.status {
        case .connected, .connecting: return "Disconnect"
        default: return "Connect"
        }
    }

    private var modeLabel: String {
        let home = tunnel.selectedServer?.homeSSIDs ?? []
        if case .disconnect = tunnel.policy.decide(path: tunnel.pathKind, homeSSIDs: home) {
            return "Paused on home Wi‑Fi"
        }
        if case .connect(let full) = tunnel.policy.decide(path: tunnel.pathKind, homeSSIDs: home) {
            return full ? "Full tunnel" : "Split tunnel"
        }
        return "—"
    }

    private var pathCaption: String {
        if tunnel.onHomeWiFi { return "Home Wi‑Fi · tunnel off" }
        switch tunnel.pathKind {
        case .cellular: return "Cellular · trusted by default"
        case .wifi(let id): return tunnel.policy.trustedNetworkIDs.contains(id) ? "Trusted Wi‑Fi" : "Untrusted Wi‑Fi"
        case .other: return "Current network"
        }
    }
}
