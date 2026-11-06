import SwiftUI
import MoorlanCore

struct HomeView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    var onScan: () -> Void
    var onSettings: () -> Void

    @State private var detailsServer: PairedServer?
    @State private var showRoutingTip = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    routingPicker
                } header: {
                    HStack(spacing: 6) {
                        Text("This network")
                        Button {
                            showRoutingTip = true
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.footnote)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("About Off, Split, and Full")
                    }
                } footer: {
                    Text(MoorlanCopy.homeRoutingFooter)
                }

                Section {
                    Text(tunnel.statusHeadline)
                        .font(.headline)
                    Text(tunnel.statusDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let rates = tunnel.transferRates, tunnel.status == .connected {
                        Text(rates)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(tunnel.transferRatesAccessibility)
                    }
                } header: {
                    Text("Status")
                }

                Section("Tunnels") {
                    ForEach(tunnel.servers) { server in
                        tunnelRow(server)
                    }
                }
            }
            .navigationTitle("Moorlan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onSettings) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel(MoorlanCopy.settingsTitle)
                    .disabled(tunnel.isUnpairing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onScan) {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(MoorlanCopy.scanNavA11y)
                    .disabled(tunnel.isUnpairing)
                }
            }
            .sheet(item: $detailsServer) { server in
                TunnelDetailsSheet(server: server)
            }
            .alert("Off, Split, Full", isPresented: $showRoutingTip) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(MoorlanCopy.routingTip)
            }
        }
    }

    private var routingPicker: some View {
        let disabled = tunnel.currentPathID == nil || tunnel.wifiIdentityMissing || tunnel.isUnpairing
        return Picker("Routing", selection: routingBinding) {
            Text(MoorlanCopy.routingOff).tag(NetworkRouting.off)
            Text(MoorlanCopy.routingSplit).tag(NetworkRouting.split)
            Text(MoorlanCopy.routingFull).tag(NetworkRouting.full)
        }
        .pickerStyle(.segmented)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .accessibilityLabel("Network routing")
        .accessibilityHint(MoorlanCopy.homeRoutingFooter)
    }

    private var routingBinding: Binding<NetworkRouting> {
        Binding(
            get: { tunnel.effectiveRouting ?? .full },
            set: { tunnel.setTemporaryRouting($0) }
        )
    }

    private func tunnelRow(_ server: PairedServer) -> some View {
        let selected = server.id == tunnel.selectedServer?.id
        let isDefault = server.id == tunnel.onDemandActiveID
        return HStack(spacing: 10) {
            Button {
                Task {
                    await tunnel.selectProfile(server.id)
                    await tunnel.applyDesiredState()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.displayName)
                            .font(.body.weight(selected ? .semibold : .regular))
                            .foregroundStyle(.primary)
                        if isDefault {
                            Text(MoorlanCopy.defaultBadge)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(tunnel.isUnpairing)
            .accessibilityLabel(server.displayName)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityHint(MoorlanCopy.pickTunnelA11y)

            Menu {
                if !isDefault {
                    Button(MoorlanCopy.useAsDefault) {
                        Task { await tunnel.setOnDemandActive(server.id) }
                    }
                }
                Button("Details") {
                    detailsServer = server
                }
                Button(MoorlanCopy.removeTunnelA11y, role: .destructive) {
                    Task {
                        await tunnel.selectProfile(server.id)
                        onScan()
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(tunnel.isUnpairing)
        }
    }
}
