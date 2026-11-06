import Foundation
import WireGuardKit
import MoorlanCore

/// WireGuardKit owns key parsing, endpoint parsing, IP ranges, and tunnel setup.
enum WireGuardProfileBuilder {
    /// Last-resort exit DNS when the lease has no resolvers (pre-dns pairs).
    private static let legacyExitDNS = ["1.1.1.1", "1.0.0.1"]

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

        let resolved = resolveDNS(policy: profile.policy, lease: profile.lease, fullTunnel: fullTunnel)
        let dnsServers = resolved.servers.compactMap { DNSServer(from: $0) }
        if !dnsServers.isEmpty {
            interface.dns = dnsServers
            if !resolved.search.isEmpty {
                interface.dnsSearch = resolved.search
            }
        }

        var peer = PeerConfiguration(publicKey: publicKey)
        peer.endpoint = endpoint
        peer.persistentKeepAlive = UInt16(exactly: profile.lease.persistentKeepalive ?? 25)

        // Host-route the resolvers we actually install so matchDomains DNS is reachable.
        var routeLease = profile.lease
        routeLease.dnsServers = resolved.servers
        peer.allowedIPs = try profile.policy.allowedIPs(lease: routeLease, fullTunnel: fullTunnel).map {
            guard let range = IPAddressRange(from: $0) else { throw MoorlanError.tunnelFailed("Invalid route \($0)") }
            return range
        }
        return TunnelConfiguration(name: profile.name, interface: interface, peers: [peer])
    }

    /// TEMP override > lease `dns_servers` (+ search) > legacy Cloudflare on exit only.
    private static func resolveDNS(
        policy: TunnelPolicy,
        lease: Lease,
        fullTunnel: Bool
    ) -> (servers: [String], search: [String]) {
        let search = (lease.dnsSearch ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let override = policy.dnsOverride {
            let servers = override
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !servers.isEmpty {
                // Keep lease search domains so carbon → carbon.home.arpa still works
                // when overriding to the same LAN resolver (or any that serves home.arpa).
                return (servers, search)
            }
        }

        let leaseDNS = lease.dnsServers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !leaseDNS.isEmpty {
            return (leaseDNS, search)
        }

        if fullTunnel {
            return (legacyExitDNS, [])
        }
        return ([], [])
    }
}
