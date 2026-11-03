import Foundation
import NetworkExtension
import PeerDoorCore
import Combine

@MainActor
final class TunnelManager: ObservableObject {
    enum Status: Equatable { case disconnected, connecting, connected, disconnecting, invalid }
    @Published private(set) var status: Status = .disconnected
    @Published private(set) var statusReason: String?
    @Published var policy: TunnelPolicy
    @Published private(set) var servers: [PairedServer]
    @Published private(set) var selectedServerID: String?
    @Published var lastError: String?
    @Published private(set) var isUnjoining = false

    private let store = ServerStore()
    private let identityStore = IdentityStore(accessGroup: AppIdentity.keychainAccessGroup)
    private let pathMonitor = NetworkPathMonitor()
    private var manager: NETunnelProviderManager?
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    private var lastProfile: TunnelProfile?
    private var applying = false
    private var needsApply = false
    private var userWantsTunnel = true

    var selectedServer: PairedServer? { servers.first { $0.id == selectedServerID } ?? servers.first }
    var pathKind: TunnelPolicy.PathKind { pathMonitor.snapshot.kind }
    var currentNetworkID: String? {
        guard let id = pathMonitor.snapshot.wifiNetworkID, id.hasPrefix("ssid:") else { return nil }
        return id
    }
    var effectiveExit: Bool {
        if case .connect(let full) = policy.decide(path: pathKind) { return full }
        return false
    }

