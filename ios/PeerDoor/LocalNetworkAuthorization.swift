import Foundation
import Network
import PeerDoorCore

/// iOS prompts when actual LAN traffic is attempted. There is no standalone
/// requestAuthorization API; an NWConnection lets us report a privacy denial.
@MainActor
final class LocalNetworkAuthorization {
    static let shared = LocalNetworkAuthorization()
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?

    func ensureAccess(to url: URL) async throws {
        guard let host = url.host, let number = UInt16(exactly: url.port ?? 80), number > 0, let port = NWEndpoint.Port(rawValue: number) else {
            throw PeerDoorError.pairingFailed("Invalid LAN address")
        }
        finish(PeerDoorError.pairingFailed("Another LAN request started"))
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                Task { @MainActor in
                    guard let self, self.connection === connection else { return }
                    switch state {
                    case .ready: self.finish(nil)
                    case .waiting:
                        if connection?.currentPath?.unsatisfiedReason == .localNetworkDenied {
                            self.finish(PeerDoorError.pairingFailed("Allow Local Network in iPhone Settings → PeerDoor, then retry."))
                        }
                    case .failed:
                        self.finish(PeerDoorError.pairingFailed("Cannot reach the host. Check Local Network permission, home Wi-Fi, and that PeerDoor is running."))
                    default: break
                    }
                }
            }
            connection.pathUpdateHandler = { [weak self, weak connection] path in
                guard path.unsatisfiedReason == .localNetworkDenied else { return }
                Task { @MainActor in
                    guard let self, self.connection === connection else { return }
                    self.finish(PeerDoorError.pairingFailed("Allow Local Network in iPhone Settings → PeerDoor, then retry."))
                }
            }
            connection.start(queue: .main)
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                self?.finish(PeerDoorError.pairingFailed("LAN connection timed out. Allow Local Network in Settings and check the server."))
            }
        }
    }
    private func finish(_ error: Error?) {
        let pending = continuation
        continuation = nil
        connection?.cancel()
        connection = nil
        timeout?.cancel()
        timeout = nil
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
}
