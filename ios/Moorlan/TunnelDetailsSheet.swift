import SwiftUI
import MoorlanCore

struct TunnelDetailsSheet: View {
    var server: PairedServer
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.dismiss) private var dismiss

    private var isOnDemandDefault: Bool {
        server.id == tunnel.onDemandActiveID
    }

    var body: some View {
        NavigationStack {
            List {
                if isOnDemandDefault {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(MoorlanCopy.onDemandDefaultTitle, systemImage: "star.fill")
                                .font(.headline)
                                .foregroundStyle(Color.accentColor)
                            Text(MoorlanCopy.onDemandDefaultBody)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                    }
                }

                Section {
                    LabeledContent("Name", value: server.displayName)
                    LabeledContent(MoorlanCopy.detailsAddress, value: server.lease.address)
                    LabeledContent(MoorlanCopy.detailsEndpoint, value: server.lease.endpoint ?? "—")
                    LabeledContent(MoorlanCopy.detailsTunnel, value: server.lease.tunnelNetwork)

                    LabeledContent(MoorlanCopy.detailsPrivateNets) {
                        multiLineValue(server.lease.homeNetworks)
                    }
                    LabeledContent(MoorlanCopy.detailsDNS) {
                        multiLineValue(server.lease.dnsServers)
                    }

                    LabeledContent(MoorlanCopy.detailsSearch, value: server.serverDNSSearchDescription)
                    LabeledContent(MoorlanCopy.detailsKeepalive, value: "\(server.lease.persistentKeepalive ?? 25)s")
                    if let mtu = server.lease.mtu {
                        LabeledContent("MTU", value: "\(mtu)")
                    }
                }
            }
            .navigationTitle(MoorlanCopy.detailsTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func multiLineValue(_ values: [String]) -> some View {
        let items = values.filter { !$0.isEmpty }
        Text(items.isEmpty ? "—" : items.joined(separator: "\n"))
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
    }
}