    init() {
        policy = store.loadPolicy()
        servers = store.loadServers()
        selectedServerID = UserDefaults.standard.string(forKey: "selected-server") ?? servers.first?.id
        pathMonitor.setServerLAN(selectedServer?.lan)
        observePath()
        observeVPN()
        pathMonitor.start()
        Task { await reloadManager(); await applyDesiredState() }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func savePolicy() {
        store.savePolicy(policy)
        lastProfile = nil
        Task { await applyDesiredState() }
    }
    func setExit(_ enabled: Bool) { policy.mode = enabled ? .exit : .split; savePolicy() }
    func identifyWiFi() { WiFiIdentity.requestAccess(into: pathMonitor) }
    func trustCurrentNetwork() {
        guard let id = currentNetworkID else { identifyWiFi(); return }
        policy.trustedNetworkIDs.insert(id)
        policy.mode = .automatic
        savePolicy()
    }
    func untrustCurrentNetwork() {
        if let id = currentNetworkID { policy.trustedNetworkIDs.remove(id); savePolicy() }
    }

    func pair(card: QRCard) async throws {
        try await LocalNetworkAuthorization.shared.ensureAccess(to: card.pairURL)
        let identity = try identityStore.loadOrCreate()
        let lease = try await PairingClient().pair(card: card, publicKey: identity.publicKey)
        let server = PairedServer(card: card, lease: lease)
        store.upsert(server)
        servers = store.loadServers()
        await selectProfile(server.id)
        // Install the native profile even on the home LAN, where starting it is forbidden.
        _ = try await configureProfile(server)
        await applyDesiredState()
    }

    func selectProfile(_ id: String) async {
        guard !isUnjoining, servers.contains(where: { $0.id == id }) else { return }
        if selectedServerID != id {
            manager?.isOnDemandEnabled = false
            try? await manager?.peerdoor_saveToPreferences()
            manager?.connection.stopVPNTunnel()
        }
        selectedServerID = id
        UserDefaults.standard.set(id, forKey: "selected-server")
        lastProfile = nil
        userWantsTunnel = true
        pathMonitor.setServerLAN(selectedServer?.lan)
        await reloadManager()
    }

    func unjoin(scanned card: UnjoinCard) async -> Bool {
        guard !isUnjoining, !applying else { lastError = "VPN configuration is busy. Retry shortly."; return false }
        do {
            let server = try card.pairedServer(in: servers)
            pathMonitor.setServerLAN(server.lan)
            defer { pathMonitor.setServerLAN(selectedServer?.lan) }
            guard pathKind == .serverLAN else { throw PeerDoorError.unjoinFailed("Delete profiles on the server’s home LAN") }
            isUnjoining = true
            defer { isUnjoining = false }
            guard let identity = try identityStore.load() ?? IdentityStore().load() else { throw PeerDoorError.missingIdentity }
            try await LocalNetworkAuthorization.shared.ensureAccess(to: card.unjoinURL)
            try await PairingClient().unjoin(server: server, publicKey: identity.publicKey, card: card)
            let installed = try await NETunnelProviderManager.peerdoor_loadAllFromPreferences()
            for profile in installed where matches(profile, server: server) {
                profile.connection.stopVPNTunnel()
                try await profile.peerdoor_removeFromPreferences()
            }
            let defaults = UserDefaults(suiteName: AppIdentity.appGroup)
            defaults?.removeObject(forKey: TunnelProfile.storageKey(server.id))
            defaults?.removeObject(forKey: "home-ssid-" + server.id)
            if selectedServer?.id == server.id {
                manager = nil
                defaults?.removeObject(forKey: AppIdentity.configKey) // Remove legacy rendered private configuration.
                defaults?.removeObject(forKey: AppIdentity.serverNameKey)
                selectedServerID = servers.first(where: { $0.id != server.id })?.id
                lastProfile = nil
                userWantsTunnel = false
                status = .disconnected
                statusReason = "Profile deleted"
            }
            servers.removeAll { $0.id == server.id }
            store.saveServers(servers)
            UserDefaults.standard.set(selectedServerID, forKey: "selected-server")
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func toggleDesiredConnection() async {
        if status == .connected || status == .connecting {
            userWantsTunnel = false
            manager?.isOnDemandEnabled = false
            try? await manager?.peerdoor_saveToPreferences()
            await disconnect()
        } else {
            userWantsTunnel = true
            lastProfile = nil
            await applyDesiredState()
        }
    }

    func applyDesiredState() async {
        guard !isUnjoining else { return }
        if applying { needsApply = true; return }
        applying = true
        defer { applying = false }
        repeat {
            needsApply = false
            await applyOnce()
        } while needsApply && !isUnjoining
    }
    private func applyOnce() async {
        guard let server = selectedServer else { await disconnect(); return }
        pathMonitor.setServerLAN(server.lan)
        guard !pathMonitor.snapshot.saturated else { statusReason = "Waiting for a network"; return }
        let decision = policy.decide(path: pathKind)
        do {
            let profile = makeProfile(server)
            let changed = profile != lastProfile
            if changed || manager == nil {
                manager = try await configureProfile(server)
                lastProfile = profile
            }
            switch decision {
            case .disconnect(let reason): statusReason = reason; await disconnect()
            case .connect(let full):
                statusReason = full ? "Exit node · all traffic" : "Subnet access · split tunnel"
                guard userWantsTunnel, let manager else { return }
                if manager.connection.status == .connected {
                    if changed, let session = manager.connection as? NETunnelProviderSession {
                        try session.sendProviderMessage(Data("reload-policy".utf8)) { _ in }
                    }
                } else if manager.connection.status != .connecting && manager.connection.status != .disconnecting && manager.connection.status != .reasserting {
                    try manager.connection.startVPNTunnel()
                }
                refreshStatus()
            }
        } catch { lastError = error.localizedDescription; status = .invalid }
    }

    private func makeProfile(_ server: PairedServer) -> TunnelProfile {
        let defaults = UserDefaults(suiteName: AppIdentity.appGroup)
        if pathKind == .serverLAN, let id = currentNetworkID {
            defaults?.set(String(id.dropFirst(5)), forKey: "home-ssid-" + server.id)
        }
        return TunnelProfile(server: server, policy: policy, homeSSID: defaults?.string(forKey: "home-ssid-" + server.id))
    }
    private func configureProfile(_ server: PairedServer) async throws -> NETunnelProviderManager {
        let identity = try identityStore.loadOrCreate()
        let profile = makeProfile(server)
        _ = try WireGuardProfileBuilder.build(profile, privateKey: identity.privateKey, fullTunnel: false)
        guard let defaults = UserDefaults(suiteName: AppIdentity.appGroup) else { throw PeerDoorError.tunnelFailed("App Group unavailable") }
        defaults.set(try JSONEncoder().encode(profile), forKey: TunnelProfile.storageKey(server.id))
        let manager = try await loadOrCreateManager(server)
        manager.localizedDescription = "PeerDoor · \(server.displayName)"
        manager.isEnabled = true
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = AppIdentity.tunnelBundleID
        proto.serverAddress = server.lease.endpoint
        proto.providerConfiguration = ["profileID": server.id]
        manager.protocolConfiguration = proto
        if let ssid = profile.homeSSID {
            let home = NEOnDemandRuleDisconnect()
            home.interfaceTypeMatch = .wiFi
            home.ssidMatch = [ssid]
            let away = NEOnDemandRuleConnect()
            away.interfaceTypeMatch = .any
            manager.onDemandRules = [home, away]
            manager.isOnDemandEnabled = userWantsTunnel
        } else {
            // Without a known home SSID, avoid an on-demand reconnect loop after
            // the extension disconnects itself for hairpin protection.
            manager.isOnDemandEnabled = false
            manager.onDemandRules = []
        }
        try await manager.peerdoor_saveToPreferences()
        try await manager.peerdoor_loadFromPreferences()
        // Legacy builds stored a rendered config including the private key here.
        // The new extension reads the identity from the shared Keychain instead.
        defaults.removeObject(forKey: AppIdentity.configKey)
        defaults.removeObject(forKey: AppIdentity.serverNameKey)
        return manager
    }
    private func matches(_ manager: NETunnelProviderManager, server: PairedServer) -> Bool {
        guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
              proto.providerBundleIdentifier == AppIdentity.tunnelBundleID else { return false }
        if let id = proto.providerConfiguration?["profileID"] as? String { return id == server.id }
        return servers.count == 1 || proto.serverAddress == server.lease.endpoint
    }
    private func loadOrCreateManager(_ server: PairedServer) async throws -> NETunnelProviderManager {
        let existing = try await NETunnelProviderManager.peerdoor_loadAllFromPreferences()
        return existing.first(where: { matches($0, server: server) }) ?? NETunnelProviderManager()
    }
    private func reloadManager() async {
        guard let server = selectedServer else { return }
        do { manager = try await loadOrCreateManager(server); refreshStatus() }
        catch { lastError = error.localizedDescription; status = .invalid }
    }
    func disconnect() async { manager?.connection.stopVPNTunnel(); refreshStatus() }
    private func observeVPN() {
        observers.append(NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        })
    }
    private func observePath() {
        pathMonitor.$snapshot.removeDuplicates().sink { [weak self] snapshot in
            Task { @MainActor in
                guard let self else { return }
                await self.applyDesiredState()
            }
        }.store(in: &cancellables)
    }
    private func refreshStatus() {
        switch manager?.connection.status {
        case .connected: status = .connected
        case .connecting, .reasserting: status = .connecting
        case .disconnecting: status = .disconnecting
        case .invalid: status = .invalid
        default: status = .disconnected
        }
    }
}

private extension NETunnelProviderManager {
    func peerdoor_saveToPreferences() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            saveToPreferences { error in if let error { cont.resume(throwing: error) } else { cont.resume() } }
        }
    }
    func peerdoor_loadFromPreferences() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            loadFromPreferences { error in if let error { cont.resume(throwing: error) } else { cont.resume() } }
        }
    }
    func peerdoor_removeFromPreferences() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            removeFromPreferences { error in if let error { cont.resume(throwing: error) } else { cont.resume() } }
        }
    }
    static func peerdoor_loadAllFromPreferences() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation { cont in
            loadAllFromPreferences { managers, error in if let error { cont.resume(throwing: error) } else { cont.resume(returning: managers ?? []) } }
        }
    }
}
