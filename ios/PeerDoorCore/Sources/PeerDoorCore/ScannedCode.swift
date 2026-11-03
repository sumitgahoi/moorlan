import Foundation

/// Public information locating a known server's deletion service. Permission
/// still comes from the per-peer credential saved in the original lease.
public struct UnjoinCard: Codable, Equatable, Sendable {
    public var v: Int
    public var action: String
    public var serverPublicKey: String
    public var unjoinURL: URL

    enum CodingKeys: String, CodingKey {
        case v, action
        case serverPublicKey = "server_public_key"
        case unjoinURL = "unjoin_url"
    }

    public init(v: Int = 2, action: String = "unjoin", serverPublicKey: String, unjoinURL: URL) {
        self.v = v
        self.action = action
        self.serverPublicKey = serverPublicKey
        self.unjoinURL = unjoinURL
    }

    public func validate() throws {
        guard v == 2 else {
            throw PeerDoorError.invalidCard("Unjoin QR version \(v) is unsupported; this app supports version 2. Update the app and server to matching versions.")
        }
        guard action == "unjoin" else { throw PeerDoorError.invalidCard("unsupported unjoin action") }
        guard WireGuardKey.isValidPublicKey(serverPublicKey) else {
            throw PeerDoorError.invalidCard("invalid server public key")
        }
        guard unjoinURL.scheme == "http", unjoinURL.host != nil,
              unjoinURL.path == "/v1/pair", unjoinURL.user == nil,
              unjoinURL.password == nil, unjoinURL.query == nil, unjoinURL.fragment == nil else {
            throw PeerDoorError.invalidCard("invalid unjoin URL")
        }
    }

    public func pairedServer(in servers: [PairedServer]) throws -> PairedServer {
        try validate()
        guard let server = servers.first(where: { $0.publicKey == serverPublicKey }) else {
            throw PeerDoorError.unjoinFailed("This device is not paired with the scanned server")
        }
        guard let credential = server.lease.unjoinToken, !credential.isEmpty else {
            throw PeerDoorError.unjoinFailed("This pairing predates unjoin support. Pair again first.")
        }
        return server
    }
}

public enum ScannedCode: Equatable, Sendable {
    case pair(QRCard)
    case unjoin(UnjoinCard)

    public static func parse(_ text: String) throws -> ScannedCode {
        struct Header: Decodable { var action: String? }
        let data = Data(text.utf8)
        let header = try JSONDecoder().decode(Header.self, from: data)
        switch header.action {
        case nil, "pair":
            return .pair(try QRCard.parse(text))
        case "unjoin":
            let card = try JSONDecoder().decode(UnjoinCard.self, from: data)
            try card.validate()
            return .unjoin(card)
        default:
            throw PeerDoorError.invalidCard("unsupported action")
        }
    }
}
