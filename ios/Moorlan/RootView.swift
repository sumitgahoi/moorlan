import SwiftUI
import UIKit
import MoorlanCore

struct RootView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var showScanner = false
    @State private var showSettings = false
    @State private var showRolesCoach = false

    var body: some View {
        Group {
            if tunnel.servers.isEmpty {
                EmptyPairingView(onScan: { showScanner = true })
            } else {
                HomeView(
                    onScan: { showScanner = true },
                    onSettings: { showSettings = true }
                )
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await tunnel.applyDesiredState() } }
        }
        .onAppear { presentCoachIfNeeded() }
        .onChange(of: tunnel.servers.count) { _, _ in presentCoachIfNeeded() }
        .alert(
            tunnel.presentedError?.title ?? "Moorlan",
            isPresented: Binding(
                get: { tunnel.presentedError != nil && !showScanner && !showSettings },
                set: { if !$0 { tunnel.clearPresentedError() } }
            ),
            presenting: tunnel.presentedError
        ) { error in
            switch error.action {
            case .ok:
                Button("OK", role: .cancel) { tunnel.clearPresentedError() }
            case .retry:
                Button("Retry") {
                    Task { await tunnel.retryAfterError() }
                }
                Button("OK", role: .cancel) { tunnel.clearPresentedError() }
            case .openSettings:
                Button("Open Settings") { openSettings() }
                Button("OK", role: .cancel) { tunnel.clearPresentedError() }
            }
        } message: { error in
            Text(error.message)
        }
        .alert(
            "New Wi‑Fi",
            isPresented: Binding(
                get: { tunnel.pendingNetworkRoleID != nil && !showScanner && !showSettings && !showRolesCoach },
                set: { if !$0 { tunnel.pendingNetworkRoleID = nil } }
            )
        ) {
            if let id = tunnel.pendingNetworkRoleID {
                Button("Home") { tunnel.setNetworkRole(.home, for: id) }
                Button("Trusted") { tunnel.setNetworkRole(.trusted, for: id) }
                Button("Leave as Away", role: .cancel) { tunnel.setNetworkRole(.away, for: id) }
            }
        } message: {
            if let id = tunnel.pendingNetworkRoleID {
                Text("“\(tunnel.displayNetworkName(id))” is new. Home keeps the tunnel off. Trusted uses home access only. Away uses full protection.")
            }
        }
        .alert("Network roles", isPresented: $showRolesCoach) {
            Button("Got it") { tunnel.dismissRolesCoach() }
        } message: {
            Text("Home is your house Wi‑Fi — tunnel off. Trusted is a safe network that isn’t Home — home access only. Away or unknown Wi‑Fi — full protection.")
        }
        .sheet(isPresented: $showScanner) {
            ScannerSheet()
                .environmentObject(tunnel)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(tunnel)
        }
    }

    private func presentCoachIfNeeded() {
        if tunnel.shouldShowRolesCoach {
            showRolesCoach = true
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        tunnel.clearPresentedError()
    }
}
