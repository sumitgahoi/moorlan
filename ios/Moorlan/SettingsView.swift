import SwiftUI
import UIKit
import MoorlanCore

struct SettingsView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.dismiss) private var dismiss
    @State private var showUnpairScanner = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Routing mode", selection: modeBinding) {
                        Text("Automatic").tag(TunnelPolicy.Mode.automatic)
                        Text("Subnet only").tag(TunnelPolicy.Mode.split)
                        Text("Exit node").tag(TunnelPolicy.Mode.exit)
                    }
                    Toggle(isOn: cellularBinding) {
                        settingLabel(
                            "Treat cellular as trusted",
                            detail: "Trusted networks stay split-tunnel unless Exit node is on. Cellular starts trusted."
                        )
                    }
                } header: {
                    Text("Tunnel policy")
                }

                Section {
                    if let id = tunnel.currentNetworkID {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(displayName(id))
                                Text(homeCaption(for: id))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if tunnel.selectedServer?.homeSSIDs.contains(id) == true {
                                Button("Remove") { tunnel.removeHomeNetwork(id) }
                            } else {
                                Button("Add") { tunnel.addCurrentHomeNetwork() }
                            }
                        }
                    } else {
                        Text(pathSummary).foregroundStyle(.secondary)
                        if case .wifi = tunnel.pathKind {
                            Button("Allow Wi-Fi identification") { tunnel.identifyWiFi() }
                            Text("Allow precise location for Wi-Fi identification so home networks can be added without typing.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }

                    ForEach(homeSSIDList, id: \.self) { id in
                        HStack {
                            Text(displayName(id))
                            Spacer()
                            Button("Remove", role: .destructive) {
                                tunnel.removeHomeNetwork(id)
                            }
                        }
                    }
                } header: {
                    Text("Home Wi‑Fi (tunnel off)")
                } footer: {
                    Text("Join each home SSID and tap Add. The tunnel stays off on these networks. Away routes still use the server’s home CIDRs.")
                }

                Section {
                    if let id = tunnel.currentNetworkID, tunnel.selectedServer?.homeSSIDs.contains(id) != true {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(displayName(id))
                                Text(tunnel.policy.trustedNetworkIDs.contains(id) ? "Trusted exception" : "Untrusted · full tunnel")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if tunnel.policy.trustedNetworkIDs.contains(id) {
                                Button("Remove") { tunnel.untrustCurrentNetwork() }
                            } else {
                                Button("Trust") { tunnel.trustCurrentNetwork() }
                            }
                        }
                    }

                    ForEach(Array(tunnel.policy.trustedNetworkIDs).filter { $0 != tunnel.currentNetworkID }.sorted(), id: \.self) { id in
                        HStack {
                            Text(displayName(id))
                            Spacer()
                            Button("Remove", role: .destructive) {
                                tunnel.policy.trustedNetworkIDs.remove(id)
                                tunnel.savePolicy()
                            }
                        }
                    }
                    if let settings = URL(string: UIApplication.openSettingsURLString) {
                        Link("Open iPhone Settings", destination: settings)
                    }
                } header: {
                    Text("Trusted Wi‑Fi exceptions")
                } footer: {
                    Text("Automatic mode uses exit routing on untrusted Wi‑Fi and subnet routing on trusted Wi‑Fi and cellular. Home Wi‑Fi always disconnects.")
                }

                if let server = tunnel.selectedServer {
                    Section("Paired host") {
                        LabeledContent("Host", value: server.displayName)
                        LabeledContent("Public key", value: String(server.publicKey.prefix(20)) + "…")
                        LabeledContent("Home CIDRs", value: server.lan ?? "Unknown")
                        LabeledContent("Client IP", value: server.lease.address)
                        Button(tunnel.isUnpairing ? "Deleting…" : "Delete profile", role: .destructive) {
                            showUnpairScanner = true
                        }
                        .disabled(tunnel.isUnpairing)
                        Text("Run moorlan --unpair on the server, then scan its QR on home Wi‑Fi. The profile is kept if the server cannot confirm removal.")
                            .font(.footnote).foregroundStyle(.secondary)
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
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(tunnel.isUnpairing)
                }
            }
        }
    }

    private var homeSSIDList: [String] {
        guard let current = tunnel.currentNetworkID else {
            return Array(tunnel.selectedServer?.homeSSIDs ?? []).sorted()
        }
        return Array(tunnel.selectedServer?.homeSSIDs ?? []).filter { $0 != current }.sorted()
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
        case .wifi: return "On Wi‑Fi"
        case .other: return "No Wi‑Fi identity yet"
        }
    }

    private func homeCaption(for id: String) -> String {
        if tunnel.selectedServer?.homeSSIDs.contains(id) == true {
            return "Home · tunnel off"
        }
        return "Not marked as home"
    }

    private func displayName(_ id: String) -> String {
        TunnelPolicy.ssidName(from: id) ?? id
    }

    private func settingLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
