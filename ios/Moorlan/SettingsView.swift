import SwiftUI
import MoorlanCore

/// App-wide settings — permanent Off/Split/Full for cellular and Wi‑Fi.
struct SettingsView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.dismiss) private var dismiss
    @State private var showRoutingInfo = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    cellularRow

                    if tunnel.currentNetworkID == nil {
                        pathIdentityRow
                    }

                    ForEach(tunnel.knownNetworkIDs, id: \.self) { id in
                        networkRow(id)
                    }
                } header: {
                    routingPolicyHeader
                }
                .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
            }
            .navigationTitle(MoorlanCopy.settingsTitle)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(tunnel.isUnpairing)
            .sheet(isPresented: $showRoutingInfo) {
                RoutingPolicyInfoSheet()
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(tunnel.isUnpairing)
                }
            }
        }
    }

    private var routingPolicyHeader: some View {
        HStack(spacing: 6) {
            Text(MoorlanCopy.routingPolicySection)
            Button {
                showRoutingInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(MoorlanCopy.routingPolicyInfoA11y)
        }
        .textCase(nil)
    }

    private var cellularRow: some View {
        Menu {
            routingMenuChoices(current: tunnel.policy.cellularRouting) { option in
                tunnel.setPermanentCellularRouting(option)
            }
        } label: {
            policyRowLabel(
                title: MoorlanCopy.cellularSection,
                systemImage: "antenna.radiowaves.left.and.right",
                routing: tunnel.policy.cellularRouting
            )
        }
        .disabled(tunnel.isUnpairing)
        .accessibilityLabel(MoorlanCopy.cellularSection)
        .accessibilityValue(MoorlanCopy.routingTitle(tunnel.policy.cellularRouting))
    }

    @ViewBuilder
    private var pathIdentityRow: some View {
        HStack(spacing: 12) {
            Image(systemName: pathIdentityIcon)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .center)
            Text(pathSummary)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if case .wifi = tunnel.pathKind {
                Button(MoorlanCopy.allowWifiName) { tunnel.identifyWiFi() }
            }
        }
    }

    private func networkRow(_ id: String) -> some View {
        let routing = tunnel.permanentRouting(forNetworkID: id)
        let isHome = routing == .off
        return Menu {
            routingMenuChoices(current: routing) { option in
                tunnel.setPermanentRouting(option, forNetworkID: id)
            }
        } label: {
            policyRowLabel(
                title: tunnel.displayNetworkName(id),
                systemImage: "wifi",
                routing: routing,
                isHome: isHome
            )
        }
        .disabled(tunnel.isUnpairing)
        .accessibilityLabel(
            isHome
                ? "\(tunnel.displayNetworkName(id)), \(MoorlanCopy.homeBadge)"
                : tunnel.displayNetworkName(id)
        )
        .accessibilityValue(MoorlanCopy.routingTitle(routing))
    }

    @ViewBuilder
    private func routingMenuChoices(
        current: NetworkRouting,
        onSelect: @escaping (NetworkRouting) -> Void
    ) -> some View {
        ForEach(NetworkRouting.allCases, id: \.self) { option in
            Button {
                onSelect(option)
            } label: {
                Label(
                    MoorlanCopy.routingTitle(option),
                    systemImage: option == current
                        ? "checkmark.circle.fill"
                        : MoorlanCopy.routingSymbol(option)
                )
            }
        }
    }

    private func policyRowLabel(
        title: String,
        systemImage: String,
        routing: NetworkRouting,
        isHome: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .center)

            HStack(spacing: 8) {
                Text(title)
                    .foregroundStyle(.primary)
                if isHome {
                    Image(systemName: "house.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(red: 0.92, green: 0.48, blue: 0.18))
                        .accessibilityHidden(true)
                }
            }

            Spacer(minLength: 8)

            Text(MoorlanCopy.routingTitle(routing))
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private var pathIdentityIcon: String {
        switch tunnel.pathKind {
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .wifi: return "wifi"
        case .other: return "questionmark.circle"
        }
    }

    private var pathSummary: String {
        switch tunnel.pathKind {
        case .cellular: return MoorlanCopy.onCellular
        case .wifi: return MoorlanCopy.onWifiNeedName
        case .other: return MoorlanCopy.noWifiYet
        }
    }
}

/// Sparse explainer for Off / Split / Full Tunnel.
private struct RoutingPolicyInfoSheet: View {
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
