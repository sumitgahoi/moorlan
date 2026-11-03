import Foundation

enum AppIdentity {
    static let appBundleID = "app.peerdoor.ios"
    static let tunnelBundleID = "app.peerdoor.ios.tunnel"
    static let appGroup = "group.app.peerdoor"
    static let tunnelProviderDescription = "PeerDoor"
    static var keychainAccessGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "PeerDoorKeychainAccessGroup") as? String
    }
    static let configKey = "active-wg-quick-config"
    static let serverNameKey = "active-server-name"
}
