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

    func testAutomaticNetworkDefaults() {
        let policy = TunnelPolicy(trustedNetworkIDs: ["ssid:Office"])
        XCTAssertEqual(policy.decide(path: .wifi(id: "ssid:Cafe")), .connect(fullTunnel: true))
        XCTAssertEqual(policy.decide(path: .wifi(id: "ssid:Office")), .connect(fullTunnel: false))
        XCTAssertEqual(policy.decide(path: .cellular), .connect(fullTunnel: false))
        XCTAssertEqual(policy.decide(path: .other), .connect(fullTunnel: true))
    }

    func testUnknownSSIDFailsClosedNeverExit() {
        let policy = TunnelPolicy(trustedNetworkIDs: ["unidentified", "wifi:en0"])
        // Even with those IDs in the trusted set, unidentified / interface fingerprints disconnect.
        XCTAssertEqual(
            policy.decide(path: .wifi(id: "unidentified")),
            .disconnect(reason: "Wi‑Fi name unavailable")
        )
        XCTAssertEqual(
            policy.decide(path: .wifi(id: "wifi:en0")),
            .disconnect(reason: "Wi‑Fi name unavailable")
        )
        // Manual exit must not hairpin when SSID is unknown.
        XCTAssertEqual(
            TunnelPolicy(mode: .exit).decide(path: .wifi(id: "unidentified")),
            .disconnect(reason: "Wi‑Fi name unavailable")
        )
    }

    func testHomeWiFiAlwaysDisconnectsEvenOverManualExit() {
        let home: Set<String> = ["ssid:House"]
        for mode in TunnelPolicy.Mode.allCases {
            XCTAssertEqual(
                TunnelPolicy(mode: mode).decide(path: .wifi(id: "ssid:House"), homeSSIDs: home),
                .disconnect(reason: "Off at home")
            )
        }
        XCTAssertEqual(
            TunnelPolicy().decide(path: .wifi(id: "ssid:Cafe"), homeSSIDs: home),
            .connect(fullTunnel: true)
        )
    }

    func testHomeIsNotTrusted() {
        let home: Set<String> = ["ssid:House"]
        let policy = TunnelPolicy(trustedNetworkIDs: ["ssid:House"])
        // Home SSIDs win; Trusted membership must not subnet-route on the home LAN.
        XCTAssertEqual(
            policy.decide(path: .wifi(id: "ssid:House"), homeSSIDs: home),
            .disconnect(reason: "Off at home")
        )
    }

    func testExplicitRoutingToggleIsHonoredExceptHome() {
        for path in [TunnelPolicy.PathKind.cellular, .wifi(id: "ssid:Cafe"), .other] {
            XCTAssertEqual(TunnelPolicy(mode: .split).decide(path: path), .connect(fullTunnel: false))
            XCTAssertEqual(TunnelPolicy(mode: .exit).decide(path: path), .connect(fullTunnel: true))
        }
        XCTAssertEqual(TunnelPolicy(treatCellularAsTrusted: false).decide(path: .cellular), .connect(fullTunnel: true))
    }

    func testAllowedIPsUseTunnelNetworkAndHomeNetworks() {
        let lease = sampleLease(
            tunnelNetwork: "10.8.0.0/24",
            homeNetworks: ["192.168.1.0/24", "10.10.10.0/24"]
        )
        let policy = TunnelPolicy()
        XCTAssertEqual(
            policy.allowedIPs(lease: lease, fullTunnel: false),
            ["10.10.10.0/24", "10.8.0.0/24", "192.168.1.0/24"]
        )
        XCTAssertEqual(
            Set(policy.allowedIPs(lease: lease, fullTunnel: true)),
            Set(["10.8.0.0/24", "192.168.1.0/24", "10.10.10.0/24", "0.0.0.0/0", "::/0"])
        )
    }

    func testAllowedIPsIgnoreEmbeddedDefaultRoutesInLeaseFields() {
        let lease = sampleLease(
            tunnelNetwork: "0.0.0.0/0",
            homeNetworks: ["::/0", "192.168.1.0/24"]
        )
        XCTAssertEqual(
            TunnelPolicy().allowedIPs(lease: lease, fullTunnel: false),
            ["192.168.1.0/24"]
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
        try store.savePolicy(TunnelPolicy(mode: .split))
        XCTAssertEqual(store.loadPolicy().mode, .split)
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
        let server = PairedServer(
            card: QRCard(pairURL: URL(string: "http://192.168.1.10/v1/pair")!, serverPublicKey: "server"),
            lease: sampleLease(unpairToken: "deletion-secret"),
            homeSSIDs: ["ssid:House"]
        )
        let profile = TunnelProfile(server: server, policy: TunnelPolicy())
        XCTAssertNil(profile.lease.unpairToken)
        let data = try JSONEncoder().encode(profile)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("deletion-secret"))
        XCTAssertFalse(text.contains("unpair_token"))
        XCTAssertFalse(text.contains("private"))
        let decoded = try JSONDecoder().decode(TunnelProfile.self, from: data)
        XCTAssertNil(decoded.lease.unpairToken)
        XCTAssertEqual(decoded.homeSSIDs, ["ssid:House"])
        XCTAssertEqual(decoded.lease.dnsServers, ["192.168.1.1"])
        XCTAssertEqual(decoded.lease.tunnelNetwork, "10.8.0.0/24")
        XCTAssertEqual(decoded.lease.homeNetworks, ["192.168.1.0/24"])
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
