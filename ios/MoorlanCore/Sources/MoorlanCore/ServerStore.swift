import Foundation

public struct ServerStore {
    private let defaults: UserDefaults
    private let key = "paired-servers"
    private let policyKey = "tunnel-policy"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadServers() throws -> [PairedServer] {
        guard let data = defaults.data(forKey: key) else { return [] }
        do {
            return try JSONDecoder().decode([PairedServer].self, from: data)
        } catch {
            throw MoorlanError.storageFailed
        }
    }

    public func saveServers(_ servers: [PairedServer]) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(servers)
        } catch {
            throw MoorlanError.storageFailed
        }
        defaults.set(data, forKey: key)
    }

    public func upsert(_ server: PairedServer) throws {
        var servers = try loadServers().filter { $0.publicKey != server.publicKey }
        servers.insert(server, at: 0)
        try saveServers(servers)
    }

    public func loadPolicy() -> TunnelPolicy {
        guard let data = defaults.data(forKey: policyKey) else { return TunnelPolicy() }
        if let current = try? JSONDecoder().decode(TunnelPolicy.self, from: data) { return current }
        if let old = try? JSONDecoder().decode(LegacyPolicy.self, from: data) {
            return TunnelPolicy(mode: old.exitNodeEnabled ? .exit : .automatic,
                trustedNetworkIDs: Set(old.trustedNetworkIDs.filter { $0.hasPrefix("ssid:") }),
                treatCellularAsTrusted: old.treatCellularAsTrusted)
        }
        // Corrupt policy blob: fall back to defaults rather than wiping trusted SSIDs silently mid-session.
        return TunnelPolicy()
    }

    public func savePolicy(_ policy: TunnelPolicy) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(policy)
        } catch {
            throw MoorlanError.storageFailed
        }
        defaults.set(data, forKey: policyKey)
    }
}

private struct LegacyPolicy: Codable {
    var exitNodeEnabled: Bool
    var trustedNetworkIDs: [String]
    var treatCellularAsTrusted: Bool
}
