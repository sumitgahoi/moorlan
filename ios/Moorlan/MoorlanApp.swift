import SwiftUI

@main
struct MoorlanApp: App {
    @StateObject private var tunnel = TunnelManager()
    @StateObject private var themeStore = ThemeStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(tunnel)
                .environmentObject(themeStore)
                .moorlanTheme(themeStore.theme)
        }
    }
}
