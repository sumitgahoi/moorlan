import SwiftUI
import UIKit
import MoorlanCore

struct RootView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var showScanner = false
    @State private var invitePayload: String?
    @State private var showSettings = false

    var body: some View {
        Group {
            if tunnel.servers.isEmpty {
                EmptyPairingView(onScan: { openInAppScanner() })
            } else {
                HomeView(
                    onScan: { openInAppScanner() },
                    onSettings: { showSettings = true }
                )
            }
        }
        .onOpenURL(perform: handleOpenURL)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await tunnel.applyDesiredState() } }
        }
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
            MoorlanCopy.useAsDefaultTitle,
            isPresented: Binding(
                get: {
                    tunnel.pendingDefaultPromptServerID != nil
                        && !showScanner
                        && !showSettings
                        && tunnel.presentedError == nil
                },
                set: { if !$0 { tunnel.declinePendingAsDefault() } }
            )
        ) {
            Button(MoorlanCopy.useAsDefaultYes) {
                Task { await tunnel.acceptPendingAsDefault() }
            }
            Button(MoorlanCopy.useAsDefaultNo, role: .cancel) {
                tunnel.declinePendingAsDefault()
            }
        } message: {
            Text(MoorlanCopy.useAsDefaultMessage)
        }
        .sheet(isPresented: $showScanner, onDismiss: { invitePayload = nil }) {
            ScannerSheet(initialPayload: invitePayload)
                .environmentObject(tunnel)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(tunnel)
        }
    }

    private func openInAppScanner() {
        invitePayload = nil
        showScanner = true
    }

    private func handleOpenURL(_ url: URL) {
        guard url.scheme?.lowercased() == "moorlan" else { return }
        invitePayload = url.absoluteString
        showScanner = true
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        tunnel.clearPresentedError()
    }
}
