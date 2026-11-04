import NetworkExtension
import WireGuardKit
import MoorlanCore
import Combine

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var controller: TunnelController?
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        Task { @MainActor in
            do {
                let controller = TunnelController(provider: self)
                self.controller = controller
                try await controller.start()
                completionHandler(nil)
            } catch {
                await self.controller?.stop()
                completionHandler(error)
            }
        }
    }
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            await controller?.stop()
            controller = nil
            completionHandler()
        }
    }
    override func handleAppMessage(_ data: Data, completionHandler: ((Data?) -> Void)?) {
        Task { @MainActor in
            do { try await controller?.reload(); completionHandler?(Data("ok".utf8)) }
            catch { completionHandler?(nil) }
        }
    }
}

/// Policy runs inside the extension as well as the UI, so leaving the app does
/// not freeze the split/exit decision or disable same-LAN protection.
@MainActor
private final class TunnelController {
    private unowned let provider: PacketTunnelProvider
    private let monitor = NetworkPathMonitor()
    private var profile: TunnelProfile?
    private var subscription: AnyCancellable?
    private var lastFullTunnel: Bool?
    private var running = false
    private var updating = false
    private var pending = false
    private var stopping = false
    private lazy var adapter = WireGuardAdapter(with: provider) { _, message in
        NSLog("[Moorlan WireGuard] %@", message)
    }
    init(provider: PacketTunnelProvider) { self.provider = provider }

    private func readProfile() throws -> TunnelProfile {
        guard let proto = provider.protocolConfiguration as? NETunnelProviderProtocol,
              let id = proto.providerConfiguration?["profileID"] as? String,
              let raw = UserDefaults(suiteName: AppIdentity.appGroup)?.data(forKey: TunnelProfile.storageKey(id)) else {
            throw MoorlanError.tunnelFailed("Open Moorlan and select this profile to configure it")
        }
        return try JSONDecoder().decode(TunnelProfile.self, from: raw)
    }
    func start() async throws {
        let profile = try readProfile()
        self.profile = profile
        monitor.start()
        for _ in 0..<40 {
            if !monitor.snapshot.saturated { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let homeSSIDs = Set(profile.homeSSIDs)
        guard case .connect(let full) = profile.policy.decide(path: monitor.snapshot.kind, homeSSIDs: homeSSIDs) else {
            monitor.stop()
            throw MoorlanError.tunnelFailed("On a home Wi‑Fi network")
        }
        guard !stopping else { throw CancellationError() }
        let config = try configuration(full: full)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            adapter.start(tunnelConfiguration: config) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
        guard !stopping else { throw CancellationError() }
        running = true
        lastFullTunnel = full
        subscription = monitor.$snapshot.removeDuplicates().sink { [weak self] _ in
            Task { @MainActor in await self?.applyPolicy() }
        }
    }
    private func configuration(full: Bool) throws -> TunnelConfiguration {
        guard let profile, let identity = try IdentityStore(accessGroup: AppIdentity.keychainAccessGroup).load() else {
            throw MoorlanError.missingIdentity
        }
        return try WireGuardProfileBuilder.build(profile, privateKey: identity.privateKey, fullTunnel: full)
    }
    func reload() async throws {
        profile = try readProfile()
        lastFullTunnel = nil
        await applyPolicy()
    }
    private func applyPolicy() async {
        guard running, !stopping else { return }
        if updating { pending = true; return }
        updating = true
        defer { updating = false }
        repeat {
            pending = false
            guard let profile, !monitor.snapshot.saturated else { return }
            let homeSSIDs = Set(profile.homeSSIDs)
            switch profile.policy.decide(path: monitor.snapshot.kind, homeSSIDs: homeSSIDs) {
            case .disconnect:
                await stop()
                provider.cancelTunnelWithError(nil)
                return
            case .connect(let full):
                guard full != lastFullTunnel else { continue }
                do {
                    let config = try configuration(full: full)
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        adapter.update(tunnelConfiguration: config) { error in
                            if let error { cont.resume(throwing: error) } else { cont.resume() }
                        }
                    }
                    lastFullTunnel = full
                } catch { provider.cancelTunnelWithError(error); return }
            }
        } while pending && !stopping
    }
    func stop() async {
        guard !stopping else { return }
        stopping = true
        monitor.stop()
        subscription?.cancel()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            adapter.stop { _ in cont.resume() }
        }
        running = false
    }
}
