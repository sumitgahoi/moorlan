import Foundation

public enum MoorlanError: LocalizedError, Equatable, Sendable {
    case invalidCard(String)
    case pairingFailed(String)
    case unpairFailed(String)
    /// Full sentence already; used when the LAN control URL is unreachable.
    case lanUnreachable(String)
    case missingIdentity
    case tunnelFailed(String)
    case leaseIncomplete
    case vpnSuperseded
    case vpnConfigurationFailed
    case wifiNameUnavailable
    case tunnelStopped
    /// Packet tunnel came up but no WireGuard handshake arrived in time.
    case handshakeFailed
    case storageFailed
    /// Server already removed the peer; local cleanup should proceed.
    case unpairAlreadyGone

    public var errorDescription: String? {
        // Diagnostics / tests only. UI MUST use UserFacingError.map — never show this raw.
        switch self {
        case .invalidCard(let message): return message
        case .pairingFailed(let message): return message
        case .unpairFailed(let message): return message
        case .lanUnreachable(let message): return message
        case .missingIdentity: return "No WireGuard identity on this phone yet"
        case .tunnelFailed(let message): return message
        case .leaseIncomplete: return "Server did not return complete connection settings"
        case .vpnSuperseded: return "Another VPN is active"
        case .vpnConfigurationFailed: return "VPN configuration failed"
        case .wifiNameUnavailable: return "Wi‑Fi name unavailable"
        case .tunnelStopped: return "Tunnel stopped"
        case .handshakeFailed: return "Handshake failed"
        case .storageFailed: return "Could not save pairing on this iPhone"
        case .unpairAlreadyGone: return "Peer already removed on server"
        }
    }
}

/// Title + one plain sentence + primary action. No raw NE / URL strings in the UI.
public struct UserFacingError: Equatable, Sendable, Identifiable {
    public enum Action: Equatable, Sendable {
        case ok
        case retry
        case openSettings
    }

    public var title: String
    public var message: String
    public var action: Action

    public var id: String { "\(title)|\(message)|\(action)" }

    public init(title: String, message: String, action: Action = .ok) {
        self.title = title
        self.message = message
        self.action = action
    }

    public static func map(_ error: Error) -> UserFacingError {
        if let moorlan = error as? MoorlanError { return map(moorlan) }
        if let urlError = error as? URLError {
            return mapURLError(urlError)
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return mapURLError(URLError(URLError.Code(rawValue: ns.code)))
        }
        if ns.domain == "NEVPNErrorDomain" || ns.domain.contains("NetworkExtension") {
            return UserFacingError(
                title: "VPN setup failed",
                message: "Moorlan could not install or start the VPN profile. Check VPN permission in Settings, then try again.",
                action: .openSettings
            )
        }
        return UserFacingError(
            title: "Something went wrong",
            message: "Moorlan hit an unexpected problem. Try again in a moment.",
            action: .retry
        )
    }

