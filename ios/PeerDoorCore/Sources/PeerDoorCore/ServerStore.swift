import Foundation

public struct ServerStore {
    private let defaults: UserDefaults
    private let key = "paired-servers"
    private let policyKey = "tunnel-policy"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadServers() -> [PairedServer] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([PairedServer].self, from: data)) ?? []
    }

    public func saveServers(_ servers: [PairedServer]) {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        defaults.set(data, forKey: key)
    }

    public func upsert(_ server: PairedServer) {
        var servers = loadServers().filter { $0.publicKey != server.publicKey }
        servers.insert(server, at: 0)
        saveServers(servers)
    }

    public func loadPolicy() -> TunnelPolicy {
        guard let data = defaults.data(forKey: policyKey) else { return TunnelPolicy() }
        if let current = try? JSONDecoder().decode(TunnelPolicy.self, from: data) { return current }
        if let old = try? JSONDecoder().decode(LegacyPolicy.self, from: data) {
            return TunnelPolicy(mode: old.exitNodeEnabled ? .exit : .automatic,
                trustedNetworkIDs: Set(old.trustedNetworkIDs.filter { $0.hasPrefix("ssid:") }),
                treatCellularAsTrusted: old.treatCellularAsTrusted)
        }
        return TunnelPolicy()
    }
    public func savePolicy(_ policy: TunnelPolicy) {
        if let data = try? JSONEncoder().encode(policy) { defaults.set(data, forKey: policyKey) }
    }
}
private struct LegacyPolicy: Codable {
    var exitNodeEnabled: Bool
    var trustedNetworkIDs: [String]
    var treatCellularAsTrusted: Bool
}
