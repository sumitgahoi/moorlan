import Foundation
import XCTest
@testable import PeerDoorCore

final class PairingClientTests: XCTestCase {
    private let key = Data(repeating: 1, count: 32).base64EncodedString()

    private func server(credential: String? = "peer-secret") -> PairedServer {
        PairedServer(
            card: QRCard(pairURL: URL(string: "http://192.168.1.10:8756/v1/pair")!, serverPublicKey: key),
            lease: Lease(address: "10.8.0.2/32", prefixes: ["10.8.0.0/24"], publicKey: key,
                         endpoint: "vpn.example:51820", lan: "192.168.1.0/24", unjoinToken: credential)
        )
    }

    private func session(_ handler: @escaping (URLRequest) throws -> (Int, Data)) -> URLSession {
        MockPairingProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockPairingProtocol.self]
        return URLSession(configuration: config)
    }

    func testVersionThreeQRAndLease() throws {
        let card = try QRCard.parse("""
        {"v":3,"pair_url":"http://192.168.1.10:8756/v1/pair","server_public_key":"\(key)"}
        """)
        XCTAssertEqual(card.v, 3)
        let lease = try JSONDecoder().decode(Lease.self, from: Data("""
        {"address":"10.8.0.2/32","prefixes":["10.8.0.0/24"],"lan":"192.168.1.0/24","public_key":"\(key)","endpoint":"vpn.example:51820","persistent_keepalive":25,"unjoin_token":"peer-secret"}
        """.utf8))
        XCTAssertEqual(lease.unjoinToken, "peer-secret")
        XCTAssertNil(lease.listenPort)
        XCTAssertEqual(lease.lan, "192.168.1.0/24")
    }

    func testPairingSendsOnlyDeviceKeyAndChecksServerIdentity() async throws {
        let card = server().card
        for matches in [true, false] {
            let responseKey = matches ? key : Data(repeating: 2, count: 32).base64EncodedString()
            let session = session { request in
                XCTAssertEqual(request.httpMethod, "POST")
                let data: Data
                if let body = request.httpBody { data = body }
                else if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var bytes = [UInt8](repeating: 0, count: 4096)
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    data = Data(bytes.prefix(max(count, 0)))
                } else { data = Data() }
                let body = try JSONSerialization.jsonObject(with: data) as! [String: String]
                XCTAssertEqual(body, ["public_key": self.key])
                let lease = Lease(address: "10.8.0.2/32", prefixes: ["10.8.0.0/24"],
                                  publicKey: responseKey, endpoint: "vpn.example:51820",
                                  lan: "192.168.1.0/24", unjoinToken: "peer-secret")
                return (200, try JSONEncoder().encode(lease))
            }
            do {
                let lease = try await PairingClient().pair(card: card, publicKey: key, session: session)
                XCTAssertTrue(matches, "Accepted a server identity different from the QR")
                XCTAssertEqual(lease.publicKey, key)
            } catch {
                if matches { XCTFail("Pairing failed: \(error)") }
                else { XCTAssertTrue(error.localizedDescription.contains("identity")) }
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

    func testUnjoinUsesDedicatedCredential() async throws {
        let session = session { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/v1/pair")
            // URLSession may expose the encoded body as a stream to URLProtocol.
            let data: Data
            if let body = request.httpBody { data = body }
            else if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = stream.read(&bytes, maxLength: bytes.count)
                data = Data(bytes.prefix(max(count, 0)))
            } else { data = Data() }
            let body = try JSONSerialization.jsonObject(with: data) as! [String: String]
            XCTAssertEqual(body["unjoin_token"], "peer-secret")
            XCTAssertNil(body["token"])
            return (204, Data())
        }
        defer { session.invalidateAndCancel() }
        try await PairingClient().unjoin(server: server(), publicKey: key, session: session)
    }

    func testUnjoinRejectsFailureAndNetworkError() async {
        for code in [200, 403, 500] {
            let session = session { _ in (code, Data("{\"error\":\"not removed\"}".utf8)) }
            do {
                try await PairingClient().unjoin(server: server(), publicKey: key, session: session)
                XCTFail("Only 204 confirms removal")
            } catch { }
            session.invalidateAndCancel()
        }
        let offline = session { _ in throw URLError(.notConnectedToInternet) }
        defer { offline.invalidateAndCancel() }
        do {
            try await PairingClient().unjoin(server: server(), publicKey: key, session: offline)
            XCTFail("Offline unjoin succeeded")
        } catch { }
    }

    func testLegacyPairingCannotSilentlyForgetHost() async {
        let session = session { _ in XCTFail("Missing credential must not send request"); return (204, Data()) }
        defer { session.invalidateAndCancel() }
        do {
            try await PairingClient().unjoin(server: server(credential: nil), publicKey: key, session: session)
            XCTFail("Expected re-pair instruction")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Pair again"))
        }
    }

    func testOldStoredCardKeepsNameAndLAN() throws {
        let card = try JSONDecoder().decode(QRCard.self, from: Data("""
        {"v":1,"name":"wg0","lan":"192.168.1.0/24","pair_url":"http://192.168.1.10:8756/v1/pair","token":"old-token"}
        """.utf8))
        let host = PairedServer(card: card, lease: server().lease)
        XCTAssertEqual(host.displayName, "wg0")
        XCTAssertEqual(card.legacyLAN, "192.168.1.0/24")
        XCTAssertThrowsError(try card.validate())
    }

    func testScannerDistinguishesUnjoinFromPairing() throws {
        let text = """
        {"v":2,"action":"unjoin","server_public_key":"\(key)","unjoin_url":"http://192.168.1.22:9999/v1/pair"}
        """
        guard case .unjoin(let card) = try ScannedCode.parse(text) else {
            return XCTFail("Unjoin QR was treated as enrollment")
        }
        XCTAssertEqual(try card.pairedServer(in: [server()]).publicKey, key)
        XCTAssertThrowsError(try QRCard.parse(text))
        XCTAssertThrowsError(try card.pairedServer(in: []))
        XCTAssertThrowsError(try card.pairedServer(in: [server(credential: nil)]))
        let pairText = """
        {"v":3,"pair_url":"http://192.168.1.10:8756/v1/pair","server_public_key":"\(key)"}
        """
        guard case .pair = try ScannedCode.parse(pairText) else {
            return XCTFail("Pairing QR stopped working")
        }
        XCTAssertThrowsError(try ScannedCode.parse("{\"action\":\"unknown\"}"))
    }

    func testUnjoinQRUsesCurrentURLAndSavedCredential() async throws {
        let currentURL = URL(string: "http://192.168.1.22:9999/v1/pair")!
        let card = UnjoinCard(serverPublicKey: key, unjoinURL: currentURL)
        let session = session { request in
            XCTAssertEqual(request.url, currentURL)
            XCTAssertEqual(request.httpMethod, "DELETE")
            return (204, Data())
        }
        defer { session.invalidateAndCancel() }
        try await PairingClient().unjoin(server: server(), publicKey: key, card: card, session: session)
        let encoded = String(decoding: try JSONEncoder().encode(card), as: UTF8.self)
        XCTAssertFalse(encoded.contains("token"))
        XCTAssertFalse(encoded.contains("peer-secret"))
    }

    func testMismatchedUnjoinQRNeverSendsCredential() async {
        let otherKey = Data(repeating: 2, count: 32).base64EncodedString()
        let card = UnjoinCard(serverPublicKey: otherKey, unjoinURL: URL(string: "http://192.168.1.22/v1/pair")!)
        let session = session { _ in XCTFail("Wrong server received a credential"); return (204, Data()) }
        defer { session.invalidateAndCancel() }
        do {
            try await PairingClient().unjoin(server: server(), publicKey: key, card: card, session: session)
            XCTFail("Expected server mismatch")
        } catch { }
    }


    func testOldServerQRExplainsUpgradeInsteadOfSilentlyDowngrading() {
        let text = """
        {"v":1,"name":"wg0","pair_url":"http://192.168.1.10:8756/v1/pair","token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
        """
        XCTAssertThrowsError(try ScannedCode.parse(text)) { error in
            XCTAssertTrue(error.localizedDescription.contains("version 1"))
            XCTAssertTrue(error.localizedDescription.contains("version 3"))
            XCTAssertTrue(error.localizedDescription.contains("Rebuild and restart"))
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
