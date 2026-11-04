import Foundation

/// A version 1 server locator. VPN settings arrive in the pairing response.
public struct QRCard: Codable, Equatable, Sendable {
    public var v: Int
    public var pairURL: URL
    public var serverPublicKey: String?
    // Retained only to decode previously stored pairings.
    public var token: String?
    public var legacyName: String?
    public var legacyLAN: String?

    enum CodingKeys: String, CodingKey {
        case v
        case pairURL = "pair_url"
        case serverPublicKey = "server_public_key"
        case token
        case legacyName = "name"
        case legacyLAN = "lan"
    }

    public init(v: Int = 1, pairURL: URL, serverPublicKey: String? = nil, token: String? = nil) {
        self.v = v
        self.pairURL = pairURL
        self.serverPublicKey = serverPublicKey
        self.token = token
    }

    public static func parse(_ text: String) throws -> QRCard {
        let card = try JSONDecoder().decode(QRCard.self, from: Data(text.utf8))
        try card.validate()
        return card
    }

    public func validate() throws {
        guard v == 1 else {
            throw MoorlanError.invalidCard("Server QR is version \(v); this app requires version 1. Rebuild and restart the Linux server using the latest server/ code, then scan its new QR.")
        }
        guard let serverPublicKey, WireGuardKey.isValidPublicKey(serverPublicKey) else {
            throw MoorlanError.invalidCard("invalid server public key")
        }
        guard pairURL.scheme == "http", pairURL.host != nil,
              pairURL.path == "/v1/pair", pairURL.user == nil,
              pairURL.password == nil, pairURL.query == nil, pairURL.fragment == nil else {
            throw MoorlanError.invalidCard("invalid pairing URL")
        }
    }

    public var lanHost: String? { pairURL.host }
}
