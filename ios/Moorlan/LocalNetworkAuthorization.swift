import Foundation
import Network
import MoorlanCore

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
            throw MoorlanError.lanUnreachable("Invalid LAN address in the QR code.")
        }
        finish(MoorlanError.lanUnreachable("Another LAN request started; try again."))
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
                            self.finish(MoorlanError.lanUnreachable(
                                "Allow Local Network for Moorlan in iPhone Settings, then scan again."
                            ))
                        }
                    case .failed:
                        self.finish(MoorlanError.lanUnreachable(LANReachability.unreachableMessage(for: url)))
                    default: break
                    }
                }
            }
            connection.pathUpdateHandler = { [weak self, weak connection] path in
                guard path.unsatisfiedReason == .localNetworkDenied else { return }
                Task { @MainActor in
                    guard let self, self.connection === connection else { return }
                    self.finish(MoorlanError.lanUnreachable(
                        "Allow Local Network for Moorlan in iPhone Settings, then scan again."
                    ))
                }
            }
            connection.start(queue: .main)
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                self?.finish(MoorlanError.lanUnreachable(LANReachability.unreachableMessage(for: url)))
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
