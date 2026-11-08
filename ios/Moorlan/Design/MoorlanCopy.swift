import Foundation
import MoorlanCore

/// Plain English for Off / Split / Full and shared UI strings.
enum MoorlanCopy {
    static let routingOff = "Off"
    static let routingSplit = "Split"
    static let routingFull = "Full"
    static let routingSection = "Routing"
    static let routingPolicySection = "About Routing"
    static let routingPolicyInfoA11y = "About Routing"

    static func routingTitle(_ routing: NetworkRouting) -> String {
        switch routing {
        case .off: return routingOff
        case .split: return routingSplit
        case .full: return routingFull
        }
    }

    static func routingSymbol(_ routing: NetworkRouting) -> String {
        switch routing {
        case .off: return "pause.circle"
        case .split: return "arrow.triangle.branch"
        case .full: return "globe"
        }
    }

    static func routingInfoTitle(_ routing: NetworkRouting) -> String {
        switch routing {
        case .off: return routingOff
        case .split: return routingSplit
        case .full: return "Full Tunnel"
        }
    }

    static func routingInfoBody(_ routing: NetworkRouting) -> String {
        switch routing {
        case .off:
            return "The tunnel stays off. Your phone uses the network as usual."
        case .split:
            return "Only this tunnel’s private networks go through. Everything else stays on this network. Recommended on trusted networks."
        case .full:
            return "All traffic goes through the tunnel. Recommended for untrusted networks."
        }
    }

    static let defaultBadge = "Default"
    static let onDemandDefaultTitle = "On-demand default"
    static let onDemandDefaultBody =
        "This tunnel auto-connects when you’re away from Off networks. Other tunnels do not."
    static let connectedBadge = "Connected"
    static let offHereBadge = "Off"
    static let useAsDefault = "Use as default"
    static let useAsDefaultTitle = "Use as your default?"
    static let useAsDefaultMessage =
        "This tunnel will auto-connect when you’re away. Other tunnels will stop auto-connecting."
    static let useAsDefaultYes = "Use as default"
    static let useAsDefaultNo = "Not now"

    // Status
    static let offOnNetwork = "Off on this network"
    static let connecting = "Connecting…"
    static let disconnecting = "Disconnecting…"
    static let needsAttention = "Needs attention"
    static let needNetwork = "Need Wi‑Fi or cellular"

    // Empty / scan
    static let emptyTitle = "Pair a tunnel"
    static let emptyBody =
        "On Wi‑Fi near the Moorlan host, open the Camera app and scan the QR from sudo moorlan --pair. Moorlan opens and pairs."
    static let emptyButton = "Or scan in Moorlan"
    static let scanTitle = "Scan"
    static let scanBody =
        "Fallback if Camera didn’t open the app. Pair adds a tunnel; unpair removes one. Best on Wi‑Fi near the host."
    static let scanNavA11y = "Scan QR code"
    static let removeTunnelA11y = "Unpair"
    static let tunnelsTitle = "Tunnels"
    static let tunnelDetailsA11y = "Details for"
    static let pickTunnelA11y = "Select this tunnel"
    static let openTunnelDetailsA11y = "Shows details"
    static let paired = "Paired"
    static let pairing = "Pairing…"
    static let reachingServer = "Reaching server…"
    static let unpairing = "Unpairing…"
    static let unpaired = "Unpaired"
    static let unpairConfirmTitlePrefix = "Unpair"
    static let unpairConfirmButton = "Unpair"
    static let unpairConfirmMessage = "This removes the VPN profile for this tunnel from your iPhone."

    // Details
    static let detailsTitle = "Details"
    static let detailsAddress = "Phone address"
    static let detailsEndpoint = "Endpoint"
    static let detailsTunnel = "Tunnel network"
    static let detailsPrivateNets = "Private networks"
    static let detailsDNS = "DNS"
    static let detailsSearch = "Search domains"
    static let detailsKeepalive = "Keepalive"
}
