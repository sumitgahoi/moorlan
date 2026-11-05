import Foundation

/// What the phone stores after a successful pairing exchange.
public struct Lease: Codable, Equatable, Sendable {
    public var address: String
    public var prefixes: [String]
    public var publicKey: String
    public var endpoint: String?
    public var listenPort: Int?
    public var mtu: Int?
    public var lan: String?
    public var dns: [String]?
    public var dnsSearch: [String]?
    public var unpairToken: String?
    public var persistentKeepalive: Int?
    public var label: String?

    enum CodingKeys: String, CodingKey {
        case address
        case prefixes
        case publicKey = "public_key"
        case endpoint
        case listenPort = "listen_port"
        case mtu
        case lan
        case dns
        case dnsSearch = "dns_search"
        case unpairToken = "unpair_token"
        case persistentKeepalive = "persistent_keepalive"
        case label
    }

    public init(
        address: String,
        prefixes: [String],
        publicKey: String,
        endpoint: String? = nil,
        listenPort: Int? = nil,
        mtu: Int? = nil,
        lan: String? = nil,
        dns: [String]? = nil,
        dnsSearch: [String]? = nil,
        unpairToken: String? = nil,
        persistentKeepalive: Int? = nil,
        label: String? = nil
    ) {
        self.address = address
        self.prefixes = prefixes
        self.publicKey = publicKey
        self.endpoint = endpoint
        self.listenPort = listenPort
        self.mtu = mtu
        self.lan = lan
        self.dns = dns
        self.dnsSearch = dnsSearch
        self.unpairToken = unpairToken
        self.persistentKeepalive = persistentKeepalive
        self.label = label
    }
}

public struct PairedServer: Codable, Equatable, Sendable, Identifiable {
    public var id: String { publicKey }
    public var card: QRCard
    public var lease: Lease
    public var pairedAt: Date
    /// Wi‑Fi networks (`ssid:Name`) where the tunnel stays off.
    public var homeSSIDs: Set<String>
    /// Phone-only overrides (DNS / MTU / keepalive). Lease identity stays server-owned.
    public var client: ClientTunnelSettings

    public var publicKey: String { lease.publicKey }
    public var lan: String? { lease.lan ?? card.legacyLAN }
    public var displayName: String { card.legacyName ?? card.lanHost ?? "WireGuard" }

    public var serverDNSDescription: String {
        let dns = (lease.dns ?? []).filter { !$0.isEmpty }
        return dns.isEmpty ? "—" : dns.joined(separator: ", ")
    }

    public var serverDNSSearchDescription: String {
        let search = (lease.dnsSearch ?? []).filter { !$0.isEmpty }
        return search.isEmpty ? "—" : search.joined(separator: ", ")
    }

    public init(
        card: QRCard,
        lease: Lease,
        pairedAt: Date = .now,
        homeSSIDs: Set<String> = [],
        client: ClientTunnelSettings = ClientTunnelSettings()
    ) {
        self.card = card
        self.lease = lease
        self.pairedAt = pairedAt
        self.homeSSIDs = homeSSIDs
        self.client = client
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        card = try c.decode(QRCard.self, forKey: .card)
        lease = try c.decode(Lease.self, forKey: .lease)
        pairedAt = try c.decode(Date.self, forKey: .pairedAt)
        homeSSIDs = try c.decodeIfPresent(Set<String>.self, forKey: .homeSSIDs) ?? []
        client = try c.decodeIfPresent(ClientTunnelSettings.self, forKey: .client) ?? ClientTunnelSettings()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(card, forKey: .card)
        try c.encode(lease, forKey: .lease)
        try c.encode(pairedAt, forKey: .pairedAt)
        try c.encode(homeSSIDs, forKey: .homeSSIDs)
        if client != ClientTunnelSettings() {
            try c.encode(client, forKey: .client)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case card, lease, pairedAt, homeSSIDs, client
    }
}
