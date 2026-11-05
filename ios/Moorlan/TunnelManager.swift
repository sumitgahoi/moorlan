import Foundation
import UIKit
import NetworkExtension
import MoorlanCore
import Combine

@MainActor
final class TunnelManager: ObservableObject {
    enum Status: Equatable { case disconnected, connecting, connected, disconnecting, invalid }
    /// Home ≠ Trusted ≠ Away. Home always disconnects; Trusted is subnet in Automatic.
    enum NetworkRole: String, CaseIterable { case home, trusted, away }

    @Published private(set) var status: Status = .disconnected
    @Published private(set) var statusReason: String?
    @Published var policy: TunnelPolicy
    @Published private(set) var servers: [PairedServer]
    @Published private(set) var selectedServerID: String?
    @Published var presentedError: UserFacingError?
    @Published private(set) var isUnpairing = false
    /// Formatted live rates while connected, e.g. "↓ 1.2 MB/s  ↑ 84 KB/s".
    @Published private(set) var transferRates: String?
    @Published private(set) var transferRatesAccessibility = ""
    /// Named Wi‑Fi that still needs a Home / Trusted / Away choice.
    @Published var pendingNetworkRoleID: String?

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
    private var intentionalDisconnect = false
    private var statsTask: Task<Void, Never>?
    private var lastRxBytes: UInt64?
    private var lastTxBytes: UInt64?
    private var lastStatsAt: Date?
    /// Default empty so `@Published` init assignments can run before the UserDefaults load.
    private var promptedNetworkIDs: Set<String> = []

    var selectedServer: PairedServer? { servers.first { $0.id == selectedServerID } ?? servers.first }
    var pathKind: TunnelPolicy.PathKind { pathMonitor.snapshot.kind }
    var currentNetworkID: String? {
        guard let id = pathMonitor.snapshot.wifiNetworkID, id.hasPrefix("ssid:") else { return nil }
        return id
    }
    var onHomeWiFi: Bool {
        guard let id = currentNetworkID, let server = selectedServer else { return false }
        return server.homeSSIDs.contains(id)
    }
    /// Wi‑Fi is up but SSID is unknown — must not connect/exit (hairpin risk).
    var wifiIdentityMissing: Bool {
        if case .wifi(let id) = pathKind {
            return !id.hasPrefix("ssid:") || id == "unidentified"
        }
        return false
    }
    var effectiveExit: Bool {
        if case .connect(let full) = policy.decide(path: pathKind, homeSSIDs: selectedServer?.homeSSIDs ?? []) { return full }
        return false
    }
    /// Plain-English hero line for the selected tunnel and path.
    var statusHeadline: String {
        if wifiIdentityMissing { return "Waiting for Wi‑Fi name" }
        if onHomeWiFi { return "Off at home" }
        switch status {
        case .connected:
            return effectiveExit ? "Connected · Full protection" : "Connected · Home access"
        case .connecting: return "Connecting"
        case .disconnecting: return "Disconnecting"
        case .invalid: return "Needs attention"
        case .disconnected:
            if statusReason == "Waiting for a network" { return "Waiting for a network" }
            if statusReason == "Wi‑Fi name unavailable" { return "Waiting for Wi‑Fi name" }
            return "Disconnected"
        }
    }
    var statusDetail: String {
        if wifiIdentityMissing || statusReason == "Wi‑Fi name unavailable" {
            return "Moorlan needs this network’s name before connecting, so it never full-tunnels on home by mistake."
        }
        if onHomeWiFi { return "You’re already on this LAN, so the tunnel stays off." }
        switch status {
        case .connected:
            return effectiveExit
                ? "All traffic goes through home."
                : "Only your home networks are reached through the tunnel."
        case .connecting: return "Reaching your home…"
        case .disconnecting: return "Closing the tunnel…"
        case .invalid:
            return statusReason ?? "Check VPN permission in Settings."
        case .disconnected:
            if statusReason == "Waiting for a network" {
                return "Connect to Wi‑Fi or cellular, then try again."
            }
            if statusReason == "Off at home" {
                return "You’re already on this LAN, so the tunnel stays off."
            }
            return "Tap Connect when you’re away from home."
        }
    }

