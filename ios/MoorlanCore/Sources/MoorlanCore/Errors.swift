import Foundation

public enum MoorlanError: LocalizedError, Equatable {
    case invalidCard(String)
    case pairingFailed(String)
    case unpairFailed(String)
    /// Full sentence already; used when the LAN control URL is unreachable.
    case lanUnreachable(String)
    case missingIdentity
    case tunnelFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCard(let message): return "Invalid QR card: \(message)"
        case .pairingFailed(let message): return "Pairing failed: \(message)"
        case .unpairFailed(let message): return "Could not unpair: \(message)"
        case .lanUnreachable(let message): return message
        case .missingIdentity: return "No WireGuard identity on this phone yet"
        case .tunnelFailed(let message): return "Tunnel failed: \(message)"
        }
    }
}
