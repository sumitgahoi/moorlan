import SwiftUI

@main
struct PeerDoorApp: App {
    @StateObject private var tunnel = TunnelManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(tunnel)
                .preferredColorScheme(.dark)
        }
    }
}
