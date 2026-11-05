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

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LANReachability.mapTransportError(error, url: card.pairURL)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MoorlanError.pairingFailed("no HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            if let obj = try? JSONDecoder().decode(ErrorBody.self, from: data) {
                throw MoorlanError.pairingFailed(obj.error)
            }
            throw MoorlanError.pairingFailed("HTTP \(http.statusCode)")
        }
        let lease: Lease
        do {
            lease = try JSONDecoder().decode(Lease.self, from: data)
        } catch {
            throw MoorlanError.leaseIncomplete
        }
        try Self.validateLease(lease, expectedServerKey: card.serverPublicKey)
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
        let controlURL = card?.unpairURL ?? server.card.pairURL
        var request = URLRequest(url: controlURL)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "public_key": publicKey,
            "unpair_token": credential
        ])
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LANReachability.mapTransportError(error, url: controlURL)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MoorlanError.unpairFailed("No HTTP response; local pairing kept")
        }
        // 204 = removed (or idempotent already-absent with valid token on current servers).
        // 404/410 = peer already gone; phone should still clear local state.
        if http.statusCode == 204 { return }
        if http.statusCode == 404 || http.statusCode == 410 {
            throw MoorlanError.unpairAlreadyGone
        }
        let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            ?? "HTTP \(http.statusCode)"
        throw MoorlanError.unpairFailed(message)
    }

    /// Lease contract: tunnel_network, home_networks, dns_servers (required), dns_search optional.
    public static func validateLease(_ lease: Lease, expectedServerKey: String?) throws {
        guard WireGuardKey.isValidPublicKey(lease.publicKey),
              let endpoint = lease.endpoint, !endpoint.isEmpty,
              !lease.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !lease.tunnelNetwork.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              lease.homeNetworks.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              lease.dnsServers.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              let credential = lease.unpairToken, !credential.isEmpty else {
            throw MoorlanError.leaseIncomplete
        }
        if let expectedServerKey, lease.publicKey != expectedServerKey {
            throw MoorlanError.pairingFailed("Server identity does not match the scanned QR")
        }
    }
}

private struct ErrorBody: Decodable {
    var error: String
}
