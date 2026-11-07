import Foundation
import MoorlanCore

/// Plain household English for Off / Split / Full.
enum MoorlanCopy {
    static let routingOff = "Off"
    static let routingSplit = "Split"
    static let routingFull = "Full"

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
            return "Only home traffic goes through the tunnel. Everything else stays on this network. Recommended on trusted networks."
        case .full:
            return "All traffic goes through home. Recommended for untrusted networks."
        }
    }

    static let homeRoutingFooter =
        "Until you leave this network. Change permanently in Settings."

    static let defaultBadge = "Default"
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
    static let emptyTitle = "Pair with your home"
    static let emptyBody =
        "On home Wi‑Fi, open the Camera app and scan the QR from sudo moorlan --pair. Moorlan opens and pairs."
    static let emptyButton = "Or scan in Moorlan"
    static let scanTitle = "Scan"
    static let scanBody =
        "Fallback if Camera didn’t open the app. Pair adds a house; unpair removes one. Best on home Wi‑Fi."
    static let scanNavA11y = "Scan QR code"
    static let removeTunnelA11y = "Unpair"
    static let tunnelsTitle = "Tunnels"
    static let tunnelDetailsA11y = "Details for"
    static let pickTunnelA11y = "Select this tunnel"
    static let openTunnelDetailsA11y = "Shows details"
    static let editTunnel = "Edit"
    static let editTunnelTitle = "Edit Name"
    static let editTunnelSave = "Save"
    static let detailsMenu = "Details"
    static let paired = "Paired"
    static let pairing = "Pairing…"
    static let reachingServer = "Reaching server…"
    static let unpairing = "Unpairing…"
    static let unpaired = "Unpaired"
    static let unpairConfirmTitlePrefix = "Unpair"
    static let unpairConfirmButton = "Unpair"
    static let unpairConfirmMessage = "This removes the VPN profile for this house from your iPhone."

    // Settings
    static let settingsTitle = "Settings"
    static let routingPolicySection = "Routing Policy"
    static let routingPolicyInfoA11y = "About Routing Policy"
    static let cellularSection = "Cellular"
    static let allowWifiName = "Allow Wi‑Fi name"
    static let onCellular = "On cellular"
    static let onWifiNeedName = "On Wi‑Fi — tap to learn its name"
    static let noWifiYet = "No Wi‑Fi name yet"
    static let homeBadge = "Home"

    // Details
    static let detailsTitle = "Details"
    static let detailsAddress = "Phone address"
    static let detailsEndpoint = "Endpoint"
    static let detailsTunnel = "Tunnel network"
    static let detailsHomeNets = "Home networks"
    static let detailsDNS = "DNS"
    static let detailsSearch = "Search domains"
    static let detailsKeepalive = "Keepalive"
}
