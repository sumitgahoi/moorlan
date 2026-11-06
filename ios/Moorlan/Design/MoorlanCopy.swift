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

    static func routingSubtitle(_ routing: NetworkRouting) -> String {
        switch routing {
        case .off: return "Tunnel stays down"
        case .split: return "Only home traffic through the tunnel"
        case .full: return "All traffic through home"
        }
    }

    static let routingTip =
        "Off keeps the tunnel down. Split sends only home traffic through the tunnel. Full sends everything through home."
    static let homeRoutingFooter =
        "Until you leave this network. Change permanently in Settings."
    static let settingsNetworksFooter =
        "Saved for each network. Unmarked Wi‑Fi defaults to Full."
    static let settingsCellularFooter =
        "Default is Split. Same three options as Wi‑Fi."

    static let defaultBadge = "Default"
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
    static let nameWifi = "Waiting for Wi‑Fi name"

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
    static let tunnelDetailsA11y = "Details for"
    static let pickTunnelA11y = "Select this tunnel"
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
    static let cellularSection = "Cellular"
    static let wifiSection = "Wi‑Fi"
    static let allowWifiName = "Allow Wi‑Fi name"
    static let onCellular = "On cellular"
    static let onWifiNeedName = "On Wi‑Fi — tap to learn its name"
    static let noWifiYet = "No Wi‑Fi name yet"
    static let hereNow = "Here now"

    // TEMP DNS
    static let dnsTempHeader = "DNS (temp)"
    static let dnsTempPlaceholder = "e.g. 1.1.1.1, 1.0.0.1"
    static let dnsTempFooter =
        "Overrides the house lease DNS for debugging. Clear to follow the lease again. Remove this later."
    static let dnsTempInvalidTitle = "Invalid DNS"

    // Details
    static let detailsTitle = "Tunnel details"
    static let detailsJoined = "Joined"
    static let detailsAddress = "Phone address"
    static let detailsEndpoint = "Endpoint"
    static let detailsTunnel = "Tunnel network"
    static let detailsHomeNets = "Home networks"
    static let detailsDNS = "DNS"
    static let detailsSearch = "Search domains"
    static let detailsKeepalive = "Keepalive"
    static let detailsKey = "Server public key"
}
