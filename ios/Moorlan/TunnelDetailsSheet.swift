import SwiftUI
import MoorlanCore

struct TunnelDetailsSheet: View {
    var server: PairedServer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Name", value: server.displayName)
                    LabeledContent(MoorlanCopy.detailsJoined, value: pairedAtText)
                }

                Section {
                    LabeledContent(MoorlanCopy.detailsAddress, value: server.lease.address)
                    LabeledContent(MoorlanCopy.detailsEndpoint, value: server.lease.endpoint ?? "—")
                    LabeledContent(MoorlanCopy.detailsTunnel, value: server.lease.tunnelNetwork)
                    LabeledContent(MoorlanCopy.detailsHomeNets, value: server.homeNetworksDescription)
                    LabeledContent(MoorlanCopy.detailsDNS, value: server.serverDNSDescription)
                    LabeledContent(MoorlanCopy.detailsSearch, value: server.serverDNSSearchDescription)
                    LabeledContent(MoorlanCopy.detailsKeepalive, value: "\(server.lease.persistentKeepalive ?? 25)s")
                    if let mtu = server.lease.mtu {
                        LabeledContent("MTU", value: "\(mtu)")
                    }
                }

                Section {
                    LabeledContent(MoorlanCopy.detailsKey, value: server.publicKey)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
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

    private var pairedAtText: String {
        server.pairedAt.formatted(date: .abbreviated, time: .shortened)
    }
}
