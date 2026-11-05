import Foundation

/// Network defaults are automatic; a user can explicitly select split or exit.
public struct TunnelPolicy: Equatable, Codable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case automatic, split, exit
    }
    public var mode: Mode
    public var trustedNetworkIDs: Set<String>
    public var treatCellularAsTrusted: Bool

    public init(mode: Mode = .automatic, trustedNetworkIDs: Set<String> = [], treatCellularAsTrusted: Bool = true) {
        self.mode = mode
        self.trustedNetworkIDs = trustedNetworkIDs
        self.treatCellularAsTrusted = treatCellularAsTrusted
    }
    public enum PathKind: Equatable, Sendable {
        case cellular, wifi(id: String), other
    }
    public enum Decision: Equatable, Sendable {
        case disconnect(reason: String)
        case connect(fullTunnel: Bool)
    }

    /// Home Wi‑Fi keeps the tunnel off and wins over manual exit/split.
    /// Trusted Wi‑Fi and cellular (when trusted) use subnet; Away named Wi‑Fi uses exit.
    /// Wi‑Fi with unknown SSID fails closed (disconnect) — never exit — to avoid hairpin.
    public func decide(path: PathKind, homeSSIDs: Set<String> = []) -> Decision {
        if case .wifi(let id) = path {
            if id.hasPrefix("ssid:"), homeSSIDs.contains(id) {
                return .disconnect(reason: "Off at home")
            }
            // Fail closed: unidentified / non-SSID fingerprints must not become Away/exit.
            if !id.hasPrefix("ssid:") || id == "unidentified" {
                return .disconnect(reason: "Wi‑Fi name unavailable")
            }
        }
        if mode == .exit { return .connect(fullTunnel: true) }
        if mode == .split { return .connect(fullTunnel: false) }
        switch path {
        case .cellular: return .connect(fullTunnel: !treatCellularAsTrusted)
        case .wifi(let id): return .connect(fullTunnel: !trustedNetworkIDs.contains(id))
        case .other: return .connect(fullTunnel: true)
        }
    }

    /// Split: `tunnel_network ∪ home_networks`. Exit adds default routes.
    public func allowedIPs(lease: Lease, fullTunnel: Bool) -> [String] {
        var ips = Set<String>()
        let tunnel = lease.tunnelNetwork.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tunnel.isEmpty, tunnel != "0.0.0.0/0", tunnel != "::/0" {
            ips.insert(tunnel)
        }
        for cidr in lease.homeNetworks {
            let trimmed = cidr.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "0.0.0.0/0", trimmed != "::/0" else { continue }
            ips.insert(trimmed)
        }
        if fullTunnel {
            ips.insert("0.0.0.0/0")
            ips.insert("::/0")
        }
        return ips.sorted()
    }

    public static func ssidName(from networkID: String) -> String? {
        guard networkID.hasPrefix("ssid:") else { return nil }
        let name = String(networkID.dropFirst(5))
        return name.isEmpty ? nil : name
    }
}

/// Non-secret, per-profile input to the Packet Tunnel extension. The private
/// identity is read separately from the shared Keychain. `unpair_token` is stripped.
public struct TunnelProfile: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var lease: Lease
    public var policy: TunnelPolicy
    public var homeSSIDs: [String]

    public init(server: PairedServer, policy: TunnelPolicy) {
        id = server.id
        name = server.displayName
        lease = server.lease
        // App host record keeps unpair_token; the extension never sees it.
        lease.unpairToken = nil
        self.policy = policy
        homeSSIDs = server.homeSSIDs.sorted()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        lease = try c.decode(Lease.self, forKey: .lease)
        lease.unpairToken = nil
        policy = try c.decode(TunnelPolicy.self, forKey: .policy)
        if let list = try c.decodeIfPresent([String].self, forKey: .homeSSIDs) {
            homeSSIDs = list
        } else if let legacy = try c.decodeIfPresent(String.self, forKey: .homeSSID), !legacy.isEmpty {
            homeSSIDs = ["ssid:" + legacy]
        } else {
            homeSSIDs = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(lease, forKey: .lease)
        try c.encode(policy, forKey: .policy)
        try c.encode(homeSSIDs, forKey: .homeSSIDs)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, lease, policy, homeSSIDs, homeSSID
    }

    public static func storageKey(_ id: String) -> String { "profile-" + id }
}
