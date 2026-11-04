import Foundation

enum AppIdentity {
    static let appBundleID = "app.moorlan.ios"
    static let tunnelBundleID = "app.moorlan.ios.tunnel"
    static let appGroup = "group.app.moorlan"
    static let tunnelProviderDescription = "Moorlan"
    static var keychainAccessGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "MoorlanKeychainAccessGroup") as? String
    }
    static let configKey = "active-wg-quick-config"
    static let serverNameKey = "active-server-name"
}
