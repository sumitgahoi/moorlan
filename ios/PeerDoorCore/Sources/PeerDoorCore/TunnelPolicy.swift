import Foundation

/// Network defaults are automatic; a user can explicitly select split or exit.
public struct TunnelPolicy: Equatable, Codable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case automatic, split, exit
    }
    public var mode: Mode
    public var trustedNetworkIDs: Set<String>
    public var treatCellularAsTrusted: Bool

    public init(mode: Mode = .automatic, trustedNetworkIDs: Set<String> = [], treatCellularAsTrusted: Bool = true) {
        self.mode = mode
        self.trustedNetworkIDs = trustedNetworkIDs
        self.treatCellularAsTrusted = treatCellularAsTrusted
    }
    public enum PathKind: Equatable, Sendable {
        case serverLAN, cellular, wifi(id: String), other
    }
    public enum Decision: Equatable, Sendable {
        case disconnect(reason: String)
        case connect(fullTunnel: Bool)
    }
    public func decide(path: PathKind) -> Decision {
        if path == .serverLAN { return .disconnect(reason: "Already on the server LAN") }
        if mode == .exit { return .connect(fullTunnel: true) }
        if mode == .split { return .connect(fullTunnel: false) }
        switch path {
        case .serverLAN: return .disconnect(reason: "Already on the server LAN")
        case .cellular: return .connect(fullTunnel: !treatCellularAsTrusted)
        case .wifi(let id): return .connect(fullTunnel: !id.hasPrefix("ssid:") || !trustedNetworkIDs.contains(id))
        case .other: return .connect(fullTunnel: true)
        }
    }
    public func allowedIPs(lease: Lease, fullTunnel: Bool) -> [String] {
        var ips = Set(lease.prefixes.filter { !$0.isEmpty && $0 != "0.0.0.0/0" && $0 != "::/0" })
        if let lan = lease.lan, !lan.isEmpty { ips.insert(lan) }
        if fullTunnel { ips.insert("0.0.0.0/0"); ips.insert("::/0") }
        return ips.sorted()
    }
}

/// Non-secret, per-profile input to the Packet Tunnel extension. The private
/// identity is read separately from the shared Keychain.
public struct TunnelProfile: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var lease: Lease
    public var lan: String?
    public var policy: TunnelPolicy
    public var homeSSID: String?
    public init(server: PairedServer, policy: TunnelPolicy, homeSSID: String? = nil) {
        id = server.id
        name = server.displayName
        lease = server.lease
        // The extension doesn't need the deletion capability.
        lease.unjoinToken = nil
        lan = server.lan
        self.policy = policy
        self.homeSSID = homeSSID
    }
    public static func storageKey(_ id: String) -> String { "profile-" + id }
}
