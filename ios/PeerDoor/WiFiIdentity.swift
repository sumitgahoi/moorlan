import Foundation
import NetworkExtension
import CoreLocation
import PeerDoorCore

/// Apple requires Wi-Fi Information capability plus an eligible privacy condition
/// (such as precise location access) before it exposes the SSID.
@MainActor
final class WiFiIdentity: NSObject, CLLocationManagerDelegate {
    static let shared = WiFiIdentity()
    private let location = CLLocationManager()
    private weak var monitor: NetworkPathMonitor?
    override private init() {
        super.init()
        location.delegate = self
    }
    static func refresh(into monitor: NetworkPathMonitor) {
        NEHotspotNetwork.fetchCurrent { network in
            let ssid = network?.ssid
            Task { @MainActor in
                monitor.setWiFiNetworkID(ssid.flatMap { $0.isEmpty ? nil : "ssid:" + $0 })
            }
        }
    }
    static func requestAccess(into monitor: NetworkPathMonitor) {
        shared.monitor = monitor
        shared.location.requestWhenInUseAuthorization()
        refresh(into: monitor)
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if let monitor = self.monitor { Self.refresh(into: monitor) }
        }
    }
}
