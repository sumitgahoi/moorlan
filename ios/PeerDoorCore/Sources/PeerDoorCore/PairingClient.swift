import Foundation

public struct PairingClient: Sendable {
    public init() {}

    public func pair(card: QRCard, publicKey: String, session: URLSession = .shared) async throws -> Lease {
        try card.validate()
        var request = URLRequest(url: card.pairURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body: [String: String] = [
            "public_key": publicKey
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PeerDoorError.pairingFailed("no HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            if let obj = try? JSONDecoder().decode(ErrorBody.self, from: data) {
                throw PeerDoorError.pairingFailed(obj.error)
            }
            throw PeerDoorError.pairingFailed("HTTP \(http.statusCode)")
        }
        let lease = try JSONDecoder().decode(Lease.self, from: data)
        guard WireGuardKey.isValidPublicKey(lease.publicKey),
              let endpoint = lease.endpoint, !endpoint.isEmpty,
              let lan = lease.lan, !lan.isEmpty,
              let credential = lease.unjoinToken, !credential.isEmpty else {
            throw PeerDoorError.pairingFailed("Server did not return complete connection settings")
        }
        guard lease.publicKey == card.serverPublicKey else {
            throw PeerDoorError.pairingFailed("Server identity does not match the scanned QR")
        }
        return lease
    }

    /// Only an acknowledged server removal permits the caller to clear local state.
    public func unjoin(server: PairedServer, publicKey: String, card: UnjoinCard? = nil, session: URLSession = .shared) async throws {
        guard let credential = server.lease.unjoinToken, !credential.isEmpty else {
            throw PeerDoorError.unjoinFailed("This pairing predates unjoin support. Pair again first.")
        }
        if let card {
            try card.validate()
            guard card.serverPublicKey == server.publicKey else {
                throw PeerDoorError.unjoinFailed("The scanned QR belongs to a different server")
            }
        }
        var request = URLRequest(url: card?.unjoinURL ?? server.card.pairURL)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "public_key": publicKey,
            "unjoin_token": credential
        ])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PeerDoorError.unjoinFailed("No HTTP response; local pairing kept")
        }
        guard http.statusCode == 204 else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
                ?? "HTTP \(http.statusCode)"
            throw PeerDoorError.unjoinFailed(message)
        }
    }

}

private struct ErrorBody: Decodable {
    var error: String
}
