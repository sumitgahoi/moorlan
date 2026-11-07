import SwiftUI
import MoorlanCore

struct HomeView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    var onScan: () -> Void
    var onSettings: () -> Void

    @State private var detailsServer: PairedServer?
    @State private var editServer: PairedServer?
    @State private var editName = ""

    private let cardShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        NavigationStack {
            // Discrete cards (Termius / Hypelist-style), not oversized List rows.
            // List + contextMenu lifts the table cell and reads as a shrink.
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(tunnel.servers) { server in
                        let status = badge(for: server)
                        let routing = routingBadge(for: server)
                        TunnelCard(
                            name: server.displayName,
                            badge: status,
                            routingBadge: routing,
                            accent: leadingAccent(for: server, badge: status),
                            disabled: tunnel.isUnpairing,
                            shape: cardShape,
                            onOpen: { detailsServer = server },
                            menu: { tunnelContextMenu(for: server) }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(MoorlanCopy.tunnelsTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onSettings) {
                        Label(MoorlanCopy.settingsTitle, systemImage: "gearshape")
                    }
                    .disabled(tunnel.isUnpairing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onScan) {
                        Label(MoorlanCopy.scanNavA11y, systemImage: "plus")
                    }
                    .disabled(tunnel.isUnpairing)
                }
            }
            .sheet(item: $detailsServer) { server in
                TunnelDetailsSheet(server: server)
            }
            .alert(MoorlanCopy.editTunnelTitle, isPresented: editAlertPresented) {
                TextField(MoorlanCopy.editTunnelTitle, text: $editName)
                    .textInputAutocapitalization(.words)
                Button(MoorlanCopy.editTunnelSave) {
                    if let server = editServer {
                        tunnel.renameServer(server.id, displayName: editName)
                    }
                    editServer = nil
                }
                Button("Cancel", role: .cancel) {
                    editServer = nil
                }
            }
        }
    }

    private var editAlertPresented: Binding<Bool> {
        Binding(
            get: { editServer != nil },
            set: { if !$0 { editServer = nil } }
        )
    }

    private var routingMenuEnabled: Bool {
        tunnel.currentPathID != nil && tunnel.isPathStable && !tunnel.isUnpairing
    }

    @ViewBuilder
    private func tunnelContextMenu(for server: PairedServer) -> some View {
        let current = tunnel.effectiveRouting
        Button {
            tunnel.setTemporaryRouting(.off)
        } label: {
            Label(
                MoorlanCopy.routingOff,
                systemImage: current == .off ? "checkmark.circle.fill" : "pause.circle"
            )
        }
        .disabled(!routingMenuEnabled)

        Button {
            tunnel.setTemporaryRouting(.split)
        } label: {
            Label(
                MoorlanCopy.routingSplit,
                systemImage: current == .split ? "checkmark.circle.fill" : "arrow.triangle.branch"
            )
        }
        .disabled(!routingMenuEnabled)

        Button {
            tunnel.setTemporaryRouting(.full)
        } label: {
            Label(
                MoorlanCopy.routingFull,
                systemImage: current == .full ? "checkmark.circle.fill" : "globe"
            )
        }
        .disabled(!routingMenuEnabled)

        Divider()

        Button {
            editName = server.displayName
            editServer = server
        } label: {
            Label(MoorlanCopy.editTunnel, systemImage: "pencil")
        }

        Divider()

        Button(role: .destructive) {
            onScan()
        } label: {
            Label(MoorlanCopy.removeTunnelA11y, systemImage: "trash")
        }

        Divider()

        Button {
            detailsServer = server
        } label: {
            Label(MoorlanCopy.detailsMenu, systemImage: "info.circle")
        }
    }

    private func isSelected(_ server: PairedServer) -> Bool {
        server.id == tunnel.selectedServer?.id
    }

    private func badge(for server: PairedServer) -> String? {
        guard isSelected(server) else {
            return server.id == tunnel.onDemandActiveID ? MoorlanCopy.defaultBadge : nil
        }
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
            return server.id == tunnel.onDemandActiveID ? MoorlanCopy.defaultBadge : nil
        }
    }

    /// Split / Full when connected (Full while the path is settling).
    private func routingBadge(for server: PairedServer) -> String? {
        guard isSelected(server), !tunnel.isOffOnCurrentPath else { return nil }
        let live = tunnel.status == .connected
            || (tunnel.status == .connecting && !tunnel.isPathStable)
        guard live else { return nil }
        return tunnel.effectiveFullTunnel ? MoorlanCopy.routingFull : MoorlanCopy.routingSplit
    }

    /// Leading card rail (Runna-style), colored by status.
    private func leadingAccent(for server: PairedServer, badge: String?) -> Color {
        switch badge {
        case MoorlanCopy.connectedBadge:
            return .green
        case MoorlanCopy.connecting:
            return Color.accentColor
        case MoorlanCopy.needsAttention:
            return .red
        case MoorlanCopy.offHereBadge:
            return Color(.tertiaryLabel)
        case MoorlanCopy.defaultBadge:
            return Color.accentColor
        default:
            return server.id == tunnel.onDemandActiveID
                ? Color.accentColor
                : Color(.tertiaryLabel)
        }
    }
}