    public static func map(_ error: MoorlanError) -> UserFacingError {
        switch error {
        case .invalidCard(let detail):
            return UserFacingError(
                title: "Unrecognized QR",
                message: friendlyDetail(detail, fallback: "This QR is not a Moorlan pair or unpair code this app understands."),
                action: .ok
            )
        case .pairingFailed(let detail):
            if detail.localizedCaseInsensitiveContains("identity") || detail.localizedCaseInsensitiveContains("match") {
                return UserFacingError(
                    title: "Server mismatch",
                    message: "The host that answered is not the one on the QR. Scan again from the Moorlan host you intend to pair.",
                    action: .retry
                )
            }
            if detail.localizedCaseInsensitiveContains("complete") || detail.localizedCaseInsensitiveContains("lease") {
                return map(.leaseIncomplete)
            }
            return UserFacingError(
                title: "Pairing rejected",
                message: friendlyDetail(detail, fallback: "The Moorlan host rejected this pairing. Check the host is in pair mode, then scan again."),
                action: .retry
            )
        case .unpairFailed(let detail):
            if detail.localizedCaseInsensitiveContains("home Wi") || detail.localizedCaseInsensitiveContains("home Wi‑Fi")
                || detail.localizedCaseInsensitiveContains("marked Off") {
                return UserFacingError(
                    title: "Join an Off Wi‑Fi",
                    message: "Unpairing needs a Wi‑Fi marked Off for this tunnel. Connect there, then scan again.",
                    action: .retry
                )
            }
            if detail.localizedCaseInsensitiveContains("Pair again") || detail.localizedCaseInsensitiveContains("unpair support") {
                return UserFacingError(
                    title: "Re-pair required",
                    message: "This profile is missing its unpair credential. Pair with the host again, then unpair.",
                    action: .ok
                )
            }
            if detail.localizedCaseInsensitiveContains("different server") {
                return UserFacingError(
                    title: "Wrong host",
                    message: "That unpair QR belongs to a different Moorlan host than the one selected here.",
                    action: .ok
                )
            }
            return UserFacingError(
                title: "Could not unpair",
                message: friendlyDetail(detail, fallback: "The host did not confirm removal. Local pairing was kept so you can retry."),
                action: .retry
            )
        case .lanUnreachable(let detail):
            let needsSettings = detail.localizedCaseInsensitiveContains("Local Network")
                || detail.localizedCaseInsensitiveContains("Settings")
            return UserFacingError(
                title: "Can’t reach the host",
                message: friendlyDetail(detail, fallback: "Join Wi‑Fi near the host, allow Local Network for Moorlan, and keep the host in pair mode."),
                action: needsSettings ? .openSettings : .retry
            )
        case .missingIdentity:
            return UserFacingError(
                title: "Missing device key",
                message: "Moorlan could not load this phone’s WireGuard identity. Try again; if it keeps failing, delete and reinstall the app.",
                action: .retry
            )
        case .tunnelFailed:
            return UserFacingError(
                title: "VPN setup failed",
                message: "Moorlan could not prepare the tunnel. Check VPN permission in Settings, then try again.",
                action: .openSettings
            )
        case .leaseIncomplete:
            return UserFacingError(
                title: "Incomplete lease",
                message: "The host did not return complete connection settings. Update the Moorlan server, then pair again.",
                action: .ok
            )
        case .vpnSuperseded:
            return UserFacingError(
                title: "Paused — another VPN is active",
                message: "Only one VPN can be active at a time. Turn off the other VPN (for example Tailscale), then tap Retry.",
                action: .retry
            )
        case .vpnConfigurationFailed:
            return UserFacingError(
                title: "VPN permission needed",
                message: "Allow Moorlan to add a VPN configuration, then try again.",
                action: .openSettings
            )
        case .wifiNameUnavailable:
            return UserFacingError(
                title: "Wi‑Fi name unavailable",
                message: "iOS did not share this network’s name. Allow Wi‑Fi Information / Location for Moorlan in Settings, then try again.",
                action: .openSettings
            )
        case .tunnelStopped:
            return UserFacingError(
                title: "Tunnel stopped",
                message: "Moorlan is no longer connected. Tap Retry when you want to connect again.",
                action: .retry
            )
        case .handshakeFailed:
            return UserFacingError(
                title: "Host didn’t respond",
                message: "The tunnel is up, but the Moorlan host did not complete a handshake. Make sure the host is online, then tap Retry.",
                action: .retry
            )
        case .storageFailed:
            return UserFacingError(
                title: "Couldn’t save on this iPhone",
                message: "Moorlan could not update local pairing data. Free some storage, then try again.",
                action: .retry
            )
        case .unpairAlreadyGone:
            return UserFacingError(
                title: "Already unpaired",
                message: "The host no longer has this device. Local VPN settings will be removed.",
                action: .ok
            )
        }
    }

    private static func mapURLError(_ error: URLError) -> UserFacingError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return UserFacingError(
                title: "Can’t reach the host",
                message: "Join Wi‑Fi near the host, allow Local Network for Moorlan, and keep the host in pair mode.",
                action: .openSettings
            )
        default:
            return UserFacingError(
                title: "Network problem",
                message: "Moorlan could not finish this network request. Check your connection and try again.",
                action: .retry
            )
        }
    }

    /// Drops raw HTTP / POSIX / URL fragments from UI copy when present.
    private static func friendlyDetail(_ detail: String, fallback: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return fallback }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http "), lower.contains("error") { return fallback }
        if lower.contains("nsurlerror") || lower.contains("posix") { return fallback }
        if lower.contains("nevpn") || lower.contains("networkextension") { return fallback }
        if trimmed.hasPrefix("Error Domain=") { return fallback }
        if trimmed.range(of: #"^HTTP \d{3}$"#, options: .regularExpression) != nil {
            return fallback
        }
        return trimmed
    }
}
