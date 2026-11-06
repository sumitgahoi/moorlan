import SwiftUI
import MoorlanCore

/// App-wide settings — permanent Off/Split/Full for cellular and Wi‑Fi.
struct SettingsView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.dismiss) private var dismiss
    @State private var tipTitle = ""
    @State private var tipMessage = ""
    @State private var showTip = false
    @State private var dnsOverrideText = ""
    @State private var dnsErrorMessage = ""
    @State private var showDNSError = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: cellularBinding) {
                        ForEach(NetworkRouting.allCases, id: \.self) { option in
                            Text(MoorlanCopy.routingTitle(option)).tag(option)
                        }
                    } label: {
                        Text("Routing")
                    }
                    .disabled(tunnel.isUnpairing)
                } header: {
                    sectionHeader(MoorlanCopy.cellularSection, tip: MoorlanCopy.routingTip)
                } footer: {
                    Text(MoorlanCopy.settingsCellularFooter)
                }

                Section {
                    if tunnel.currentNetworkID == nil {
                        Text(pathSummary).foregroundStyle(.secondary)
                        if case .wifi = tunnel.pathKind {
                            Button(MoorlanCopy.allowWifiName) { tunnel.identifyWiFi() }
                        }
                    }

                    ForEach(tunnel.knownNetworkIDs, id: \.self) { id in
                        networkRow(id)
                    }
                } header: {
                    sectionHeader(MoorlanCopy.wifiSection, tip: MoorlanCopy.routingTip)
                } footer: {
                    Text(MoorlanCopy.settingsNetworksFooter)
                }

                Section {
                    TextField(dnsPlaceholder, text: $dnsOverrideText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                        .disabled(tunnel.isUnpairing)
                        .onSubmit { commitDNSOverride() }
                } header: {
                    Text(MoorlanCopy.dnsTempHeader)
                } footer: {
                    Text(MoorlanCopy.dnsTempFooter)
                }
            }
            .navigationTitle(MoorlanCopy.settingsTitle)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(tunnel.isUnpairing)
            .onAppear { dnsOverrideText = dnsOverrideDisplay }
            .alert(tipTitle, isPresented: $showTip) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(tipMessage)
            }
            .alert(MoorlanCopy.dnsTempInvalidTitle, isPresented: $showDNSError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(dnsErrorMessage)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if commitDNSOverride() { dismiss() }
                    }
                    .disabled(tunnel.isUnpairing)
                }
            }
        }
    }

    private func networkRow(_ id: String) -> some View {
        let routing = tunnel.permanentRouting(forNetworkID: id)
        let isCurrent = id == tunnel.currentNetworkID
        return Menu {
            ForEach(NetworkRouting.allCases, id: \.self) { option in
                Button {
                    tunnel.setPermanentRouting(option, forNetworkID: id)
                } label: {
                    if option == routing {
                        Label(MoorlanCopy.routingTitle(option), systemImage: "checkmark")
                    } else {
                        Text(MoorlanCopy.routingTitle(option))
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
                            Text(MoorlanCopy.hereNow)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.2), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(MoorlanCopy.routingSubtitle(routing))
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
        .accessibilityValue(MoorlanCopy.routingTitle(routing))
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

    private var cellularBinding: Binding<NetworkRouting> {
        Binding(
            get: { tunnel.policy.cellularRouting },
            set: { tunnel.setPermanentCellularRouting($0) }
        )
    }

    private var pathSummary: String {
        switch tunnel.pathKind {
        case .cellular: return MoorlanCopy.onCellular
        case .wifi: return MoorlanCopy.onWifiNeedName
        case .other: return MoorlanCopy.noWifiYet
        }
    }

    private var dnsOverrideDisplay: String {
        (tunnel.policy.dnsOverride ?? []).joined(separator: ", ")
    }

    private var dnsPlaceholder: String {
        let lease = tunnel.selectedServer?.lease.dnsServers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        if lease.isEmpty { return MoorlanCopy.dnsTempPlaceholder }
        return lease.joined(separator: ", ")
    }

    @discardableResult
    private func commitDNSOverride() -> Bool {
        let parsed = TunnelPolicy.parseDNSOverride(dnsOverrideText)
        if let error = parsed.error {
            dnsErrorMessage = error
            showDNSError = true
            return false
        }
        let next = parsed.servers
        if next != tunnel.policy.dnsOverride {
            tunnel.policy.dnsOverride = next
            tunnel.savePolicyAndRestartTunnel()
        }
        return true
    }
}
