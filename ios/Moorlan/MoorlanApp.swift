import SwiftUI

@main
struct MoorlanApp: App {
    @StateObject private var tunnel = TunnelManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(tunnel)
                .preferredColorScheme(.dark)
        }
    }
}
