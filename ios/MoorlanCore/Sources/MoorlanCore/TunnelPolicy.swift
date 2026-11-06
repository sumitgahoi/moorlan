import Foundation

/// Per-network tunnel behavior. Unmarked Wi‑Fi defaults to full; cellular defaults to split.
public enum NetworkRouting: String, Codable, CaseIterable, Sendable {
    case off
    case split
    case full
}

/// Phone-owned routing map. Server lease owns identity and DNS; this owns Off/Split/Full.
public struct TunnelPolicy: Equatable, Codable, Sendable {
    /// Permanent Wi‑Fi map keyed by `ssid:Name`. Missing key → `.full`.
    public var networkRouting: [String: NetworkRouting]
    /// Permanent cellular routing. Default `.split`.
    public var cellularRouting: NetworkRouting
    /// TEMP debug only: when non-empty, replaces lease `dns_servers` for the tunnel.
    public var dnsOverride: [String]?

    public init(
        networkRouting: [String: NetworkRouting] = [:],
        cellularRouting: NetworkRouting = .split,
        dnsOverride: [String]? = nil
    ) {
        self.networkRouting = networkRouting
        self.cellularRouting = cellularRouting
        self.dnsOverride = dnsOverride
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.networkRouting) || c.contains(.cellularRouting) {
            networkRouting = try c.decodeIfPresent([String: NetworkRouting].self, forKey: .networkRouting) ?? [:]
            // Drop non-ssid keys from legacy blobs.
            networkRouting = networkRouting.filter { $0.key.hasPrefix("ssid:") }
            cellularRouting = try c.decodeIfPresent(NetworkRouting.self, forKey: .cellularRouting) ?? .split
            dnsOverride = try c.decodeIfPresent([String].self, forKey: .dnsOverride)
            return
        }
        // Mid-era: mode + trustedNetworkIDs + treatCellularAsTrusted
        let trusted = Set(
            (try c.decodeIfPresent([String].self, forKey: .trustedNetworkIDs) ?? [])
                .filter { $0.hasPrefix("ssid:") }
        )
        var routing: [String: NetworkRouting] = [:]
        for id in trusted { routing[id] = .split }
        networkRouting = routing
        let treatTrusted = try c.decodeIfPresent(Bool.self, forKey: .treatCellularAsTrusted) ?? true
        cellularRouting = treatTrusted ? .split : .full
        dnsOverride = try c.decodeIfPresent([String].self, forKey: .dnsOverride)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(networkRouting, forKey: .networkRouting)
        try c.encode(cellularRouting, forKey: .cellularRouting)
        try c.encodeIfPresent(dnsOverride, forKey: .dnsOverride)
    }

    private enum CodingKeys: String, CodingKey {
        case networkRouting, cellularRouting, dnsOverride
        case trustedNetworkIDs, treatCellularAsTrusted
    }

    /// Lease with optional TEMP DNS override applied (identity fields unchanged).
    public func effectiveLease(_ lease: Lease) -> Lease {
        guard let override = dnsOverride else { return lease }
        let servers = override
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !servers.isEmpty else { return lease }
        var copy = lease
        copy.dnsServers = servers
        return copy
    }

    /// Parses comma-separated IPv4 DNS list. Empty → nil (follow lease). `error` set on bad input.
    public static func parseDNSOverride(_ text: String) -> (servers: [String]?, error: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return (nil, nil) }
        var out: [String] = []
        var seen = Set<String>()
        for part in trimmed.split(separator: ",") {
            let ip = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if ip.isEmpty { continue }
            let octets = ip.split(separator: ".", omittingEmptySubsequences: false)
            guard octets.count == 4,
                  octets.allSatisfy({ UInt8($0) != nil }) else {
                return (nil, "Invalid DNS address: \(ip)")
            }
            if seen.insert(ip).inserted { out.append(ip) }
        }
        return (out.isEmpty ? nil : out, nil)
    }

    public enum PathKind: Equatable, Sendable {
        case cellular, wifi(id: String), other
    }

    public enum Decision: Equatable, Sendable {
        case disconnect(reason: String)
        case connect(fullTunnel: Bool)
    }

    /// Permanent routing for a named Wi‑Fi id (`ssid:…`). Missing → Full.
    public func permanentRouting(forNetworkID id: String) -> NetworkRouting {
        networkRouting[id] ?? .full
    }

    /// SSIDs permanently marked Off (drive on-demand Disconnect rules).
    public var permanentOffNetworkIDs: Set<String> {
        Set(networkRouting.compactMap { $0.value == .off ? $0.key : nil })
    }

    public var permanentOffSSIDNames: [String] {
        permanentOffNetworkIDs.compactMap(Self.ssidName(from:)).sorted()
    }

    /// Decide using the permanent map only (extension + on-demand).
    public func decide(path: PathKind) -> Decision {
        decide(path: path, override: nil)
    }

    /// Decide with an optional temporary override for the current path.
    public func decide(path: PathKind, override: NetworkRouting?) -> Decision {
        if case .wifi(let id) = path {
            if !id.hasPrefix("ssid:") || id == "unidentified" {
                return .disconnect(reason: "Wi‑Fi name unavailable")
            }
            let routing = override ?? permanentRouting(forNetworkID: id)
            return decision(for: routing, offReason: "Off on this network")
        }
        switch path {
        case .cellular:
            let routing = override ?? cellularRouting
            return decision(for: routing, offReason: "Off on cellular")
        case .other:
            return .connect(fullTunnel: true)
        case .wifi:
            return .disconnect(reason: "Wi‑Fi name unavailable")
        }
    }

    private func decision(for routing: NetworkRouting, offReason: String) -> Decision {
        switch routing {
        case .off: return .disconnect(reason: offReason)
        case .split: return .connect(fullTunnel: false)
        case .full: return .connect(fullTunnel: true)
        }
    }

    /// Split: `tunnel_network ∪ home_networks ∪ dns_servers/32`. Full adds `0.0.0.0/0`.
    ///
    /// WireGuardKit applies lease DNS with `NEDNSSettings.matchDomains = [""]`, so every
    /// query goes to those resolvers. Without host routes into the tunnel, iOS blackholes
    /// DNS whenever a resolver is outside `home_networks` (common with public DNS in split).
    ///
    /// Full is IPv4-only: do **not** add `::/0`. The product has no IPv6 tunnel pool or
    /// IPv6 Internet exit; claiming a default IPv6 route blackholes Happy Eyeballs and
    /// makes websites appear dead even when IPv4 DNS and routing work.
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
        for dns in lease.dnsServers {
            let trimmed = dns.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "0.0.0.0/0", trimmed != "::/0" else { continue }
            if trimmed.contains("/") {
                ips.insert(trimmed)
            } else if trimmed.contains(":") {
                ips.insert(trimmed + "/128")
            } else {
                ips.insert(trimmed + "/32")
            }
        }
        if fullTunnel {
            ips.insert("0.0.0.0/0")
        }
        return ips.sorted()
    }

    public static func ssidName(from networkID: String) -> String? {
        guard networkID.hasPrefix("ssid:") else { return nil }
        let name = String(networkID.dropFirst(5))
        return name.isEmpty ? nil : name
    }

    /// Merge former per-server home SSIDs into permanent Off.
    public mutating func applyLegacyHomeSSIDs(_ ids: Set<String>) {
        for id in ids where id.hasPrefix("ssid:") {
            networkRouting[id] = .off
        }
    }
}

