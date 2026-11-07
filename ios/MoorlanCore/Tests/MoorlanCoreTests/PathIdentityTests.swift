import XCTest
@testable import MoorlanCore

final class PathIdentityTests: XCTestCase {
    func testWiFiWithSSIDIsStable() {
        XCTAssertEqual(
            PathIdentity.classify(hasWiFi: true, hasCellular: false, wifiNetworkID: "ssid:Home"),
            .stable(.wifi(id: "ssid:Home"))
        )
        XCTAssertEqual(
            PathIdentity.classify(hasWiFi: true, hasCellular: true, wifiNetworkID: "ssid:Cafe"),
            .stable(.wifi(id: "ssid:Cafe"))
        )
    }

    func testCellularOnlyIsStable() {
        XCTAssertEqual(
            PathIdentity.classify(hasWiFi: false, hasCellular: true, wifiNetworkID: nil),
            .stable(.cellular)
        )
    }

    func testWiFiWithoutSSIDStaysTransitional() {
        // Full until named Wi‑Fi or cellular-only; never a timed “settle”.
        XCTAssertEqual(
            PathIdentity.classify(hasWiFi: true, hasCellular: false, wifiNetworkID: nil),
            .transitional
        )
        XCTAssertEqual(
            PathIdentity.classify(hasWiFi: true, hasCellular: true, wifiNetworkID: nil),
            .transitional
        )
    }

    func testNoInterfacesIsTransitional() {
        XCTAssertEqual(
            PathIdentity.classify(hasWiFi: false, hasCellular: false, wifiNetworkID: nil),
            .transitional
        )
    }

    func testKnownSSIDHelper() {
        XCTAssertTrue(PathIdentity.isKnownSSID("ssid:Home"))
        XCTAssertFalse(PathIdentity.isKnownSSID("unidentified"))
    }
}