    init() {
        policy = store.loadPolicy()
        do {
            servers = try store.loadServers()
        } catch {
            servers = []
            // Defer error presentation until after init completes.
            Task { @MainActor in self.present(error) }
        }
        selectedServerID = UserDefaults.standard.string(forKey: "selected-server") ?? servers.first?.id
        promptedNetworkIDs = Set(UserDefaults.standard.stringArray(forKey: Self.promptedNetworksKey) ?? [])
        observePath()
        observeVPN()
        pathMonitor.start()
        Task { await reloadManager(); await applyDesiredState() }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func savePolicy() {
        do {
            try store.savePolicy(policy)
        } catch {
            present(error)
            return
        }
        lastProfile = nil
        Task { await applyDesiredState() }
    }

    func identifyWiFi() { WiFiIdentity.requestAccess(into: pathMonitor) }

    func networkRole(for id: String) -> NetworkRole {
        if selectedServer?.homeSSIDs.contains(id) == true { return .home }
        if policy.trustedNetworkIDs.contains(id) { return .trusted }
        return .away
    }

    /// Home = tunnel off; Trusted = subnet in Automatic; Away = exit in Automatic.
    func setNetworkRole(_ role: NetworkRole, for id: String) {
        guard var server = selectedServer else { return }
        switch role {
        case .home:
            server.homeSSIDs.insert(id)
            policy.trustedNetworkIDs.remove(id)
        case .trusted:
            server.homeSSIDs.remove(id)
            policy.trustedNetworkIDs.insert(id)
            if policy.mode != .automatic { policy.mode = .automatic }
        case .away:
            server.homeSSIDs.remove(id)
            policy.trustedNetworkIDs.remove(id)
        }
        promptedNetworkIDs.insert(id)
        persistPromptedNetworks()
        if pendingNetworkRoleID == id { pendingNetworkRoleID = nil }
        upsertServer(server)
        savePolicy()
    }

    /// Known SSIDs: current network plus saved home/trusted entries.
    var knownNetworkIDs: [String] {
        var ids = Set(selectedServer?.homeSSIDs ?? [])
        ids.formUnion(policy.trustedNetworkIDs)
        if let current = currentNetworkID { ids.insert(current) }
        return ids.sorted {
            displayNetworkName($0).localizedCaseInsensitiveCompare(displayNetworkName($1)) == .orderedAscending
        }
    }

    func displayNetworkName(_ id: String) -> String {
        TunnelPolicy.ssidName(from: id) ?? id
    }

    /// Admin-visible peer name sent at pair time (`moorlan --list-peers`).
    var deviceLabel: String {
        get {
            let stored = UserDefaults.standard.string(forKey: Self.deviceLabelKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !stored.isEmpty { return stored }
            let system = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return system.isEmpty ? "iPhone" : system
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: Self.deviceLabelKey)
            } else {
                UserDefaults.standard.set(trimmed, forKey: Self.deviceLabelKey)
            }
            objectWillChange.send()
        }
    }

    private static let deviceLabelKey = "device-label"
    private static let promptedNetworksKey = "prompted-network-ids"
    private static let rolesCoachKey = "network-roles-coach-seen"

    var shouldShowRolesCoach: Bool {
        !UserDefaults.standard.bool(forKey: Self.rolesCoachKey) && !servers.isEmpty
    }

    func dismissRolesCoach() {
        UserDefaults.standard.set(true, forKey: Self.rolesCoachKey)
        objectWillChange.send()
    }

    func clearPresentedError() { presentedError = nil }

    func present(_ error: UserFacingError) {
        presentedError = error
    }

    func present(_ error: Error) {
        presentedError = UserFacingError.map(error)
    }

    func retryAfterError() async {
        clearPresentedError()
        userWantsTunnel = true
        lastProfile = nil
        await applyDesiredState()
    }

    func pair(card: QRCard) async throws {
        try Task.checkCancellation()
        try await LocalNetworkAuthorization.shared.ensureAccess(to: card.pairURL)
        try Task.checkCancellation()
        let identity = try identityStore.loadOrCreate()
        let lease = try await PairingClient().pair(
            card: card,
            publicKey: identity.publicKey,
            label: deviceLabel
        )
        try Task.checkCancellation()
        var server = PairedServer(card: card, lease: lease)
        // Re-pair of the same host keeps prior Home/Trusted classification for that host.
        if let existing = servers.first(where: { $0.publicKey == server.publicKey }) {
            server.homeSSIDs = existing.homeSSIDs
        }
        if let id = currentNetworkID {
            server.homeSSIDs.insert(id)
            promptedNetworkIDs.insert(id)
            persistPromptedNetworks()
        }
        // Upsert one host; never wipe other paired tunnels.
        try store.upsert(server)
        servers = try store.loadServers()
        await selectProfile(server.id)
        // Install a distinct native profile even on home Wi‑Fi, where starting it is forbidden.
        _ = try await configureProfile(server)
        await applyDesiredState()
    }

