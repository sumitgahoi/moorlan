import XCTest
@testable import MoorlanCore

final class TunnelPolicyTests: XCTestCase {
    private func sampleLease(
        tunnelNetwork: String = "10.8.0.0/24",
        homeNetworks: [String] = ["192.168.1.0/24"],
        dnsServers: [String] = ["192.168.1.1"],
        unpairToken: String? = "peer-secret"
    ) -> Lease {
        Lease(
            address: "10.8.0.2/32",
            tunnelNetwork: tunnelNetwork,
            homeNetworks: homeNetworks,
            publicKey: "key",
            endpoint: "example:51820",
            dnsServers: dnsServers,
            unpairToken: unpairToken
        )
    }

    func testDefaultsWiFiAndCellularFull() {
        let policy = TunnelPolicy()
        XCTAssertEqual(policy.decide(path: .wifi(id: "ssid:Cafe")), .connect(fullTunnel: true))
        XCTAssertEqual(policy.decide(path: .cellular), .connect(fullTunnel: true))
        XCTAssertEqual(policy.decide(path: .other), .connect(fullTunnel: true))
        XCTAssertEqual(policy.cellularRouting, .full)
    }

    func testDurableRoutingMatrix() {
        var policy = TunnelPolicy(networkRouting: [
            "ssid:House": .off,
            "ssid:Office": .split,
            "ssid:Cafe": .full
        ])
        XCTAssertEqual(policy.decide(path: .wifi(id: "ssid:House")), .disconnect(reason: "Off on this network"))
        XCTAssertEqual(policy.decide(path: .wifi(id: "ssid:Office")), .connect(fullTunnel: false))
        XCTAssertEqual(policy.decide(path: .wifi(id: "ssid:Cafe")), .connect(fullTunnel: true))
        policy.cellularRouting = .off
        XCTAssertEqual(policy.decide(path: .cellular), .disconnect(reason: "Off on cellular"))
        policy.cellularRouting = .split
        XCTAssertEqual(policy.decide(path: .cellular), .connect(fullTunnel: false))
        policy.cellularRouting = .full
        XCTAssertEqual(policy.decide(path: .cellular), .connect(fullTunnel: true))
    }

    func testDurableMapChangePersistsInPolicy() {
        var policy = TunnelPolicy()
        XCTAssertEqual(policy.routing(forNetworkID: "ssid:Cafe"), .full)
        policy.networkRouting["ssid:Cafe"] = .split
        XCTAssertEqual(policy.decide(path: .wifi(id: "ssid:Cafe")), .connect(fullTunnel: false))
        policy.networkRouting["ssid:Cafe"] = .off
        XCTAssertEqual(policy.offSSIDNames, ["Cafe"])
        policy.networkRouting["ssid:Cafe"] = .full
        XCTAssertEqual(policy.decide(path: .wifi(id: "ssid:Cafe")), .connect(fullTunnel: true))
    }

    func testUnknownSSIDUsesUnmarkedFullNotError() {
        XCTAssertEqual(
            TunnelPolicy().decide(path: .wifi(id: "unidentified")),
            .connect(fullTunnel: true)
        )
        XCTAssertEqual(
            TunnelPolicy().decide(path: .wifi(id: "wifi:en0")),
            .connect(fullTunnel: true)
        )
    }

    func testAllowedIPsUseTunnelNetworkAndHomeNetworks() {
        let lease = sampleLease(
            tunnelNetwork: "10.8.0.0/24",
            homeNetworks: ["192.168.1.0/24", "10.10.10.0/24"]
        )
        let policy = TunnelPolicy()
        XCTAssertEqual(
            policy.allowedIPs(lease: lease, fullTunnel: false),
            ["10.10.10.0/24", "10.8.0.0/24", "192.168.1.0/24", "192.168.1.1/32"]
        )
        XCTAssertEqual(
            Set(policy.allowedIPs(lease: lease, fullTunnel: true)),
            Set(["10.8.0.0/24", "192.168.1.0/24", "10.10.10.0/24", "192.168.1.1/32", "0.0.0.0/0"])
        )
        XCTAssertFalse(policy.allowedIPs(lease: lease, fullTunnel: true).contains("::/0"))
    }

    func testAllowedIPsIncludeDNSHostRoutesOutsideHomeNetworks() {
        let lease = sampleLease(
            tunnelNetwork: "10.8.0.0/24",
            homeNetworks: ["192.168.1.0/24"],
            dnsServers: ["10.10.10.53", "1.1.1.1"]
        )
        XCTAssertEqual(
            TunnelPolicy().allowedIPs(lease: lease, fullTunnel: false),
            ["1.1.1.1/32", "10.10.10.53/32", "10.8.0.0/24", "192.168.1.0/24"]
        )
    }

    func testAllowedIPsIgnoreEmbeddedDefaultRoutesInLeaseFields() {
        let lease = sampleLease(
            tunnelNetwork: "0.0.0.0/0",
            homeNetworks: ["::/0", "192.168.1.0/24"]
        )
        XCTAssertEqual(
            TunnelPolicy().allowedIPs(lease: lease, fullTunnel: false),
            ["192.168.1.0/24", "192.168.1.1/32"]
        )
    }

