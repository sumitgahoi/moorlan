import SwiftUI
import UIKit
import MoorlanCore

struct SettingsView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.dismiss) private var dismiss
    @State private var showUnpairScanner = false
    @State private var showForgetConfirm = false
    @State private var tipTitle = ""
    @State private var tipMessage = ""
    @State private var showTip = false
    @State private var deviceLabelDraft = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Device name", text: $deviceLabelDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { commitDeviceLabel() }
                        .onChange(of: deviceLabelDraft) { _, _ in
                            commitDeviceLabel()
                        }
                } header: {
                    sectionHeader(
                        "This iPhone",
                        tip: "Shown as the peer label on your Moorlan host (moorlan --list-peers). iOS hides the Settings device name from apps, so set it here. Re-pair to update an existing peer."
                    )
                }

                Section {
                    Picker("Away default", selection: modeBinding) {
                        Text("Automatic").tag(TunnelPolicy.Mode.automatic)
                        Text("Home access only").tag(TunnelPolicy.Mode.split)
                        Text("Full protection").tag(TunnelPolicy.Mode.exit)
                    }
                    Toggle(isOn: cellularBinding) {
                        Text("Treat cellular as trusted")
                    }
                } header: {
                    sectionHeader(
                        "Routing",
                        tip: "Automatic: Home keeps the tunnel off; Trusted Wi‑Fi and cellular use home access only; other Wi‑Fi uses full protection. Manual modes override Automatic except Home always disconnects. Away default and Trusted SSIDs are phone-wide (shared across tunnels). DNS comes from the server lease only."
                    )
                }

                Section {
                    if tunnel.currentNetworkID == nil {
                        Text(pathSummary).foregroundStyle(.secondary)
                        if case .wifi = tunnel.pathKind {
                            Button("Allow Wi‑Fi identification") { tunnel.identifyWiFi() }
                        }
                    }

                    ForEach(tunnel.knownNetworkIDs, id: \.self) { id in
                        networkRow(id)
                    }
                } header: {
                    sectionHeader(
                        "Networks",
                        tip: "Home is your house LAN — tunnel off. Trusted is a safe network that is not Home — home access only. Away / unmarked Wi‑Fi uses full protection in Automatic. Home and Trusted are different on purpose."
                    )
                }

                if tunnel.servers.count > 1 {
                    Section {
                        ForEach(tunnel.servers) { server in
                            Button {
                                Task {
                                    await tunnel.selectProfile(server.id)
                                    await tunnel.applyDesiredState()
                                }
                            } label: {
                                HStack {
                                    Text(server.displayName)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if server.id == tunnel.selectedServer?.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(tunnel.isUnpairing)
                        }
                    } header: {
                        sectionHeader(
                            "Tunnels",
                            tip: "Only the selected tunnel auto-activates. Pairing another host adds a tunnel; it does not remove existing ones."
                        )
                    }
                }

                if let server = tunnel.selectedServer {
                    Section {
                        LabeledContent("Host", value: server.displayName)
                        DisclosureGroup("Server lease") {
                            LabeledContent("Client IP", value: server.lease.address)
                            LabeledContent("Endpoint", value: server.lease.endpoint ?? "—")
                            LabeledContent("Tunnel network", value: server.lease.tunnelNetwork)
                            LabeledContent("Home networks", value: server.homeNetworksDescription)
                            LabeledContent("DNS", value: server.serverDNSDescription)
                            LabeledContent("Search domains", value: server.serverDNSSearchDescription)
                            LabeledContent("Keepalive", value: "\(server.lease.persistentKeepalive ?? 25)s")
                            if let mtu = server.lease.mtu {
                                LabeledContent("MTU", value: "\(mtu)")
                            }
                            LabeledContent("Public key", value: String(server.publicKey.prefix(20)) + "…")
                        }
                        Button(tunnel.isUnpairing ? "Deleting…" : "Unpair with QR", role: .destructive) {
                            showUnpairScanner = true
                        }
                        .disabled(tunnel.isUnpairing)
                        Button("Remove from this iPhone", role: .destructive) {
                            showForgetConfirm = true
                        }
                        .disabled(tunnel.isUnpairing)
                    } header: {
                        sectionHeader(
                            "Paired host",
                            tip: "Read-only lease from the server. Prefer Unpair with QR on Home Wi‑Fi so the host deletes the peer. Remove from this iPhone only clears local VPN settings if the server already unpaired or cleanup got stuck."
                        )
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(tunnel.isUnpairing)
            .sheet(isPresented: $showUnpairScanner) {
                ScannerSheet()
                    .environmentObject(tunnel)
            }
            .alert(tipTitle, isPresented: $showTip) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(tipMessage)
            }
            .confirmationDialog(
                "Remove \(tunnel.selectedServer?.displayName ?? "this host") from this iPhone?",
                isPresented: $showForgetConfirm,
                titleVisibility: .visible
            ) {
                Button("Remove from this iPhone", role: .destructive) {
                    guard let server = tunnel.selectedServer else { return }
                    Task {
                        await tunnel.forgetLocalHost(server)
                        if tunnel.servers.isEmpty { dismiss() }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Deletes the local VPN profile only. If the Moorlan host still has this peer, run moorlan --unpair there or re-pair later.")
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        commitDeviceLabel()
                        dismiss()
                    }
                    .disabled(tunnel.isUnpairing)
                }
            }
            .onAppear {
                deviceLabelDraft = tunnel.deviceLabel
            }
        }
    }

    private func commitDeviceLabel() {
        let trimmed = deviceLabelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != tunnel.deviceLabel {
            tunnel.deviceLabel = trimmed.isEmpty ? UIDevice.current.name : trimmed
            deviceLabelDraft = tunnel.deviceLabel
        }
    }

    private func networkRow(_ id: String) -> some View {
        let role = tunnel.networkRole(for: id)
        let isCurrent = id == tunnel.currentNetworkID
        return Menu {
            ForEach(TunnelManager.NetworkRole.allCases, id: \.self) { option in
                Button {
                    tunnel.setNetworkRole(option, for: id)
                } label: {
                    if option == role {
                        Label(roleTitle(option), systemImage: "checkmark")
                    } else {
                        Text(roleTitle(option))
                    }
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(tunnel.displayNetworkName(id))
                            .foregroundStyle(.primary)
                        if isCurrent {
                            Text("Current")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.2), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(roleSubtitle(role))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .disabled(tunnel.isUnpairing)
        .accessibilityLabel(tunnel.displayNetworkName(id))
        .accessibilityValue(roleTitle(role))
    }

    private func sectionHeader(_ title: String, tip: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Button {
                tipTitle = title
                tipMessage = tip
                showTip = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.footnote)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About \(title)")
        }
    }

    private func roleTitle(_ role: TunnelManager.NetworkRole) -> String {
        switch role {
        case .home: return "Home"
        case .trusted: return "Trusted"
        case .away: return "Away"
        }
    }

    private func roleSubtitle(_ role: TunnelManager.NetworkRole) -> String {
        switch role {
        case .home: return "Home · tunnel off"
        case .trusted: return "Trusted · home access only"
        case .away: return "Away · full protection"
        }
    }

    private var modeBinding: Binding<TunnelPolicy.Mode> {
        Binding(get: { tunnel.policy.mode }, set: { tunnel.policy.mode = $0; tunnel.savePolicy() })
    }

    private var cellularBinding: Binding<Bool> {
        Binding(
            get: { tunnel.policy.treatCellularAsTrusted },
            set: {
                tunnel.policy.treatCellularAsTrusted = $0
                tunnel.savePolicy()
            }
        )
    }

    private var pathSummary: String {
        switch tunnel.pathKind {
        case .cellular: return "On cellular"
        case .wifi: return "On Wi‑Fi — allow identification to name this network"
        case .other: return "No Wi‑Fi identity yet"
        }
    }
}
