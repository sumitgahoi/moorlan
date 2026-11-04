import Foundation

public struct PairingClient: Sendable {
    public init() {}

    public func pair(card: QRCard, publicKey: String, label: String, session: URLSession = .shared) async throws -> Lease {
        try card.validate()
        var request = URLRequest(url: card.pairURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "public_key": publicKey,
            "label": label
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MoorlanError.pairingFailed("no HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            if let obj = try? JSONDecoder().decode(ErrorBody.self, from: data) {
                throw MoorlanError.pairingFailed(obj.error)
            }
            throw MoorlanError.pairingFailed("HTTP \(http.statusCode)")
        }
        let lease = try JSONDecoder().decode(Lease.self, from: data)
        guard WireGuardKey.isValidPublicKey(lease.publicKey),
              let endpoint = lease.endpoint, !endpoint.isEmpty,
              let lan = lease.lan, !lan.isEmpty,
              let credential = lease.unpairToken, !credential.isEmpty else {
            throw MoorlanError.pairingFailed("Server did not return complete connection settings")
        }
        guard lease.publicKey == card.serverPublicKey else {
            throw MoorlanError.pairingFailed("Server identity does not match the scanned QR")
        }
        return lease
    }

    /// Only an acknowledged server removal permits the caller to clear local state.
    public func unpair(server: PairedServer, publicKey: String, card: UnpairCard? = nil, session: URLSession = .shared) async throws {
        guard let credential = server.lease.unpairToken, !credential.isEmpty else {
            throw MoorlanError.unpairFailed("This pairing predates unpair support. Pair again first.")
        }
        if let card {
            try card.validate()
            guard card.serverPublicKey == server.publicKey else {
                throw MoorlanError.unpairFailed("The scanned QR belongs to a different server")
            }
        }
        var request = URLRequest(url: card?.unpairURL ?? server.card.pairURL)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "public_key": publicKey,
            "unpair_token": credential
        ])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MoorlanError.unpairFailed("No HTTP response; local pairing kept")
        }
        guard http.statusCode == 204 else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
                ?? "HTTP \(http.statusCode)"
            throw MoorlanError.unpairFailed(message)
        }
    }
}

private struct ErrorBody: Decodable {
    var error: String
}