    func selectProfile(_ id: String) async {
        guard !isUnpairing, servers.contains(where: { $0.id == id }) else { return }
        if selectedServerID != id {
            intentionalDisconnect = true
            manager?.isOnDemandEnabled = false
            try? await manager?.moorlan_saveToPreferences()
            manager?.connection.stopVPNTunnel()
        }
        selectedServerID = id
        UserDefaults.standard.set(id, forKey: "selected-server")
        lastProfile = nil
        userWantsTunnel = true
        await reloadManager()
    }

    func unpair(scanned card: UnpairCard) async -> Bool {
        guard !isUnpairing, !applying else {
            present(UserFacingError(
                title: "Try again shortly",
                message: "VPN configuration is busy. Wait a moment, then retry.",
                action: .retry
            ))
            return false
        }
        do {
            let server = try card.pairedServer(in: servers)
            if !server.homeSSIDs.isEmpty {
                guard let id = currentNetworkID, server.homeSSIDs.contains(id) else {
                    throw MoorlanError.unpairFailed("Join one of this profile’s home Wi‑Fi networks, then try again")
                }
            }
            isUnpairing = true
            defer { isUnpairing = false }
            guard let identity = try identityStore.load() ?? IdentityStore().load() else { throw MoorlanError.missingIdentity }
            try await LocalNetworkAuthorization.shared.ensureAccess(to: card.unpairURL)
            do {
                try await PairingClient().unpair(server: server, publicKey: identity.publicKey, card: card)
            } catch MoorlanError.unpairAlreadyGone {
                // Server already deleted the peer — still clear local state.
            }
            // After server success (or already-gone), always clear local host even if NE cleanup is partial.
            try await removeLocalHost(server)
            return true
        } catch {
            present(error)
            return false
        }
    }

    /// Clears one host from this iPhone without calling the server. Use after a
    /// confirmed server unpair when local cleanup was interrupted, or when the
    /// user chooses “Remove from this iPhone” and accepts re-pair if needed.
    func forgetLocalHost(_ server: PairedServer) async {
        guard !isUnpairing else { return }
        isUnpairing = true
        defer { isUnpairing = false }
        do {
            try await removeLocalHost(server)
        } catch {
            present(error)
        }
    }

    private func removeLocalHost(_ server: PairedServer) async throws {
        if let installed = try? await NETunnelProviderManager.moorlan_loadAllFromPreferences() {
            for profile in installed where matches(profile, server: server) {
                intentionalDisconnect = true
                profile.connection.stopVPNTunnel()
                try? await profile.moorlan_removeFromPreferences()
            }
        }
        let defaults = UserDefaults(suiteName: AppIdentity.appGroup)
        defaults?.removeObject(forKey: TunnelProfile.storageKey(server.id))
        defaults?.removeObject(forKey: "home-ssid-" + server.id)
        if selectedServer?.id == server.id {
            manager = nil
            defaults?.removeObject(forKey: AppIdentity.configKey)
            defaults?.removeObject(forKey: AppIdentity.serverNameKey)
            selectedServerID = servers.first(where: { $0.id != server.id })?.id
            lastProfile = nil
            userWantsTunnel = false
            status = .disconnected
            statusReason = "Profile deleted"
        }
        // Remove one host only; Keychain identity and other tunnels stay.
        servers.removeAll { $0.id == server.id }
        try store.saveServers(servers)
        UserDefaults.standard.set(selectedServerID, forKey: "selected-server")
    }

    func toggleDesiredConnection() async {
        if status == .connected || status == .connecting {
            userWantsTunnel = false
            intentionalDisconnect = true
            manager?.isOnDemandEnabled = false
            try? await manager?.moorlan_saveToPreferences()
            await disconnect()
        } else {
            userWantsTunnel = true
            clearPresentedError()
            lastProfile = nil
            await applyDesiredState()
        }
    }

