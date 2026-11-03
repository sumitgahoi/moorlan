import Foundation
import Network
import Darwin
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
    private let queue = DispatchQueue(label: "peerdoor.path")
    private var serverLAN: String?
    private var latestPath: Network.NWPath?
    private var pathGeneration = 0
    /// Optional richer Wi‑Fi id (e.g. `ssid:Home`) supplied by the app after NEHotspotNetwork lookup.
    private var wifiOverrideID: String?

    public init() {}

    public func setServerLAN(_ cidr: String?) {
        guard serverLAN != cidr else { return }
        serverLAN = cidr
        if let latestPath {
            apply(latestPath)
        }
    }

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
                // Hairpin protection must not wait for an optional SSID lookup.
                if let serverLAN = self.serverLAN, self.onServerLAN(serverLAN) {
                    self.wifiOverrideID = nil
                    self.apply(path)
                }
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
        if let serverLAN, onServerLAN(serverLAN) {
            kind = .serverLAN
        } else if path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi) {
            kind = .cellular
        } else if path.usesInterfaceType(.wifi) {
            kind = .wifi(id: wifiFingerprint(interfaces: interfaces))
        } else {
            kind = .other
        }
        snapshot = Snapshot(kind: kind, interfaces: interfaces, saturated: path.status != .satisfied, wifiNetworkID: wifiOverrideID)
    }

    /// Best-effort same-LAN check using the phone's current IPv4 addresses.
    private func onServerLAN(_ cidr: String) -> Bool {
        guard let network = IPv4Network(cidr) else { return false }
        for address in localIPv4Addresses() where network.contains(address) {
            return true
        }
        return false
    }

    private func wifiFingerprint(interfaces: [String]) -> String {
        if let wifiOverrideID, !wifiOverrideID.isEmpty {
            return wifiOverrideID
        }
        // An interface name such as en0 identifies hardware, not a Wi-Fi network.
        // Unknown networks always use the untrusted default and cannot be trusted.
        return "unidentified"

    }
}

struct IPv4Network {
    let network: UInt32
    let mask: UInt32

    init?(_ cidr: String) {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              (0...32).contains(prefix),
              let ip = IPv4Address(String(parts[0])) else {
            return nil
        }
        mask = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
        network = ip.raw & mask
    }

    func contains(_ ip: IPv4Address) -> Bool {
        (ip.raw & mask) == network
    }
}

struct IPv4Address {
    let raw: UInt32

    init?(_ text: String) {
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
        raw = UInt32(bigEndian: address.s_addr)
    }
}

func localIPv4Addresses() -> [IPv4Address] {
    var addresses: [IPv4Address] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
    defer { freeifaddrs(ifaddr) }

    var ptr: UnsafeMutablePointer<ifaddrs>? = first
    while let current = ptr {
        let flags = Int32(current.pointee.ifa_flags)
        let isUp = (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING)
        let isLoopback = (flags & IFF_LOOPBACK) != 0
        let name = String(cString: current.pointee.ifa_name)
        // Only physical Wi-Fi/Ethernet addresses participate in hairpin detection.
        // A VPN's utun address must never make an away network look like home.
        if isUp, !isLoopback, name.hasPrefix("en"), let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                let text = String(cString: hostname)
                if let ip = IPv4Address(text) {
                    addresses.append(ip)
                }
            }
        }
        ptr = current.pointee.ifa_next
    }
    return addresses
}
