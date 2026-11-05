import Foundation
import WireGuardKit
import MoorlanCore

/// WireGuardKit owns key parsing, endpoint parsing, IP ranges, and tunnel setup.
enum WireGuardProfileBuilder {
    static func build(_ profile: TunnelProfile, privateKey: String, fullTunnel: Bool) throws -> TunnelConfiguration {
        guard let key = PrivateKey(base64Key: privateKey),
              let address = IPAddressRange(from: profile.lease.address),
              let publicKey = PublicKey(base64Key: profile.lease.publicKey),
              let text = profile.lease.endpoint, let endpoint = Endpoint(from: text) else {
            throw MoorlanError.tunnelFailed("Invalid WireGuard profile")
        }
        var interface = InterfaceConfiguration(privateKey: key)
        interface.addresses = [address]
        if let mtu = profile.lease.mtu { interface.mtu = UInt16(exactly: mtu) }

        let dnsServers = profile.lease.dnsServers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { DNSServer(from: $0) }
        guard !dnsServers.isEmpty else {
            throw MoorlanError.leaseIncomplete
        }
        interface.dns = dnsServers

        let search = (profile.lease.dnsSearch ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !search.isEmpty {
            interface.dnsSearch = search
        }

        var peer = PeerConfiguration(publicKey: publicKey)
        peer.endpoint = endpoint
        peer.persistentKeepAlive = UInt16(exactly: profile.lease.persistentKeepalive ?? 25)
        peer.allowedIPs = try profile.policy.allowedIPs(lease: profile.lease, fullTunnel: fullTunnel).map {
            guard let range = IPAddressRange(from: $0) else { throw MoorlanError.tunnelFailed("Invalid route \($0)") }
            return range
        }
        return TunnelConfiguration(name: profile.name, interface: interface, peers: [peer])
    }
}
