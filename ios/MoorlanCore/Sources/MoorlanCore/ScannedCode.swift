import Foundation

/// Public information locating a known server's deletion service. Permission
/// still comes from the per-peer credential saved in the original lease.
public struct UnpairCard: Codable, Equatable, Sendable {
    public var v: Int
    public var action: String
    public var serverPublicKey: String
    public var unpairURL: URL

    enum CodingKeys: String, CodingKey {
        case v, action
        case serverPublicKey = "server_public_key"
        case unpairURL = "unpair_url"
    }

    public init(v: Int = 1, action: String = "unpair", serverPublicKey: String, unpairURL: URL) {
        self.v = v
        self.action = action
        self.serverPublicKey = serverPublicKey
        self.unpairURL = unpairURL
    }

    public func validate() throws {
        guard v == 1 else {
            throw MoorlanError.invalidCard("Unpair QR version \(v) is unsupported; this app supports version 1. Rebuild and restart the Linux server using the latest server/ code, then scan its new QR.")
        }
        guard action == "unpair" else { throw MoorlanError.invalidCard("unsupported unpair action") }
        guard WireGuardKey.isValidPublicKey(serverPublicKey) else {
            throw MoorlanError.invalidCard("invalid server public key")
        }
        guard unpairURL.scheme == "http", unpairURL.host != nil,
              unpairURL.path == "/v1/pair", unpairURL.user == nil,
              unpairURL.password == nil, unpairURL.query == nil, unpairURL.fragment == nil else {
            throw MoorlanError.invalidCard("invalid unpair URL")
        }
    }

    public func pairedServer(in servers: [PairedServer]) throws -> PairedServer {
        try validate()
        guard let server = servers.first(where: { $0.publicKey == serverPublicKey }) else {
            throw MoorlanError.unpairFailed("This device is not paired with the scanned server")
        }
        guard let credential = server.lease.unpairToken, !credential.isEmpty else {
            throw MoorlanError.unpairFailed("This pairing predates unpair support. Pair again first.")
        }
        return server
    }
}

public enum ScannedCode: Equatable, Sendable {
    case pair(QRCard)
    case unpair(UnpairCard)

    public static func parse(_ text: String) throws -> ScannedCode {
        struct Header: Decodable { var action: String? }
        let data = Data(text.utf8)
        let header = try JSONDecoder().decode(Header.self, from: data)
        switch header.action {
        case nil, "pair":
            return .pair(try QRCard.parse(text))
        case "unpair":
            let card = try JSONDecoder().decode(UnpairCard.self, from: data)
            try card.validate()
            return .unpair(card)
        default:
            throw MoorlanError.invalidCard("unsupported action")
        }
    }
}
