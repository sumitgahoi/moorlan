import Foundation
import XCTest
@testable import MoorlanCore

final class PairingClientTests: XCTestCase {
    private let key = Data(repeating: 1, count: 32).base64EncodedString()

    private func lease(
        publicKey: String? = nil,
        tunnelNetwork: String = "10.8.0.0/24",
        homeNetworks: [String] = ["192.168.1.0/24"],
        dnsServers: [String] = ["192.168.1.1"],
        dnsSearch: [String]? = ["home.arpa"],
        unpairToken: String? = "peer-secret"
    ) -> Lease {
        Lease(
            address: "10.8.0.2/32",
            tunnelNetwork: tunnelNetwork,
            homeNetworks: homeNetworks,
            publicKey: publicKey ?? key,
            endpoint: "vpn.example:51820",
            dnsServers: dnsServers,
            dnsSearch: dnsSearch,
            unpairToken: unpairToken,
            persistentKeepalive: 25
        )
    }

    private func server(credential: String? = "peer-secret") -> PairedServer {
        PairedServer(
            card: QRCard(pairURL: URL(string: "http://192.168.1.10:8756/v1/pair")!, serverPublicKey: key),
            lease: lease(unpairToken: credential)
        )
    }

    private func session(_ handler: @escaping (URLRequest) throws -> (Int, Data)) -> URLSession {
        MockPairingProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockPairingProtocol.self]
        return URLSession(configuration: config)
    }

    private func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = stream.read(&bytes, maxLength: bytes.count)
            return Data(bytes.prefix(max(count, 0)))
        }
        return Data()
    }

    private func invite(_ action: String, control: String = "http://192.168.1.10:8756/v1/pair", spk: String? = nil) -> String {
        var components = URLComponents()
        components.scheme = "moorlan"
        components.host = "v1"
        components.path = "/\(action)"
        components.queryItems = [
            URLQueryItem(name: "url", value: control),
            URLQueryItem(name: "spk", value: spk ?? key)
        ]
        return components.url!.absoluteString
    }

    func testVersionOneQRAndLeaseFields() throws {
        let card = try QRCard.parse(invite("pair"))
        XCTAssertEqual(card.v, 1)
        XCTAssertEqual(card.serverPublicKey, key)
        let lease = try JSONDecoder().decode(Lease.self, from: Data("""
        {"address":"10.8.0.2/32","tunnel_network":"10.8.0.0/24","home_networks":["192.168.1.0/24"],"dns_servers":["192.168.1.1"],"dns_search":["home.arpa"],"public_key":"\(key)","endpoint":"vpn.example:51820","persistent_keepalive":25,"unpair_token":"peer-secret"}
        """.utf8))
        XCTAssertEqual(lease.unpairToken, "peer-secret")
        XCTAssertEqual(lease.tunnelNetwork, "10.8.0.0/24")
        XCTAssertEqual(lease.homeNetworks, ["192.168.1.0/24"])
        XCTAssertEqual(lease.dnsServers, ["192.168.1.1"])
        XCTAssertEqual(lease.dnsSearch, ["home.arpa"])
    }

    func testLeaseRejectsLegacyFieldNames() {
        let legacy = Data("""
        {"address":"10.8.0.2/32","prefixes":["10.8.0.0/24"],"lan":"192.168.1.0/24","dns":["192.168.1.1"],"public_key":"\(key)","endpoint":"vpn.example:51820","unpair_token":"peer-secret"}
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(Lease.self, from: legacy))
    }

    func testPairingSendsDeviceKeyLabelAndChecksServerIdentity() async throws {
        let card = server().card
        for matches in [true, false] {
            let responseKey = matches ? key : Data(repeating: 2, count: 32).base64EncodedString()
            let session = session { request in
                XCTAssertEqual(request.httpMethod, "POST")
                let body = try JSONSerialization.jsonObject(with: try self.requestBody(request)) as! [String: String]
                XCTAssertEqual(body, ["public_key": self.key, "label": "iPhone 17"])
                return (200, try JSONEncoder().encode(self.lease(publicKey: responseKey)))
            }
            do {
                let lease = try await PairingClient().pair(card: card, publicKey: key, label: "iPhone 17", session: session)
                XCTAssertTrue(matches, "Accepted a server identity different from the QR")
                XCTAssertEqual(lease.publicKey, key)
                XCTAssertEqual(lease.dnsServers, ["192.168.1.1"])
            } catch {
                if matches { XCTFail("Pairing failed: \(error)") }
                else {
                    let facing = UserFacingError.map(error)
                    XCTAssertTrue(
                        facing.message.localizedCaseInsensitiveContains("mismatch")
                            || facing.message.localizedCaseInsensitiveContains("QR")
                            || error.localizedDescription.contains("identity")
                    )
                }
            }
            session.invalidateAndCancel()
        }
    }

    func testPairRejectsIncompleteLeaseMissingDNSOrNetworks() async {
        let card = server().card
        let incomplete = [
            lease(tunnelNetwork: ""),
            lease(homeNetworks: []),
            lease(dnsServers: []),
            lease(unpairToken: nil)
        ]
        for bad in incomplete {
            let session = session { _ in (200, try JSONEncoder().encode(bad)) }
            do {
                _ = try await PairingClient().pair(card: card, publicKey: key, label: "iPhone", session: session)
                XCTFail("Expected incomplete lease rejection")
            } catch {
                XCTAssertEqual(UserFacingError.map(error).title, "Incomplete lease")
            }
            session.invalidateAndCancel()
        }
    }

    func testVersionTwoStoredProfileStillDecodes() throws {
        let card = try JSONDecoder().decode(QRCard.self, from: Data("""
        {"v":2,"pair_url":"http://192.168.1.10:8756/v1/pair","token":"old-token"}
        """.utf8))
        XCTAssertEqual(card.v, 2)
        XCTAssertEqual(card.token, "old-token")
        XCTAssertThrowsError(try card.validate())
    }

    func testUnpairUsesDedicatedCredential() async throws {
        let session = session { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/v1/pair")
            let body = try JSONSerialization.jsonObject(with: try self.requestBody(request)) as! [String: String]
            XCTAssertEqual(body["unpair_token"], "peer-secret")
            XCTAssertNil(body["token"])
            return (204, Data())
        }
        defer { session.invalidateAndCancel() }
        try await PairingClient().unpair(server: server(), publicKey: key, session: session)
    }

    func testUnpairTreatsGoneAsSuccessSignal() async {
        for code in [404, 410] {
            let session = session { _ in (code, Data()) }
            do {
                try await PairingClient().unpair(server: server(), publicKey: key, session: session)
                XCTFail("Expected unpairAlreadyGone for HTTP \(code)")
            } catch {
                XCTAssertEqual(error as? MoorlanError, .unpairAlreadyGone)
            }
            session.invalidateAndCancel()
        }
    }

    func testUnpairRejectsFailureAndNetworkError() async {
        for code in [200, 403, 500] {
            let session = session { _ in (code, Data("{\"error\":\"not removed\"}".utf8)) }
            do {
                try await PairingClient().unpair(server: server(), publicKey: key, session: session)
                XCTFail("Only 204 / already-gone confirms removal")
            } catch { }
            session.invalidateAndCancel()
        }
        let offline = session { _ in throw URLError(.notConnectedToInternet) }
        defer { offline.invalidateAndCancel() }
        do {
            try await PairingClient().unpair(server: server(), publicKey: key, session: offline)
            XCTFail("Offline unpair succeeded")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("192.168.1.10:8756"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("Local Network"), error.localizedDescription)
            let facing = UserFacingError.map(error)
            XCTAssertEqual(facing.title, "Can’t reach the host")
            XCTAssertEqual(facing.action, .openSettings)
        }
    }

    func testPairTransportTimeoutNamesEndpoint() async {
        let card = server().card
        let offline = session { _ in throw URLError(.timedOut) }
        defer { offline.invalidateAndCancel() }
        do {
            _ = try await PairingClient().pair(card: card, publicKey: key, label: "iPhone", session: offline)
            XCTFail("Expected LAN unreachable")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                LANReachability.unreachableMessage(for: card.pairURL)
            )
            XCTAssertFalse(error.localizedDescription.hasPrefix("Pairing failed:"))
        }
    }

    func testLegacyPairingCannotSilentlyForgetHost() async {
        let session = session { _ in XCTFail("Missing credential must not send request"); return (204, Data()) }
        defer { session.invalidateAndCancel() }
        do {
            try await PairingClient().unpair(server: server(credential: nil), publicKey: key, session: session)
            XCTFail("Expected re-pair instruction")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Pair again"))
        }
    }

    func testOldStoredCardKeepsName() throws {
        let card = try JSONDecoder().decode(QRCard.self, from: Data("""
        {"v":1,"name":"wg0","lan":"192.168.1.0/24","pair_url":"http://192.168.1.10:8756/v1/pair","token":"old-token"}
        """.utf8))
        let host = PairedServer(card: card, lease: server().lease)
        XCTAssertEqual(host.displayName, "wg0")
        XCTAssertEqual(card.legacyLAN, "192.168.1.0/24")
        XCTAssertThrowsError(try card.validate())
    }

    func testScannerDistinguishesUnpairFromPairing() throws {
        let text = invite("unpair", control: "http://192.168.1.22:9999/v1/pair")
        guard case .unpair(let card) = try ScannedCode.parse(text) else {
            return XCTFail("Unpair QR was treated as enrollment")
        }
        XCTAssertEqual(try card.pairedServer(in: [server()]).publicKey, key)
        XCTAssertThrowsError(try QRCard.parse(text))
        XCTAssertThrowsError(try card.pairedServer(in: []))
        XCTAssertThrowsError(try card.pairedServer(in: [server(credential: nil)]))
        guard case .pair = try ScannedCode.parse(invite("pair")) else {
            return XCTFail("Pairing QR stopped working")
        }
        XCTAssertThrowsError(try ScannedCode.parse("moorlan://v1/unknown?url=http://192.168.1.10:8756/v1/pair&spk=\(key)"))
        XCTAssertThrowsError(try ScannedCode.parse("""
        {"v":1,"pair_url":"http://192.168.1.10:8756/v1/pair","server_public_key":"\(key)"}
        """)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Moorlan invite"))
        }
    }

    func testUnpairQRUsesCurrentURLAndSavedCredential() async throws {
        let currentURL = URL(string: "http://192.168.1.22:9999/v1/pair")!
        let card = UnpairCard(serverPublicKey: key, unpairURL: currentURL)
        let session = session { request in
            XCTAssertEqual(request.url, currentURL)
            XCTAssertEqual(request.httpMethod, "DELETE")
            return (204, Data())
        }
        defer { session.invalidateAndCancel() }
        try await PairingClient().unpair(server: server(), publicKey: key, card: card, session: session)
        let encoded = String(decoding: try JSONEncoder().encode(card), as: UTF8.self)
        XCTAssertFalse(encoded.contains("token"))
        XCTAssertFalse(encoded.contains("peer-secret"))
    }

    func testMismatchedUnpairQRNeverSendsCredential() async {
        let otherKey = Data(repeating: 2, count: 32).base64EncodedString()
        let card = UnpairCard(serverPublicKey: otherKey, unpairURL: URL(string: "http://192.168.1.22/v1/pair")!)
        let session = session { _ in XCTFail("Wrong server received a credential"); return (204, Data()) }
        defer { session.invalidateAndCancel() }
        do {
            try await PairingClient().unpair(server: server(), publicKey: key, card: card, session: session)
            XCTFail("Expected server mismatch")
        } catch { }
    }

    func testLegacyJSONQRIsRejected() {
        let text = """
        {"v":1,"pair_url":"http://192.168.1.10:8756/v1/pair","server_public_key":"\(key)"}
        """
        XCTAssertThrowsError(try ScannedCode.parse(text)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Moorlan invite"))
        }
    }
}

private final class MockPairingProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.unknown) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() { }
}
