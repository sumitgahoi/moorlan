import Foundation

/// Phone-owned tunnel knobs. Does not change server lease identity.
public struct ClientTunnelSettings: Codable, Equatable, Sendable {
    /// When non-nil, replaces lease DNS for this phone. `nil` follows the lease
    /// (and exit-mode Cloudflare fallback when the lease has no DNS).
    public var dns: [String]?
    /// When non-nil, replaces lease DNS search domains.
    public var dnsSearch: [String]?
    /// When non-nil, replaces lease MTU.
    public var mtu: Int?
    /// When non-nil, replaces lease persistent keepalive.
    public var persistentKeepalive: Int?

    public init(
        dns: [String]? = nil,
        dnsSearch: [String]? = nil,
        mtu: Int? = nil,
        persistentKeepalive: Int? = nil
    ) {
        self.dns = dns
        self.dnsSearch = dnsSearch
        self.mtu = mtu
        self.persistentKeepalive = persistentKeepalive
    }

    public struct ParseError: Error, Equatable, Sendable {
        public var message: String
        public init(_ message: String) { self.message = message }
    }

    /// Parses a comma-separated DNS list. Empty / whitespace → `nil` (follow server).
    public static func parseDNS(_ text: String) -> Result<[String]?, ParseError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .success(nil) }
        var out: [String] = []
        var seen = Set<String>()
        for part in trimmed.split(separator: ",") {
            let ip = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if ip.isEmpty { continue }
            guard IPv4Address(ip) != nil else {
                return .failure(ParseError("Invalid DNS address: \(ip)"))
            }
            if seen.insert(ip).inserted {
                out.append(ip)
            }
        }
        if out.isEmpty { return .success(nil) }
        return .success(out)
    }

    /// Parses comma-separated search domains. Empty → `nil` (follow server).
    public static func parseDNSSearch(_ text: String) -> Result<[String]?, ParseError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .success(nil) }
        var out: [String] = []
        var seen = Set<String>()
        for part in trimmed.split(separator: ",") {
            var domain = part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if domain.hasSuffix(".") { domain.removeLast() }
            if domain.isEmpty { continue }
            guard isValidSearchDomain(domain) else {
                return .failure(ParseError("Invalid search domain: \(domain)"))
            }
            if seen.insert(domain).inserted {
                out.append(domain)
            }
        }
        if out.isEmpty { return .success(nil) }
        return .success(out)
    }

    public static func formatDNS(_ servers: [String]?) -> String {
        (servers ?? []).joined(separator: ", ")
    }

    public static func formatDNSSearch(_ domains: [String]?) -> String {
        (domains ?? []).joined(separator: ", ")
    }

    private static func isValidSearchDomain(_ domain: String) -> Bool {
        guard !domain.isEmpty, domain.count <= 253 else { return false }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !labels.isEmpty else { return false }
        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return false }
            guard label.first != "-", label.last != "-" else { return false }
            for scalar in label.unicodeScalars {
                let ok = (scalar >= "a" && scalar <= "z")
                    || (scalar >= "0" && scalar <= "9")
                    || scalar == "-"
                if !ok { return false }
            }
        }
        return true
    }
}