/// Tunnel card: tap opens details; ⋯ and long-press share the same actions.
/// Flicker fix: no Button highlight under long-press; flatten before contextMenu;
/// preview matches the live card width so the lift doesn’t resize.
private struct TunnelCard<MenuContent: View>: View {
    var name: String
    var badge: String?
    var routingBadge: String?
    var accent: Color
    var disabled: Bool
    var shape: RoundedRectangle
    var onOpen: () -> Void
    @ViewBuilder var menu: () -> MenuContent

    @State private var cardWidth: CGFloat = 0

    var body: some View {
        cardContent(showMenuControl: true)
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { cardWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, width in cardWidth = width }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: shape)
            .clipShape(shape)
            .compositingGroup()
            .contentShape(shape)
            .contextMenu {
                menu()
            } preview: {
                cardContent(showMenuControl: false)
                    .frame(width: cardWidth > 0 ? cardWidth : nil)
                    .background(Color(.secondarySystemGroupedBackground), in: shape)
                    .clipShape(shape)
                    .compositingGroup()
            }
            .disabled(disabled)
    }

    @ViewBuilder
    private func cardContent(showMenuControl: Bool) -> some View {
        HStack(spacing: 0) {
            // Runna-style leading rail — flush to the card edge.
            Rectangle()
                .fill(accent)
                .frame(width: 4)
                .accessibilityHidden(true)

            HStack(spacing: 8) {
                TunnelRow(name: name, badge: badge, routingBadge: routingBadge)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !disabled else { return }
                        onOpen()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(name)
                    .accessibilityValue([badge, routingBadge].compactMap { $0 }.joined(separator: ", "))
                    .accessibilityHint(MoorlanCopy.openTunnelDetailsA11y)

                if showMenuControl {
                    Menu(content: menu) {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(disabled)
                    .accessibilityLabel("More for \(name)")
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .padding(.vertical, 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Quiet list row: tunnel name + optional status / routing pills.
private struct TunnelRow: View {
    var name: String
    var badge: String?
    var routingBadge: String?

    var body: some View {
        HStack(spacing: 14) {
            Text(name)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if let badge {
                    StatusPill(text: badge, kind: .status(badge))
                }
                if let routingBadge {
                    StatusPill(text: routingBadge, kind: .routing)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct StatusPill: View {
    enum Kind {
        case status(String)
        case routing
    }

    var text: String
    var kind: Kind

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(background, in: Capsule(style: .continuous))
    }

    private var foreground: Color {
        switch kind {
        case .routing:
            return .secondary
        case .status(let badge):
            switch badge {
            case MoorlanCopy.connectedBadge:
                return .white
            case MoorlanCopy.connecting, MoorlanCopy.defaultBadge:
                return Color.accentColor
            case MoorlanCopy.needsAttention:
                return .white
            default:
                return .secondary
            }
        }
    }

    private var background: Color {
        switch kind {
        case .routing:
            return Color(.tertiarySystemFill)
        case .status(let badge):
            switch badge {
            case MoorlanCopy.connectedBadge:
                return .green
            case MoorlanCopy.connecting, MoorlanCopy.defaultBadge:
                return Color.accentColor.opacity(0.15)
            case MoorlanCopy.needsAttention:
                return .red
            default:
                return Color(.tertiarySystemFill)
            }
        }
    }
}
