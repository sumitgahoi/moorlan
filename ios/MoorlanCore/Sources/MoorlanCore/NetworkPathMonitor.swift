import Foundation
import Network
#if os(iOS)
import NetworkExtension
#endif

/// Observes the current path and classifies it for TunnelPolicy.
///
/// Stable = named Wi‑Fi or cellular-only. Otherwise `isStable == false` and
/// app/extension keep **Full** until a stable identity appears (indefinitely if
/// SSID never arrives). Missing SSID is never a user-facing error.
@MainActor
public final class NetworkPathMonitor: ObservableObject {
    public struct Snapshot: Equatable, Sendable {
        public var kind: TunnelPolicy.PathKind
        public var interfaces: [String]
        public var saturated: Bool
        public var wifiNetworkID: String?
        /// False while unsettled; policy should use Full.
        public var isStable: Bool

        public init(
            kind: TunnelPolicy.PathKind,
            interfaces: [String] = [],
            saturated: Bool = true,
            wifiNetworkID: String? = nil,
            isStable: Bool = true
        ) {
            self.kind = kind
            self.interfaces = interfaces
            self.saturated = saturated
            self.wifiNetworkID = wifiNetworkID
            self.isStable = isStable
        }
    }

    @Published public private(set) var snapshot = Snapshot(kind: .other, isStable: false)

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "moorlan.path")
    private var latestPath: Network.NWPath?
    private var pathGeneration = 0
    private var wifiOverrideID: String?

    public init() {}

    public func setWiFiNetworkID(_ id: String?) {
        wifiOverrideID = normalizedSSID(id)
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
        let hasCellular = path.usesInterfaceType(.cellular)
        let hasWiFi = path.usesInterfaceType(.wifi)
        let wifiID = wifiOverrideID.flatMap { PathIdentity.isKnownSSID($0) ? $0 : nil }
        let saturated = path.status != .satisfied

        switch PathIdentity.classify(
            hasWiFi: hasWiFi,
            hasCellular: hasCellular,
            wifiNetworkID: wifiID
        ) {
        case .stable(let kind):
            let publishedWiFiID: String? = {
                if case .wifi(let id) = kind, PathIdentity.isKnownSSID(id) { return id }
                return nil
            }()
            snapshot = Snapshot(
                kind: kind,
                interfaces: interfaces,
                saturated: saturated,
                wifiNetworkID: publishedWiFiID,
                isStable: true
            )
        case .transitional:
            snapshot = Snapshot(
                kind: snapshot.kind,
                interfaces: interfaces,
                saturated: saturated,
                wifiNetworkID: snapshot.wifiNetworkID,
                isStable: false
            )
        }
    }

    private func normalizedSSID(_ id: String?) -> String? {
        guard let id, PathIdentity.isKnownSSID(id) else { return nil }
        return id
    }
}
