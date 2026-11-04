import Foundation

/// User-facing copy when the phone cannot open the LAN control URL from a QR.
public enum LANReachability {
    public static func endpointDescription(for url: URL) -> String {
        guard let host = url.host, !host.isEmpty else { return url.absoluteString }
        return "\(host):\(url.port ?? 80)"
    }

    public static func unreachableMessage(for url: URL) -> String {
        let endpoint = endpointDescription(for: url)
        return "Cannot reach \(endpoint). Join home Wi‑Fi, allow Local Network for Moorlan in Settings, keep moorlan running with -private-endpoint \(endpoint), and check firewall/VLAN access to that address."
    }

    /// Maps transport failures to a clear LAN message; leaves other errors unchanged.
    public static func mapTransportError(_ error: Error, url: URL) -> Error {
        guard isUnreachable(error) else { return error }
        return MoorlanError.lanUnreachable(unreachableMessage(for: url))
    }

    public static func isUnreachable(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .networkConnectionLost,
                 .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost,
                 .internationalRoamingOff, .dataNotAllowed:
                return true
            default:
                return false
            }
        }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        switch ns.code {
        case NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
             NSURLErrorNotConnectedToInternet, NSURLErrorDNSLookupFailed, NSURLErrorCannotFindHost:
            return true
        default:
            return false
        }
    }
}
