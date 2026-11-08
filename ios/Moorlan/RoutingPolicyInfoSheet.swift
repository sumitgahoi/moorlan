import SwiftUI
import MoorlanCore

/// Sparse explainer for Off / Split / Full Tunnel.
struct RoutingPolicyInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(NetworkRouting.allCases, id: \.self) { option in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: MoorlanCopy.routingSymbol(option))
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .center)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(MoorlanCopy.routingInfoTitle(option))
                                .font(.body.weight(.semibold))
                            Text(MoorlanCopy.routingInfoBody(option))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 10)
                    .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                }
            }
            .listStyle(.plain)
            .navigationTitle(MoorlanCopy.routingPolicySection)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
