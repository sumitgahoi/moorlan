import Foundation
import Network
#if os(iOS)
import NetworkExtension
#endif

/// Observes the current path and classifies it for TunnelPolicy.
@MainActor
public final class NetworkPathMonitor: ObservableObject {
    public struct Snapshot: Equatable, Sendable {
        public var kind: TunnelPolicy.PathKind
        public var interfaces: [String]
        public var saturated: Bool
        public var wifiNetworkID: String?

        public init(kind: TunnelPolicy.PathKind, interfaces: [String] = [], saturated: Bool = true, wifiNetworkID: String? = nil) {
            self.kind = kind
            self.interfaces = interfaces
            self.saturated = saturated
            self.wifiNetworkID = wifiNetworkID
        }
    }

    @Published public private(set) var snapshot = Snapshot(kind: .other)

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "moorlan.path")
    private var latestPath: Network.NWPath?
    private var pathGeneration = 0
    /// Optional richer Wi‑Fi id (e.g. `ssid:Home`) supplied by the app after NEHotspotNetwork lookup.
    private var wifiOverrideID: String?

    public init() {}

    public func setWiFiNetworkID(_ id: String?) {
        wifiOverrideID = id
        if let latestPath {
            apply(latestPath)
        }
    }

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.latestPath = path
                self.pathGeneration += 1
                let generation = self.pathGeneration
                #if os(iOS)
                if path.usesInterfaceType(.wifi) {
                    // Read the current association before publishing it; never
                    // reuse the previous SSID or trust an interface fingerprint.
                    NEHotspotNetwork.fetchCurrent { network in
                        let ssid = network?.ssid
                        Task { @MainActor in
                            guard self.pathGeneration == generation else { return }
                            self.wifiOverrideID = ssid.flatMap { $0.isEmpty ? nil : "ssid:" + $0 }
                            self.apply(path)
                        }
                    }
                } else {
                    self.wifiOverrideID = nil
                    self.apply(path)
                }
                #else
                self.wifiOverrideID = nil
                self.apply(path)
                #endif
            }
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        monitor.cancel()
    }

    private func apply(_ path: Network.NWPath) {
        let interfaces = path.availableInterfaces.map(\.name)
        let kind: TunnelPolicy.PathKind
        if path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi) {
            kind = .cellular
        } else if path.usesInterfaceType(.wifi) {
            kind = .wifi(id: wifiFingerprint(interfaces: interfaces))
        } else {
            kind = .other
        }
        snapshot = Snapshot(kind: kind, interfaces: interfaces, saturated: path.status != .satisfied, wifiNetworkID: wifiOverrideID)
    }

    private func wifiFingerprint(interfaces: [String]) -> String {
        if let wifiOverrideID, !wifiOverrideID.isEmpty {
            return wifiOverrideID
        }
        // Interface names (en0) are hardware, not network identity. Unknown SSID
        // stays "unidentified"; TunnelPolicy fails closed (disconnect, never exit).
        _ = interfaces
        return "unidentified"
    }
}