    func applyDesiredState() async {
        guard !isUnpairing else { return }
        if applying { needsApply = true; return }
        applying = true
        defer { applying = false }
        repeat {
            needsApply = false
            await applyOnce()
        } while needsApply && !isUnpairing
    }
    private func applyOnce() async {
        guard let server = selectedServer else { await disconnect(); return }
        guard !pathMonitor.snapshot.saturated else { statusReason = "Waiting for a network"; return }
        let decision = policy.decide(path: pathKind, homeSSIDs: server.homeSSIDs)
        do {
            let profile = makeProfile(server)
            let changed = profile != lastProfile
            if changed || manager == nil {
                manager = try await configureProfile(server)
                lastProfile = profile
            }
            switch decision {
            case .disconnect(let reason):
                if reason == "Wi‑Fi name unavailable", statusReason != reason {
                    present(MoorlanError.wifiNameUnavailable)
                }
                statusReason = reason
                intentionalDisconnect = true
                await disconnect()
            case .connect:
                statusReason = nil
                if presentedError?.title == UserFacingError.map(.wifiNameUnavailable).title {
                    clearPresentedError()
                }
                guard userWantsTunnel, let manager else {
                    refreshStatus()
                    return
                }
                if manager.connection.status == .connected {
                    if changed, let session = manager.connection as? NETunnelProviderSession {
                        try session.sendProviderMessage(Data("reload-policy".utf8)) { _ in }
                    }
                } else if manager.connection.status != .connecting
                            && manager.connection.status != .disconnecting
                            && manager.connection.status != .reasserting {
                    do {
                        try manager.connection.startVPNTunnel()
                    } catch {
                        present(mapStartFailure(error))
                        status = .invalid
                        return
                    }
                }
                refreshStatus()
            }
        } catch {
            present(mapConfigurationFailure(error))
            status = .invalid
        }
    }

    private func makeProfile(_ server: PairedServer) -> TunnelProfile {
        TunnelProfile(server: server, policy: policy)
    }
    private func configureProfile(_ server: PairedServer) async throws -> NETunnelProviderManager {
        let identity = try identityStore.loadOrCreate()
        let profile = makeProfile(server)
        _ = try WireGuardProfileBuilder.build(profile, privateKey: identity.privateKey, fullTunnel: false)
        guard let defaults = UserDefaults(suiteName: AppIdentity.appGroup) else {
            throw MoorlanError.tunnelFailed("App Group unavailable")
        }
        // Extension profile: no private key, no unpair_token (stripped in TunnelProfile.init).
        defaults.set(try JSONEncoder().encode(profile), forKey: TunnelProfile.storageKey(server.id))
        let manager = try await loadOrCreateManager(server)
        manager.localizedDescription = "Moorlan · \(server.displayName)"
        manager.isEnabled = true
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = AppIdentity.tunnelBundleID
        proto.serverAddress = server.lease.endpoint
        proto.providerConfiguration = ["profileID": server.id]
        manager.protocolConfiguration = proto
        let homeNames = server.homeSSIDs.compactMap(TunnelPolicy.ssidName(from:)).sorted()
        if !homeNames.isEmpty {
            let home = NEOnDemandRuleDisconnect()
            home.interfaceTypeMatch = .wiFi
            home.ssidMatch = homeNames
            let away = NEOnDemandRuleConnect()
            away.interfaceTypeMatch = .any
            manager.onDemandRules = [home, away]
            manager.isOnDemandEnabled = userWantsTunnel
        } else {
            // Without home SSIDs, avoid an on-demand reconnect loop after a self-stop at home.
            manager.isOnDemandEnabled = false
            manager.onDemandRules = []
        }
        try await manager.moorlan_saveToPreferences()
        try await manager.moorlan_loadFromPreferences()
        // Legacy builds stored a rendered config including the private key here.
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
        let existing = try await NETunnelProviderManager.moorlan_loadAllFromPreferences()
        return existing.first(where: { matches($0, server: server) }) ?? NETunnelProviderManager()
    }
    private func reloadManager() async {
        guard let server = selectedServer else { return }
        do { manager = try await loadOrCreateManager(server); refreshStatus() }
        catch {
            present(mapConfigurationFailure(error))
            status = .invalid
        }
    }
    private func upsertServer(_ server: PairedServer) {
        do {
            try store.upsert(server)
            servers = try store.loadServers()
        } catch {
            present(error)
        }
    }
    func disconnect() async {
        manager?.connection.stopVPNTunnel()
        refreshStatus()
    }

