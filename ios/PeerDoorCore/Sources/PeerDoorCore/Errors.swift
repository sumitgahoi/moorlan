import Foundation

public enum PeerDoorError: LocalizedError, Equatable {
    case invalidCard(String)
    case pairingFailed(String)
    case unjoinFailed(String)
    case missingIdentity
    case tunnelFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCard(let message): return "Invalid QR card: \(message)"
        case .pairingFailed(let message): return "Pairing failed: \(message)"
        case .unjoinFailed(let message): return "Could not unjoin: \(message)"
        case .missingIdentity: return "No WireGuard identity on this phone yet"
        case .tunnelFailed(let message): return "Tunnel failed: \(message)"
        }
    }
}
