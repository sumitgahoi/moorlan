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

    public var publicKey: String { lease.publicKey }
    public var lan: String? { lease.lan ?? card.legacyLAN }
    public var displayName: String { card.legacyName ?? card.lanHost ?? "WireGuard" }

    public init(card: QRCard, lease: Lease, pairedAt: Date = .now) {
        self.card = card
        self.lease = lease
        self.pairedAt = pairedAt
    }
}