    func testLegacyPolicyMigration() throws {
        let name = "moorlan-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("""
        {"exitNodeEnabled":false,"trustedNetworkIDs":["wifi:en0","ssid:Office"],"treatCellularAsTrusted":true}
        """.utf8), forKey: "tunnel-policy")
        let store = ServerStore(defaults: defaults)
        let policy = store.loadPolicy()
        XCTAssertEqual(policy.networkRouting["ssid:Office"], .split)
        XCTAssertNil(policy.networkRouting["wifi:en0"])
        XCTAssertEqual(policy.cellularRouting, .split)
        try store.savePolicy(TunnelPolicy(cellularRouting: .full))
        XCTAssertEqual(store.loadPolicy().cellularRouting, .full)
    }

    func testMigrateLegacyHomeSSIDs() throws {
        let name = "moorlan-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ServerStore(defaults: defaults)
        var policy = TunnelPolicy()
        var servers = [
            PairedServer(
                card: QRCard(pairURL: URL(string: "http://192.168.1.10/v1/pair")!, serverPublicKey: "server"),
                lease: sampleLease(),
                homeSSIDs: ["ssid:House"]
            )
        ]
        XCTAssertTrue(try store.migrateLegacyHomeSSIDs(policy: &policy, servers: &servers))
        XCTAssertEqual(policy.networkRouting["ssid:House"], .off)
        XCTAssertTrue(servers[0].homeSSIDs.isEmpty)
        XCTAssertFalse(try store.migrateLegacyHomeSSIDs(policy: &policy, servers: &servers))
    }

    func testCorruptServerStoreThrowsInsteadOfEmpty() throws {
        let name = "moorlan-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("not-json".utf8), forKey: "paired-servers")
        let store = ServerStore(defaults: defaults)
        XCTAssertThrowsError(try store.loadServers()) { error in
            XCTAssertEqual(error as? MoorlanError, .storageFailed)
        }
    }

    func testExtensionProfileStripsUnpairTokenAndOmitsPrivateKey() throws {
        var policy = TunnelPolicy()
        policy.networkRouting["ssid:House"] = .off
        let server = PairedServer(
            card: QRCard(pairURL: URL(string: "http://192.168.1.10/v1/pair")!, serverPublicKey: "server"),
            lease: sampleLease(unpairToken: "deletion-secret")
        )
        let profile = TunnelProfile(server: server, policy: policy)
        XCTAssertNil(profile.lease.unpairToken)
        let data = try JSONEncoder().encode(profile)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("deletion-secret"))
        XCTAssertFalse(text.contains("unpair_token"))
        XCTAssertFalse(text.contains("private"))
        let decoded = try JSONDecoder().decode(TunnelProfile.self, from: data)
        XCTAssertNil(decoded.lease.unpairToken)
        XCTAssertEqual(decoded.policy.networkRouting["ssid:House"], .off)
        XCTAssertEqual(decoded.lease.dnsServers, ["192.168.1.1"])
        XCTAssertEqual(decoded.lease.tunnelNetwork, "10.8.0.0/24")
        XCTAssertEqual(decoded.lease.homeNetworks, ["192.168.1.0/24"])
    }

    func testLegacyHomeSSIDsOnProfileDecode() throws {
        let json = """
        {"id":"server","name":"House","lease":{"address":"10.8.0.2/32","tunnel_network":"10.8.0.0/24","home_networks":["192.168.1.0/24"],"public_key":"server","endpoint":"example:51820","dns_servers":["192.168.1.1"]},"policy":{"networkRouting":{},"cellularRouting":"split"},"homeSSIDs":["ssid:House"]}
        """
        let decoded = try JSONDecoder().decode(TunnelProfile.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.policy.networkRouting["ssid:House"], .off)
    }

    func testPairedServerDoesNotPersistClientDNSOverrides() throws {
        let server = PairedServer(
            card: QRCard(pairURL: URL(string: "http://192.168.1.10/v1/pair")!, serverPublicKey: "server"),
            lease: sampleLease(dnsServers: ["192.168.1.1"])
        )
        let encoded = try JSONEncoder().encode(server)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("\"client\""))
        let decoded = try JSONDecoder().decode(PairedServer.self, from: encoded)
        XCTAssertEqual(decoded.lease.dnsServers, ["192.168.1.1"])
    }

    func testUserFacingErrorsNeverSurfaceRawNEOrURLStrings() {
        let handshake = UserFacingError.map(MoorlanError.handshakeFailed)
        XCTAssertEqual(handshake.title, "Host didn’t respond")
        XCTAssertEqual(handshake.action, .retry)
        XCTAssertFalse(handshake.message.lowercased().contains("handshake"))

        let stopped = UserFacingError.map(MoorlanError.tunnelStopped)
        XCTAssertEqual(stopped.title, "Tunnel stopped")
        XCTAssertEqual(stopped.action, .retry)
        XCTAssertFalse(stopped.message.lowercased().contains("nevpn"))

        let url = UserFacingError.map(URLError(.timedOut))
        XCTAssertFalse(url.message.lowercased().contains("nsurlerror"))
        XCTAssertFalse(url.message.contains("NSURLError"))

        let ne = NSError(domain: "NEVPNErrorDomain", code: 1)
        let mapped = UserFacingError.map(ne)
        XCTAssertFalse(mapped.message.contains("NEVPNErrorDomain"))
        XCTAssertEqual(mapped.action, .openSettings)
    }
}
