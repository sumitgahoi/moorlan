import SwiftUI
import MoorlanCore

struct HomeView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    var onScan: () -> Void

    @State private var detailsServer: PairedServer?
    @State private var showRoutingInfo = false
    @State private var toastText: String?
    @State private var toastTask: Task<Void, Never>?

    private let cardShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    RoutingModeTiles(
                        selection: tunnel.effectiveRouting,
                        enabled: routingControlEnabled,
                        onSelect: { tunnel.setRouting($0) },
                        onInfo: { showRoutingInfo = true }
                    )

                    ForEach(tunnel.servers) { server in
                        let status = statusBadge(for: server)
                        let isDefault = server.id == tunnel.onDemandActiveID
                        TunnelCard(
                            name: server.displayName,
                            badge: status,
                            isDefault: isDefault,
                            showDefaultStar: tunnel.servers.count > 1,
                            accent: leadingAccent(for: server, badge: status, isDefault: isDefault),
                            disabled: tunnel.isUnpairing,
                            shape: cardShape,
                            onOpen: { detailsServer = server },
                            onMakeDefault: { makeDefault(server) }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            .background(Color(.systemGroupedBackground))
            .overlay(alignment: .bottom) {
                if let toastText {
                    Text(toastText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(.regularMaterial, in: Capsule(style: .continuous))
                        .padding(.horizontal, 24)
                        .padding(.bottom, 28)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: toastText)
            .navigationTitle(MoorlanCopy.tunnelsTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onScan) {
                        Label(MoorlanCopy.scanNavA11y, systemImage: "camera")
                    }
                    .disabled(tunnel.isUnpairing)
                }
            }
            .sheet(item: $detailsServer) { server in
                TunnelDetailsSheet(server: server)
            }
            .sheet(isPresented: $showRoutingInfo) {
                RoutingPolicyInfoSheet()
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .onDisappear {
                toastTask?.cancel()
                toastTask = nil
            }
        }
    }

    private var routingControlEnabled: Bool {
        tunnel.currentPathID != nil && tunnel.isPathStable && !tunnel.isUnpairing
    }

    private func isSelected(_ server: PairedServer) -> Bool {
        server.id == tunnel.selectedServer?.id
    }

    /// Status only — on-demand default is a card tint + star, not a pill.
    private func statusBadge(for server: PairedServer) -> String? {
        guard isSelected(server) else { return nil }
        if tunnel.isOffOnCurrentPath { return MoorlanCopy.offHereBadge }
        switch tunnel.status {
        case .connected:
            return MoorlanCopy.connectedBadge
        case .connecting:
            // Path flip: Full until settled — keep Connected.
            if !tunnel.isPathStable { return MoorlanCopy.connectedBadge }
            return MoorlanCopy.connecting
        case .disconnecting: return MoorlanCopy.disconnecting
        case .invalid: return MoorlanCopy.needsAttention
        case .disconnected:
            if tunnel.statusReason == "Waiting for a network" { return MoorlanCopy.needNetwork }
            return nil
        }
    }

    /// Leading card rail (Runna-style), colored by status; accent when default.
    private func leadingAccent(for server: PairedServer, badge: String?, isDefault: Bool) -> Color {
        switch badge {
        case MoorlanCopy.connectedBadge:
            return .green
        case MoorlanCopy.connecting:
            return Color.accentColor
        case MoorlanCopy.needsAttention:
            return .red
        case MoorlanCopy.offHereBadge:
            return Color(.tertiaryLabel)
        default:
            return isDefault ? Color.accentColor : Color(.tertiaryLabel)
        }
    }

    private func makeDefault(_ server: PairedServer) {
        guard server.id != tunnel.onDemandActiveID else { return }
        Task {
            await tunnel.setOnDemandActive(server.id)
            showToast(MoorlanCopy.madeDefaultToast(server.displayName))
        }
    }

    private func showToast(_ text: String) {
        toastTask?.cancel()
        toastText = text
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            toastText = nil
            toastTask = nil
        }
    }
}

