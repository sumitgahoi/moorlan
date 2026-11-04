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

    /// Home Wi‑Fi (`ssid:Name`) keeps the tunnel off. Trusted Wi‑Fi is split in automatic mode.
    public func decide(path: PathKind, homeSSIDs: Set<String> = []) -> Decision {
        if case .wifi(let id) = path, id.hasPrefix("ssid:"), homeSSIDs.contains(id) {
            return .disconnect(reason: "On a home Wi‑Fi network")
        }
        if mode == .exit { return .connect(fullTunnel: true) }
        if mode == .split { return .connect(fullTunnel: false) }
        switch path {
        case .cellular: return .connect(fullTunnel: !treatCellularAsTrusted)
        case .wifi(let id): return .connect(fullTunnel: !id.hasPrefix("ssid:") || !trustedNetworkIDs.contains(id))
        case .other: return .connect(fullTunnel: true)
        }
    }

    public func allowedIPs(lease: Lease, fullTunnel: Bool) -> [String] {
        var ips = Set(lease.prefixes.filter { !$0.isEmpty && $0 != "0.0.0.0/0" && $0 != "::/0" })
        for cidr in Self.homeCIDRs(from: lease.lan) { ips.insert(cidr) }
        if fullTunnel { ips.insert("0.0.0.0/0"); ips.insert("::/0") }
        return ips.sorted()
    }

    /// Away-route prefixes from the lease `lan` field (one CIDR or comma-separated).
    public static func homeCIDRs(from lan: String?) -> [String] {
        guard let lan, !lan.isEmpty else { return [] }
        return lan.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    public static func ssidName(from networkID: String) -> String? {
        guard networkID.hasPrefix("ssid:") else { return nil }
        let name = String(networkID.dropFirst(5))
        return name.isEmpty ? nil : name
    }
}

/// Non-secret, per-profile input to the Packet Tunnel extension. The private
/// identity is read separately from the shared Keychain.
public struct TunnelProfile: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var lease: Lease
    public var lan: String?
    public var policy: TunnelPolicy
    public var homeSSIDs: [String]

    public init(server: PairedServer, policy: TunnelPolicy) {
        id = server.id
        name = server.displayName
        lease = server.lease
        // The extension doesn't need the deletion capability.
        lease.unpairToken = nil
        lan = server.lan
        self.policy = policy
        homeSSIDs = server.homeSSIDs.sorted()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        lease = try c.decode(Lease.self, forKey: .lease)
        lan = try c.decodeIfPresent(String.self, forKey: .lan)
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
        try c.encodeIfPresent(lan, forKey: .lan)
        try c.encode(policy, forKey: .policy)
        try c.encode(homeSSIDs, forKey: .homeSSIDs)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, lease, lan, policy, homeSSIDs, homeSSID
    }

    public static func storageKey(_ id: String) -> String { "profile-" + id }
}
