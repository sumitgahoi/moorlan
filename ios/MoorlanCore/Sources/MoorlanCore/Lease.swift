import Foundation

/// What the phone stores after a successful pairing exchange.
public struct Lease: Codable, Equatable, Sendable {
    public var address: String
    public var tunnelNetwork: String
    public var homeNetworks: [String]
    public var publicKey: String
    public var endpoint: String?
    public var mtu: Int?
    public var dnsServers: [String]
    public var dnsSearch: [String]?
    public var unpairToken: String?
    public var persistentKeepalive: Int?
    public var label: String?
    /// Tunnel display name from server site conf (`name`).
    public var name: String?

    enum CodingKeys: String, CodingKey {
        case address
        case tunnelNetwork = "tunnel_network"
        case homeNetworks = "home_networks"
        case publicKey = "public_key"
        case endpoint
        case mtu
        case dnsServers = "dns_servers"
        case dnsSearch = "dns_search"
        case unpairToken = "unpair_token"
        case persistentKeepalive = "persistent_keepalive"
        case label
        case name
    }

    public init(
        address: String,
        tunnelNetwork: String,
        homeNetworks: [String],
        publicKey: String,
        endpoint: String? = nil,
        mtu: Int? = nil,
        dnsServers: [String],
        dnsSearch: [String]? = nil,
        unpairToken: String? = nil,
        persistentKeepalive: Int? = nil,
        label: String? = nil,
        name: String? = nil
    ) {
        self.address = address
        self.tunnelNetwork = tunnelNetwork
        self.homeNetworks = homeNetworks
        self.publicKey = publicKey
        self.endpoint = endpoint
        self.mtu = mtu
        self.dnsServers = dnsServers
        self.dnsSearch = dnsSearch
        self.unpairToken = unpairToken
        self.persistentKeepalive = persistentKeepalive
        self.label = label
        self.name = name
    }
}

public struct PairedServer: Codable, Equatable, Sendable, Identifiable {
    public var id: String { publicKey }
    public var card: QRCard
    public var lease: Lease
    public var pairedAt: Date
    /// Wi‑Fi networks (`ssid:Name`) where the tunnel stays off.
    public var homeSSIDs: Set<String>

    public var publicKey: String { lease.publicKey }
    public var displayName: String {
        if let renamed = card.legacyName?.trimmingCharacters(in: .whitespacesAndNewlines), !renamed.isEmpty {
            return renamed
        }
        if let name = lease.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return card.lanHost ?? "WireGuard"
    }

    public var serverDNSDescription: String {
        let dns = lease.dnsServers.filter { !$0.isEmpty }
        return dns.isEmpty ? "—" : dns.joined(separator: ", ")
    }

    public var serverDNSSearchDescription: String {
        let search = (lease.dnsSearch ?? []).filter { !$0.isEmpty }
        return search.isEmpty ? "—" : search.joined(separator: ", ")
    }

    public var homeNetworksDescription: String {
        let nets = lease.homeNetworks.filter { !$0.isEmpty }
        return nets.isEmpty ? "—" : nets.joined(separator: ", ")
    }

    public init(
        card: QRCard,
        lease: Lease,
        pairedAt: Date = .now,
        homeSSIDs: Set<String> = []
    ) {
        self.card = card
        self.lease = lease
        self.pairedAt = pairedAt
        self.homeSSIDs = homeSSIDs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        card = try c.decode(QRCard.self, forKey: .card)
        lease = try c.decode(Lease.self, forKey: .lease)
        pairedAt = try c.decode(Date.self, forKey: .pairedAt)
        homeSSIDs = try c.decodeIfPresent(Set<String>.self, forKey: .homeSSIDs) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(card, forKey: .card)
        try c.encode(lease, forKey: .lease)
        try c.encode(pairedAt, forKey: .pairedAt)
        try c.encode(homeSSIDs, forKey: .homeSSIDs)
    }

    private enum CodingKeys: String, CodingKey {
        case card, lease, pairedAt, homeSSIDs
    }
}
