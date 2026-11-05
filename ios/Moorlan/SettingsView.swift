import SwiftUI
import UIKit
import MoorlanCore

struct SettingsView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.dismiss) private var dismiss
    @State private var showUnpairScanner = false
    @State private var tipTitle = ""
    @State private var tipMessage = ""
    @State private var showTip = false
    @State private var deviceLabelDraft = ""
    @State private var dnsDraft = ""
    @State private var dnsSearchDraft = ""
    @State private var keepaliveDraft = ""
    @State private var mtuDraft = ""
    @State private var clientError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Device name", text: $deviceLabelDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { commitDeviceLabel() }
                        .onChange(of: deviceLabelDraft) { _, _ in
                            // Commit as the user types so pair uses the latest value.
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
                        Text("Home LAN only").tag(TunnelPolicy.Mode.split)
                        Text("Exit Node").tag(TunnelPolicy.Mode.exit)
                    }
                    Toggle(isOn: cellularBinding) {
                        Text("Treat cellular as trusted")
                    }
                } header: {
                    sectionHeader(
                        "Routing",
                        tip: "Automatic turns Exit Node on for unknown Wi‑Fi, and off for trusted Wi‑Fi and cellular. The Home screen Exit Node toggle overrides until you choose Automatic again. AllowedIPs follow this mode; they are not free-form."
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
                        tip: "Home keeps the tunnel off. Trusted uses Home LAN only (Exit Node off) in Automatic. Normal / unmarked Wi‑Fi uses Exit Node in Automatic."
                    )
                }

                if let server = tunnel.selectedServer {
                    Section {
                        TextField("DNS servers", text: $dnsDraft, prompt: Text(dnsPlaceholder(server)))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation)
                            .onSubmit { commitClientSettings() }
                        TextField("Search domains", text: $dnsSearchDraft, prompt: Text(dnsSearchPlaceholder(server)))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .onSubmit { commitClientSettings() }
                        Text("Leave blank to use the server lease (or 1.1.1.1 in Exit Node when the lease has no DNS). Server DNS: \(server.serverDNSDescription). Search: \(server.serverDNSSearchDescription)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if server.client.dns != nil || server.client.dnsSearch != nil {
                            Button("Reset DNS to server") {
                                dnsDraft = ""
                                dnsSearchDraft = ""
                                commitClientSettings()
                            }
                        }
                        TextField("Keepalive (seconds)", text: $keepaliveDraft, prompt: Text(keepalivePlaceholder(server)))
                            .keyboardType(.numberPad)
                            .onSubmit { commitClientSettings() }
                        TextField("MTU", text: $mtuDraft, prompt: Text(mtuPlaceholder(server)))
                            .keyboardType(.numberPad)
                            .onSubmit { commitClientSettings() }
                        if let clientError {
                            Text(clientError).font(.footnote).foregroundStyle(.red)
                        }
                        Button("Apply tunnel settings") { commitClientSettings() }
                            .disabled(tunnel.isUnpairing)
                    } header: {
                        sectionHeader(
                            "Tunnel on this iPhone",
                            tip: "DNS, search domains, keepalive, and MTU are phone overrides. They do not change the Moorlan host. Routing/AllowedIPs stay under Away default above."
                        )
                    }

                    Section {
                        LabeledContent("Host", value: server.displayName)
                        DisclosureGroup("Server lease") {
                            LabeledContent("Client IP", value: server.lease.address)
                            LabeledContent("Endpoint", value: server.lease.endpoint ?? "—")
                            LabeledContent("Home CIDRs", value: server.lan ?? "Unknown")
                            LabeledContent("DNS", value: server.serverDNSDescription)
                            LabeledContent("Search domains", value: server.serverDNSSearchDescription)
                            LabeledContent("Keepalive", value: "\(server.lease.persistentKeepalive ?? 25)s")
                            if let mtu = server.lease.mtu {
                                LabeledContent("MTU", value: "\(mtu)")
                            }
                            LabeledContent("Public key", value: String(server.publicKey.prefix(20)) + "…")
                        }
                        Button(tunnel.isUnpairing ? "Deleting…" : "Delete profile", role: .destructive) {
                            showUnpairScanner = true
                        }
                        .disabled(tunnel.isUnpairing)
                    } header: {
                        sectionHeader(
                            "Paired host",
                            tip: "Read-only lease from the server. To delete, run moorlan --unpair on the server, then scan its QR on home Wi‑Fi."
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
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        commitDeviceLabel()
                        commitClientSettings()
                        dismiss()
                    }
                    .disabled(tunnel.isUnpairing)
                }
            }
            .onAppear {
                deviceLabelDraft = tunnel.deviceLabel
                loadClientDrafts()
            }
            .onChange(of: tunnel.selectedServerID) { _, _ in loadClientDrafts() }
        }
    }

    private func commitDeviceLabel() {
        let trimmed = deviceLabelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != tunnel.deviceLabel {
            tunnel.deviceLabel = trimmed.isEmpty ? UIDevice.current.name : trimmed
            deviceLabelDraft = tunnel.deviceLabel
        }
    }

    private func loadClientDrafts() {
        guard let server = tunnel.selectedServer else {
            dnsDraft = ""
            dnsSearchDraft = ""
            keepaliveDraft = ""
            mtuDraft = ""
            clientError = nil
            return
        }
        dnsDraft = ClientTunnelSettings.formatDNS(server.client.dns)
        dnsSearchDraft = ClientTunnelSettings.formatDNSSearch(server.client.dnsSearch)
        if let keepalive = server.client.persistentKeepalive {
            keepaliveDraft = String(keepalive)
        } else {
            keepaliveDraft = ""
        }
        if let mtu = server.client.mtu {
            mtuDraft = String(mtu)
        } else {
            mtuDraft = ""
        }
        clientError = nil
    }

    private func commitClientSettings() {
        guard let server = tunnel.selectedServer else { return }
        let dns: [String]?
        switch ClientTunnelSettings.parseDNS(dnsDraft) {
        case .failure(let error):
            clientError = error.message
            return
        case .success(let value):
            dns = value
        }
        let dnsSearch: [String]?
        switch ClientTunnelSettings.parseDNSSearch(dnsSearchDraft) {
        case .failure(let error):
            clientError = error.message
            return
        case .success(let value):
            dnsSearch = value
        }
        var client = server.client
        client.dns = dns
        client.dnsSearch = dnsSearch
        let keepaliveText = keepaliveDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if keepaliveText.isEmpty {
            client.persistentKeepalive = nil
        } else if let value = Int(keepaliveText), (5...120).contains(value) {
            client.persistentKeepalive = value
        } else {
            clientError = "Keepalive must be 5–120 seconds"
            return
        }
        let mtuText = mtuDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if mtuText.isEmpty {
            client.mtu = nil
        } else if let value = Int(mtuText), (1280...1500).contains(value) {
            client.mtu = value
        } else {
            clientError = "MTU must be 1280–1500"
            return
        }
        clientError = nil
        tunnel.saveClientSettings(client)
        loadClientDrafts()
    }

    private func dnsPlaceholder(_ server: PairedServer) -> String {
        let lease = (server.lease.dns ?? []).filter { !$0.isEmpty }
        if !lease.isEmpty { return lease.joined(separator: ", ") }
        return "1.1.1.1, 1.0.0.1"
    }

    private func dnsSearchPlaceholder(_ server: PairedServer) -> String {
        let search = (server.lease.dnsSearch ?? []).filter { !$0.isEmpty }
        if !search.isEmpty { return search.joined(separator: ", ") }
        return "home.arpa"
    }

    private func keepalivePlaceholder(_ server: PairedServer) -> String {
        "\(server.lease.persistentKeepalive ?? 25)"
    }

    private func mtuPlaceholder(_ server: PairedServer) -> String {
        if let mtu = server.lease.mtu { return "\(mtu)" }
        return "default"
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
        case .normal: return "Normal"
        }
    }

    private func roleSubtitle(_ role: TunnelManager.NetworkRole) -> String {
        switch role {
        case .home: return "Home · tunnel off"
        case .trusted: return "Trusted · Home LAN only"
        case .normal: return "Normal · Exit Node when away"
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