/// Target / Amazon-style Off · Split · Full switcher for the current path.
private struct RoutingModeTiles: View {
    var selection: NetworkRouting?
    var enabled: Bool
    var onSelect: (NetworkRouting) -> Void
    var onInfo: () -> Void

    private let tileShape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(MoorlanCopy.routingSection)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(action: onInfo) {
                    Image(systemName: "info.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(MoorlanCopy.routingPolicyInfoA11y)
            }
            .padding(.trailing, -10)

            HStack(spacing: 10) {
                ForEach(NetworkRouting.allCases, id: \.self) { option in
                    tile(for: option)
                }
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
        }
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func tile(for option: NetworkRouting) -> some View {
        let selected = selection == option
        Button {
            onSelect(option)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: MoorlanCopy.routingSymbol(option))
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                Text(MoorlanCopy.routingTitle(option))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 6)
            .background(
                selected
                    ? Color.accentColor.opacity(0.12)
                    : Color(.secondarySystemGroupedBackground),
                in: tileShape
            )
            .overlay(
                tileShape.strokeBorder(
                    selected ? Color.accentColor : Color(.separator),
                    lineWidth: selected ? 2 : 1
                )
            )
            .contentShape(tileShape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(MoorlanCopy.routingInfoTitle(option))
        .accessibilityValue(MoorlanCopy.routingInfoBody(option))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// Tunnel card: tap opens details. On-demand default uses a tinted fill + star.
private struct TunnelCard: View {
    var name: String
    var badge: String?
    var isDefault: Bool
    var showDefaultStar: Bool
    var accent: Color
    var disabled: Bool
    var shape: RoundedRectangle
    var onOpen: () -> Void
    var onMakeDefault: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Runna-style leading rail — flush to the card edge.
            Rectangle()
                .fill(accent)
                .frame(width: 4)
                .accessibilityHidden(true)

            Button(action: onOpen) {
                TunnelRow(name: name, badge: badge)
                    .padding(.leading, 16)
                    .padding(.trailing, showDefaultStar ? 8 : 16)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .accessibilityLabel(name)
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(MoorlanCopy.openTunnelDetailsA11y)

            if showDefaultStar {
                Button(action: onMakeDefault) {
                    Image(systemName: isDefault ? "star.fill" : "star")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isDefault ? Color.accentColor : Color(.tertiaryLabel))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(disabled || isDefault)
                .accessibilityLabel(isDefault ? MoorlanCopy.defaultStarA11y : MoorlanCopy.makeDefaultA11y)
                .padding(.trailing, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardFill, in: shape)
        .clipShape(shape)
    }

    private var cardFill: Color {
        if isDefault {
            return Color.accentColor.opacity(0.12)
        }
        return Color(.secondarySystemGroupedBackground)
    }

    private var accessibilityValue: String {
        [badge, isDefault ? MoorlanCopy.defaultBadge : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

/// Quiet list row: tunnel name + optional status pill.
private struct TunnelRow: View {
    var name: String
    var badge: String?

    var body: some View {
        HStack(spacing: 14) {
            Text(name)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let badge {
                StatusPill(text: badge)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct StatusPill: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(background, in: Capsule(style: .continuous))
    }

    private var foreground: Color {
        switch text {
        case MoorlanCopy.connectedBadge:
            return .white
        case MoorlanCopy.connecting:
            return Color.accentColor
        case MoorlanCopy.needsAttention:
            return .white
        default:
            return .secondary
        }
    }

    private var background: Color {
        switch text {
        case MoorlanCopy.connectedBadge:
            return .green
        case MoorlanCopy.connecting:
            return Color.accentColor.opacity(0.15)
        case MoorlanCopy.needsAttention:
            return .red
        default:
            return Color(.tertiarySystemFill)
        }
    }
}
