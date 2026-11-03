import SwiftUI

struct RootView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var showScanner = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            InkBackground()
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
        .alert("PeerDoor", isPresented: Binding(get: { tunnel.lastError != nil && !showScanner && !showSettings }, set: { if !$0 { tunnel.lastError = nil } })) {
            Button("OK", role: .cancel) { tunnel.lastError = nil }
        } message: { Text(tunnel.lastError ?? "") }
        .sheet(isPresented: $showScanner) {
            ScannerSheet()
                .environmentObject(tunnel)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(tunnel)
        }
    }
}