/// Non-secret, per-profile input to the Packet Tunnel extension. The private
/// identity is read separately from the shared Keychain. `unpair_token` is stripped.
public struct TunnelProfile: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var lease: Lease
    public var policy: TunnelPolicy

    public init(server: PairedServer, policy: TunnelPolicy) {
        id = server.id
        name = server.displayName
        lease = server.lease
        // App host record keeps unpair_token; the extension never sees it.
        lease.unpairToken = nil
        self.policy = policy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        lease = try c.decode(Lease.self, forKey: .lease)
        lease.unpairToken = nil
        var loaded = try c.decode(TunnelPolicy.self, forKey: .policy)
        // Legacy extension profiles carried homeSSIDs separately.
        if let list = try c.decodeIfPresent([String].self, forKey: .homeSSIDs) {
            loaded.applyLegacyHomeSSIDs(Set(list))
        } else if let legacy = try c.decodeIfPresent(String.self, forKey: .homeSSID), !legacy.isEmpty {
            loaded.applyLegacyHomeSSIDs(["ssid:" + legacy])
        }
        policy = loaded
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(lease, forKey: .lease)
        try c.encode(policy, forKey: .policy)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, lease, policy, homeSSIDs, homeSSID
    }

    public static func storageKey(_ id: String) -> String { "profile-" + id }
}