    private func observeVPN() {
        observers.append(NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        })
    }
    private func observePath() {
        pathMonitor.$snapshot.removeDuplicates().sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.considerNetworkRolePrompt()
                await self.applyDesiredState()
            }
        }.store(in: &cancellables)
    }
    private func refreshStatus() {
        let previous = status
        let wasIntentional = intentionalDisconnect
        switch manager?.connection.status {
        case .connected: status = .connected
        case .connecting, .reasserting: status = .connecting
        case .disconnecting: status = .disconnecting
        case .invalid: status = .invalid
        default: status = .disconnected
        }
        // Unexpected drop: generic stop — do not assume another VPN (false positives).
        if previous == .connected
            && status == .disconnected
            && userWantsTunnel
            && !wasIntentional
            && !onHomeWiFi
            && !wifiIdentityMissing
            && selectedServer != nil {
            present(MoorlanError.tunnelStopped)
        }
        // Keep the intentional flag through .disconnecting so a follow-up
        // .disconnected notification is not treated as unexpected.
        if status == .connected || status == .disconnected || status == .invalid {
            intentionalDisconnect = false
        }
        updateStatsPolling()
    }

    private func considerNetworkRolePrompt() {
        guard let id = currentNetworkID, selectedServer != nil else { return }
        if networkRole(for: id) != .away { return }
        if promptedNetworkIDs.contains(id) { return }
        pendingNetworkRoleID = id
    }

    private func persistPromptedNetworks() {
        UserDefaults.standard.set(Array(promptedNetworkIDs), forKey: Self.promptedNetworksKey)
    }

    private func mapStartFailure(_ error: Error) -> Error {
        let ns = error as NSError
        if ns.domain == NEVPNErrorDomain {
            switch NEVPNError.Code(rawValue: ns.code) {
            case .configurationDisabled, .configurationInvalid, .configurationStale:
                return MoorlanError.vpnConfigurationFailed
            default:
                break
            }
        }
        return MoorlanError.tunnelStopped
    }

    private func mapConfigurationFailure(_ error: Error) -> Error {
        if error is MoorlanError { return error }
        let ns = error as NSError
        if ns.domain == NEVPNErrorDomain {
            return MoorlanError.vpnConfigurationFailed
        }
        return error
    }

    private func updateStatsPolling() {
        if status == .connected {
            guard statsTask == nil else { return }
            statsTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refreshTransferRates()
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        } else {
            statsTask?.cancel()
            statsTask = nil
            transferRates = nil
            transferRatesAccessibility = ""
            lastRxBytes = nil
            lastTxBytes = nil
            lastStatsAt = nil
        }
    }

    private func refreshTransferRates() async {
        guard status == .connected,
              let session = manager?.connection as? NETunnelProviderSession else { return }
        let uapi: String? = await withCheckedContinuation { cont in
            do {
                try session.sendProviderMessage(Data([0])) { data in
                    cont.resume(returning: data.flatMap { String(data: $0, encoding: .utf8) })
                }
            } catch {
                cont.resume(returning: nil)
            }
        }
        guard let uapi else { return }
        let (rx, tx) = Self.parseTransferBytes(uapi)
        let now = Date()
        defer {
            lastRxBytes = rx
            lastTxBytes = tx
            lastStatsAt = now
        }
        guard let previousRx = lastRxBytes, let previousTx = lastTxBytes, let previousAt = lastStatsAt else { return }
        let dt = now.timeIntervalSince(previousAt)
        guard dt > 0.2 else { return }
        let down = Double(rx &- previousRx) / dt
        let up = Double(tx &- previousTx) / dt
        transferRates = "↓ \(Self.formatRate(down))  ↑ \(Self.formatRate(up))"
        transferRatesAccessibility = "Download \(Self.formatRate(down)), upload \(Self.formatRate(up))"
    }

    private static func parseTransferBytes(_ uapi: String) -> (UInt64, UInt64) {
        var rx: UInt64 = 0
        var tx: UInt64 = 0
        for line in uapi.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("rx_bytes="), let value = UInt64(line.dropFirst("rx_bytes=".count)) {
                rx += value
            } else if line.hasPrefix("tx_bytes="), let value = UInt64(line.dropFirst("tx_bytes=".count)) {
                tx += value
            }
        }
        return (rx, tx)
    }

    private static func formatRate(_ bytesPerSecond: Double) -> String {
        let abs = max(0, bytesPerSecond)
        if abs < 1000 { return String(format: "%.0f B/s", abs) }
        if abs < 1000 * 1000 { return String(format: "%.1f KB/s", abs / 1000) }
        return String(format: "%.2f MB/s", abs / 1_000_000)
    }
}

private extension NETunnelProviderManager {
    func moorlan_saveToPreferences() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            saveToPreferences { error in if let error { cont.resume(throwing: error) } else { cont.resume() } }
        }
    }
    func moorlan_loadFromPreferences() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            loadFromPreferences { error in if let error { cont.resume(throwing: error) } else { cont.resume() } }
        }
    }
    func moorlan_removeFromPreferences() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            removeFromPreferences { error in if let error { cont.resume(throwing: error) } else { cont.resume() } }
        }
    }
    static func moorlan_loadAllFromPreferences() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation { cont in
            loadAllFromPreferences { managers, error in if let error { cont.resume(throwing: error) } else { cont.resume(returning: managers ?? []) } }
        }
    }
}
