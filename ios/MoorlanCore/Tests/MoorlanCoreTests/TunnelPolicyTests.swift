import XCTest
@testable import MoorlanCore

final class TunnelPolicyTests: XCTestCase {
    func testAutomaticNetworkDefaults() {
        let policy = TunnelPolicy(trustedNetworkIDs: ["ssid:Office"])
        XCTAssertEqual(policy.decide(path: .wifi(id: "ssid:Cafe")), .connect(fullTunnel: true))
        XCTAssertEqual(policy.decide(path: .wifi(id: "unidentified")), .connect(fullTunnel: true))
        XCTAssertEqual(policy.decide(path: .wifi(id: "ssid:Office")), .connect(fullTunnel: false))
        XCTAssertEqual(policy.decide(path: .cellular), .connect(fullTunnel: false))
        XCTAssertEqual(policy.decide(path: .other), .connect(fullTunnel: true))
    }
    func testUnknownNetworkCannotBecomeTrustedByInterfaceName() {
        let policy = TunnelPolicy(trustedNetworkIDs: ["unidentified", "wifi:en0"])
        XCTAssertEqual(policy.decide(path: .wifi(id: "unidentified")), .connect(fullTunnel: true))
        XCTAssertEqual(policy.decide(path: .wifi(id: "wifi:en0")), .connect(fullTunnel: true))
    }
    func testHomeWiFiAlwaysDisconnects() {
        let home: Set<String> = ["ssid:House"]
        for mode in TunnelPolicy.Mode.allCases {
            XCTAssertEqual(
                TunnelPolicy(mode: mode).decide(path: .wifi(id: "ssid:House"), homeSSIDs: home),
                .disconnect(reason: "Tunnel stays off on home Wi‑Fi")
            )
        }
        XCTAssertEqual(
            TunnelPolicy().decide(path: .wifi(id: "ssid:Cafe"), homeSSIDs: home),
            .connect(fullTunnel: true)
        )
    }
    func testExplicitRoutingToggleIsHonored() {
        for path in [TunnelPolicy.PathKind.cellular, .wifi(id: "ssid:Cafe"), .other] {
            XCTAssertEqual(TunnelPolicy(mode: .split).decide(path: path), .connect(fullTunnel: false))
            XCTAssertEqual(TunnelPolicy(mode: .exit).decide(path: path), .connect(fullTunnel: true))
        }
        XCTAssertEqual(TunnelPolicy(treatCellularAsTrusted: false).decide(path: .cellular), .connect(fullTunnel: true))
    }
    func testSplitIncludesLANAndExcludesDefaultRoutes() {
        let lease = Lease(address: "10.8.0.2/32", prefixes: ["10.8.0.0/24", "0.0.0.0/0", "::/0"], publicKey: "key", lan: "192.168.1.0/24")
        let policy = TunnelPolicy()
        XCTAssertEqual(policy.allowedIPs(lease: lease, fullTunnel: false), ["10.8.0.0/24", "192.168.1.0/24"])
        XCTAssertEqual(Set(policy.allowedIPs(lease: lease, fullTunnel: true)), Set(["10.8.0.0/24", "192.168.1.0/24", "0.0.0.0/0", "::/0"]))
    }
    func testHomeCIDRListAcceptsCommaSeparated() {
        XCTAssertEqual(TunnelPolicy.homeCIDRs(from: "10.10.0.0/16"), ["10.10.0.0/16"])
        XCTAssertEqual(
            TunnelPolicy.homeCIDRs(from: "10.10.10.0/24, 10.10.20.0/24"),
            ["10.10.10.0/24", "10.10.20.0/24"]
        )
        let lease = Lease(address: "10.8.0.2/32", prefixes: ["10.8.0.0/24"], publicKey: "key", lan: "10.10.10.0/24,10.10.20.0/24")
        XCTAssertEqual(
            TunnelPolicy().allowedIPs(lease: lease, fullTunnel: false),
            ["10.10.10.0/24", "10.10.20.0/24", "10.8.0.0/24"]
        )
    }
    func testLegacyTrustDoesNotTrustEveryWiFiInterface() throws {
        let name = "moorlan-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("""
        {"exitNodeEnabled":false,"trustedNetworkIDs":["wifi:en0","ssid:Office"],"treatCellularAsTrusted":true}
        """.utf8), forKey: "tunnel-policy")
        let store = ServerStore(defaults: defaults)
        let policy = store.loadPolicy()
        XCTAssertEqual(policy.mode, .automatic)
        XCTAssertEqual(policy.trustedNetworkIDs, ["ssid:Office"])
        store.savePolicy(TunnelPolicy(mode: .split))
        XCTAssertEqual(store.loadPolicy().mode, .split)
    }
    func testExtensionProfileDoesNotContainPrivateOrDeletionCredential() throws {
        let server = PairedServer(
            card: QRCard(pairURL: URL(string: "http://192.168.1.10/v1/pair")!, token: String(repeating: "a", count: 32)),
            lease: Lease(address: "10.8.0.2/32", prefixes: [], publicKey: "server", endpoint: "example:51820", lan: "192.168.1.0/24", unpairToken: "deletion-secret"),
            homeSSIDs: ["ssid:House"]
        )
        let profile = TunnelProfile(server: server, policy: TunnelPolicy())
        let data = try JSONEncoder().encode(profile)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("deletion-secret"))
        XCTAssertFalse(text.contains("private"))
        XCTAssertEqual(try JSONDecoder().decode(TunnelProfile.self, from: data), profile)
        XCTAssertEqual(profile.homeSSIDs, ["ssid:House"])
    }

    func testClientOverridesBakeIntoTunnelProfileWithoutChangingStoredLease() throws {
        var server = PairedServer(
            card: QRCard(pairURL: URL(string: "http://192.168.1.10/v1/pair")!, serverPublicKey: "server"),
            lease: Lease(
                address: "10.8.0.2/32",
                prefixes: ["10.8.0.0/24"],
                publicKey: "server",
                endpoint: "example:51820",
                mtu: 1420,
                lan: "192.168.1.0/24",
                dns: ["192.168.1.1"],
                persistentKeepalive: 25
            )
        )
        server.client = ClientTunnelSettings(dns: ["10.10.10.10"], dnsSearch: ["home.arpa"], mtu: 1380, persistentKeepalive: 30)
        let profile = TunnelProfile(server: server, policy: TunnelPolicy())
        XCTAssertEqual(profile.lease.dns, ["10.10.10.10"])
        XCTAssertEqual(profile.lease.dnsSearch, ["home.arpa"])
        XCTAssertEqual(profile.lease.mtu, 1380)
        XCTAssertEqual(profile.lease.persistentKeepalive, 30)
        XCTAssertEqual(server.lease.dns, ["192.168.1.1"])
        XCTAssertEqual(server.lease.mtu, 1420)
        XCTAssertEqual(server.lease.persistentKeepalive, 25)

        let encoded = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(PairedServer.self, from: encoded)
        XCTAssertEqual(decoded.client.dns, ["10.10.10.10"])
        XCTAssertEqual(decoded.client.dnsSearch, ["home.arpa"])
        XCTAssertEqual(decoded.lease.dns, ["192.168.1.1"])
    }

    func testClientDNSParsing() throws {
        XCTAssertNil(try ClientTunnelSettings.parseDNS("").get())
        XCTAssertEqual(try ClientTunnelSettings.parseDNS(" 10.10.10.10, 10.10.10.11 ").get(), ["10.10.10.10", "10.10.10.11"])
        if case .failure = ClientTunnelSettings.parseDNS("not-an-ip") {} else {
            XCTFail("expected invalid DNS failure")
        }
        XCTAssertEqual(try ClientTunnelSettings.parseDNSSearch(" home.arpa, LAN. ").get(), ["home.arpa", "lan"])
        if case .failure = ClientTunnelSettings.parseDNSSearch("-bad") {} else {
            XCTFail("expected invalid search domain failure")
        }
    }
    func testIPv4ParsingAndNetworkBoundaries() {
        XCTAssertNil(IPv4Address("192.168.bad.1.2"))
        XCTAssertTrue(IPv4Network("192.168.1.0/24")!.contains(IPv4Address("192.168.1.10")!))
        XCTAssertFalse(IPv4Network("192.168.1.0/24")!.contains(IPv4Address("10.8.0.2")!))
    }
}
