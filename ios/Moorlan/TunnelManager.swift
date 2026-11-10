import Foundation
import UIKit
import NetworkExtension
import MoorlanCore
import Combine

@MainActor
final class TunnelManager: ObservableObject {
    enum Status: Equatable { case disconnected, connecting, connected, disconnecting, invalid }

    private static let cellularPathID = "cellular"
    private static let onDemandActiveKey = "on-demand-active-server"
    private static let deviceLabelKey = "device-label"
    private static let selectedServerKey = "selected-server"

    @Published private(set) var status: Status = .disconnected
    @Published private(set) var statusReason: String?
    @Published var policy: TunnelPolicy
    @Published private(set) var servers: [PairedServer]
    @Published private(set) var selectedServerID: String?
    /// Tunnel that owns iOS on-demand auto-connect (at most one).
    @Published private(set) var onDemandActiveID: String?
    @Published var presentedError: UserFacingError?
    @Published private(set) var isUnpairing = false
    @Published private(set) var transferRates: String?
    @Published private(set) var transferRatesAccessibility = ""

    private let store = ServerStore()
    private let identityStore = IdentityStore(accessGroup: AppIdentity.keychainAccessGroup)
    private let pathMonitor = NetworkPathMonitor()
    private var manager: NETunnelProviderManager?
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    private var mutating = false
    private var userWantsTunnel = true
    private var intentionalDisconnect = false
    private var statsTask: Task<Void, Never>?
    private var lastRxBytes: UInt64?
    private var lastTxBytes: UInt64?
    private var lastStatsAt: Date?
    private var networkExtensionConnected = false
    private var hasLiveHandshake = false
    private var handshakeWaitStartedAt: Date?
    private var handshakeFailTask: Task<Void, Never>?

    private static let handshakeFreshSeconds: TimeInterval = 180
    private static let handshakeTimeoutSeconds: TimeInterval = 25

    var selectedServer: PairedServer? { servers.first { $0.id == selectedServerID } ?? servers.first }
    var pathKind: TunnelPolicy.PathKind { pathMonitor.snapshot.kind }
    /// False while path identity is settling; UI treats unsettled as Full.
    var isPathStable: Bool { pathMonitor.snapshot.isStable }
    var currentNetworkID: String? {
        guard let id = pathMonitor.snapshot.wifiNetworkID, id.hasPrefix("ssid:") else { return nil }
        return id
    }

    /// Path key for durable routing (SSID id or cellular).
    var currentPathID: String? {
        switch pathKind {
        case .wifi(let id) where PathIdentity.isKnownSSID(id):
            return id
        case .cellular:
            return Self.cellularPathID
        default:
            return nil
        }
    }

    /// Durable routing for the current path. Unsettled path → Full for display.
    var effectiveRouting: NetworkRouting? {
        if !isPathStable { return .full }
        guard let pathID = currentPathID else { return nil }
        if pathID == Self.cellularPathID {
            return policy.cellularRouting
        }
        return policy.routing(forNetworkID: pathID)
    }

    var isOffOnCurrentPath: Bool {
        guard isPathStable else { return false }
        return effectiveRouting == .off
    }

    var effectiveFullTunnel: Bool {
        if case .connect(let full) = displayedDecision() { return full }
        return false
    }

    var statusHeadline: String {
        if isOffOnCurrentPath { return "Off on this network" }
        switch status {
        case .connected:
            return effectiveFullTunnel ? "Connected · Full" : "Connected · Split"
        case .connecting:
            if !isPathStable {
                return "Connected · Full"
            }
            return "Connecting…"
        case .disconnecting: return "Disconnecting…"
        case .invalid: return "Needs attention"
        case .disconnected:
            if statusReason == "Waiting for a network" { return "Waiting for a network" }
            return "Disconnected"
        }
    }

    var statusDetail: String {
        if isOffOnCurrentPath {
            return "Tunnel stays off here. Change Off / Split / Full on this network to connect."
        }
        switch status {
        case .connected:
            return effectiveFullTunnel
                ? "All traffic goes through the tunnel."
                : "Only this tunnel’s private networks are reached through the tunnel."
        case .connecting:
            if !isPathStable {
                return "Switching networks…"
            }
            return networkExtensionConnected
                ? "Tunnel is up; waiting for a handshake with the host…"
                : "Reaching the host…"
        case .disconnecting: return "Closing the tunnel…"
        case .invalid:
            return statusReason ?? "Check VPN permission in Settings."
        case .disconnected:
            if statusReason == "Waiting for a network" {
                return "Connect to Wi‑Fi or cellular, then try again."
            }
            return statusReason ?? "Choose Split or Full to connect."
        }
    }

    init() {
        policy = store.loadPolicy()
        do {
            servers = try store.loadServers()
        } catch {
            servers = []
            Task { @MainActor in self.present(error) }
        }
        do {
            _ = try store.migrateLegacyHomeSSIDs(policy: &policy, servers: &servers)
        } catch {
            Task { @MainActor in self.present(error) }
        }
        selectedServerID = UserDefaults.standard.string(forKey: Self.selectedServerKey) ?? servers.first?.id
        onDemandActiveID = UserDefaults.standard.string(forKey: Self.onDemandActiveKey)
        if let active = onDemandActiveID, !servers.contains(where: { $0.id == active }) {
            onDemandActiveID = nil
            UserDefaults.standard.removeObject(forKey: Self.onDemandActiveKey)
        }
        if onDemandActiveID == nil, servers.count == 1, let only = servers.first {
            onDemandActiveID = only.id
            UserDefaults.standard.set(only.id, forKey: Self.onDemandActiveKey)
        }
        observePath()
        observeVPN()
        pathMonitor.start()
        // Observe only: attach to existing system VPN. Do not rewrite prefs or bounce the tunnel.
        Task { await attachToSystemVPN() }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// Load system VPN managers and refresh status without saving preferences.
    func attachToSystemVPN() async {
        await reloadManager()
    }

    func identifyWiFi() { WiFiIdentity.requestAccess(into: pathMonitor) }

    /// Durable routing for a Wi‑Fi id.
    func routing(forNetworkID id: String) -> NetworkRouting {
        policy.routing(forNetworkID: id)
    }

    /// Tunnel-list: set Off/Split/Full for the **current** path. Persists and applies once.
    func setRouting(_ routing: NetworkRouting) {
        guard let pathID = currentPathID, isPathStable else { return }
        let previousOff = policy.offNetworkIDs
        if pathID == Self.cellularPathID {
            guard policy.cellularRouting != routing else { return }
            policy.cellularRouting = routing
        } else {
            guard pathID.hasPrefix("ssid:") else { return }
            guard policy.routing(forNetworkID: pathID) != routing else { return }
            policy.networkRouting[pathID] = routing
        }
        do {
            try store.savePolicy(policy)
        } catch {
            present(error)
            return
        }
        userWantsTunnel = routing != .off
        let offChanged = previousOff != policy.offNetworkIDs
        Task {
            await applyUserRoutingChange(offSetChanged: offChanged)
        }
    }

    /// Rename a paired host (display name only). Does not change selection or tunnel state.
    func renameServer(_ id: String, displayName: String) {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = servers.firstIndex(where: { $0.id == id }) else { return }
        var server = servers[index]
        server.card.legacyName = trimmed
        do {
            try store.upsert(server)
            servers = try store.loadServers()
            Task { await refreshProfileDescription(for: server) }
        } catch {
            present(error)
        }
    }

    func displayNetworkName(_ id: String) -> String {
        TunnelPolicy.ssidName(from: id) ?? id
    }

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

    func clearPresentedError() { presentedError = nil }

    func present(_ error: UserFacingError) {
        presentedError = error
    }

    func present(_ error: Error) {
        presentedError = UserFacingError.map(error)
    }

    func retryAfterError() async {
        clearPresentedError()
        userWantsTunnel = effectiveRouting != .off
        await applyUserRoutingChange(offSetChanged: false)
    }

    /// Pair. Marks current Wi‑Fi Off. First/only tunnel becomes on-demand default.
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
        let server = PairedServer(card: card, lease: lease)
        let hadOtherTunnels = servers.contains { $0.publicKey != server.publicKey }
        let previousOff = policy.offNetworkIDs
        if let id = currentNetworkID {
            policy.networkRouting[id] = .off
            try store.savePolicy(policy)
        }
        try store.upsert(server)
        servers = try store.loadServers()
        await selectProfile(server.id)
        _ = try await configureProfile(server, enableOnDemand: false)
        writeAppGroupProfiles()
        if !hadOtherTunnels {
            await setOnDemandActive(server.id)
        }
        let offChanged = previousOff != policy.offNetworkIDs
        await applyUserRoutingChange(offSetChanged: offChanged)
    }

    /// Make this tunnel the sole on-demand-active profile.
    func setOnDemandActive(_ id: String) async {
        guard servers.contains(where: { $0.id == id }) else { return }
        guard onDemandActiveID != id else { return }
        onDemandActiveID = id
        UserDefaults.standard.set(id, forKey: Self.onDemandActiveKey)
        let offNames = policy.offSSIDNames
        do {
            let installed = try await NETunnelProviderManager.moorlan_loadAllFromPreferences()
            for profile in installed {
                guard let profileID = moorlanProfileID(profile) else { continue }
                if profileID == id {
                    applyOnDemandRules(to: profile, offSSIDNames: offNames, enabled: !offNames.isEmpty)
                    if selectedServerID == id {
                        manager = profile
                    }
                } else {
                    profile.isOnDemandEnabled = false
                    profile.onDemandRules = []
                    if profile.connection.status != .disconnected && profile.connection.status != .invalid {
                        intentionalDisconnect = true
                        profile.connection.stopVPNTunnel()
                    }
                }
                try? await profile.moorlan_saveToPreferences()
            }
            if selectedServerID == id {
                try? await manager?.moorlan_loadFromPreferences()
            }
        } catch {
            present(mapConfigurationFailure(error))
        }
    }

    func selectProfile(_ id: String) async {
        guard !isUnpairing, servers.contains(where: { $0.id == id }) else { return }
        if selectedServerID != id {
            intentionalDisconnect = true
            // Do not clear on-demand on the previous default — only setOnDemandActive does that.
            if onDemandActiveID != selectedServerID {
                manager?.isOnDemandEnabled = false
                try? await manager?.moorlan_saveToPreferences()
            }
            manager?.connection.stopVPNTunnel()
        }
        selectedServerID = id
        UserDefaults.standard.set(id, forKey: Self.selectedServerKey)
        userWantsTunnel = effectiveRouting != .off
        await reloadManager()
    }

    func unpair(scanned card: UnpairCard) async -> Bool {
        guard !isUnpairing, !mutating else {
            present(UserFacingError(
                title: "Try again shortly",
                message: "VPN configuration is busy. Wait a moment, then retry.",
                action: .retry
            ))
            return false
        }
        do {
            let server = try card.pairedServer(in: servers)
            let offIDs = policy.offNetworkIDs
            if !offIDs.isEmpty {
                guard let id = currentNetworkID, offIDs.contains(id) else {
                    throw MoorlanError.unpairFailed("Join a Wi‑Fi marked Off for this tunnel, then try again")
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
            try await removeLocalHost(server)
            return true
        } catch {
            present(error)
            return false
        }
    }

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
        let wasActive = onDemandActiveID == server.id
        if onDemandActiveID == server.id {
            onDemandActiveID = nil
            UserDefaults.standard.removeObject(forKey: Self.onDemandActiveKey)
        }
        if selectedServer?.id == server.id {
            manager = nil
            defaults?.removeObject(forKey: AppIdentity.configKey)
            defaults?.removeObject(forKey: AppIdentity.serverNameKey)
            selectedServerID = servers.first(where: { $0.id != server.id })?.id
            userWantsTunnel = false
            status = .disconnected
            statusReason = "Profile deleted"
        }
        servers.removeAll { $0.id == server.id }
        try store.saveServers(servers)
        UserDefaults.standard.set(selectedServerID, forKey: Self.selectedServerKey)
        if wasActive {
            if servers.count == 1, let only = servers.first {
                await setOnDemandActive(only.id)
            } else {
                await disableOnDemandOnAllManagers()
            }
        }
        await reloadManager()
    }

    /// Persist App Group profiles and apply the durable decision for the current path (user-initiated).
    private func applyUserRoutingChange(offSetChanged: Bool) async {
        guard !isUnpairing else { return }
        if mutating { return }
        mutating = true
        defer { mutating = false }

        writeAppGroupProfiles()

        if offSetChanged, let activeID = onDemandActiveID {
            await syncOnDemandRules(for: activeID)
        }

        guard let server = selectedServer else {
            await disconnect()
            return
        }
        guard !pathMonitor.snapshot.saturated else {
            statusReason = "Waiting for a network"
            return
        }

        let needsConfigure: Bool = {
            guard let manager else { return true }
            return moorlanProfileID(manager) != server.id
        }()
        if needsConfigure {
            do {
                manager = try await configureProfile(
                    server,
                    enableOnDemand: onDemandActiveID == server.id
                )
            } catch {
                present(mapConfigurationFailure(error))
                status = .invalid
                return
            }
        }

        let decision: TunnelPolicy.Decision = pathMonitor.snapshot.isStable
            ? policy.decide(path: pathKind)
            : .connect(fullTunnel: true)
        await reconcileVPN(to: decision, reloadTunnel: true)
    }

    private func displayedDecision() -> TunnelPolicy.Decision {
        if !isPathStable {
            return .connect(fullTunnel: true)
        }
        return policy.decide(path: pathKind)
    }

    private func reconcileVPN(to decision: TunnelPolicy.Decision, reloadTunnel: Bool) async {
        switch decision {
        case .disconnect(let reason):
            statusReason = reason
            intentionalDisconnect = true
            userWantsTunnel = false
            await disconnect()
        case .connect:
            statusReason = nil
            userWantsTunnel = true
            if presentedError?.title == UserFacingError.map(.wifiNameUnavailable).title {
                clearPresentedError()
            }
            guard let manager else {
                refreshStatus()
                return
            }
            if manager.connection.status == .connected {
                if reloadTunnel, let session = manager.connection as? NETunnelProviderSession {
                    try? session.sendProviderMessage(Data("reload-policy".utf8)) { _ in }
                }
            } else if manager.connection.status != .connecting
                        && manager.connection.status != .disconnecting
                        && manager.connection.status != .reasserting {
                do {
                    // Same recovery as wireguard-apple TunnelContainer.startActivation.
                    try await startActivation()
                } catch {
                    present(mapStartFailure(error))
                    status = .invalid
                    return
                }
            }
            refreshStatus()
        }
    }

    /// Mirrors wireguard-apple `TunnelContainer.startActivation` (see
    /// ARCHITECTURE.md “NetworkExtension reference implementations”):
    /// if disabled (common after another VPN took the slot), re-enable + save and
    /// recurse; on `configurationInvalid` / `configurationStale`, reload and recurse.
    /// Caps at 8 attempts. Prefer WireGuard/Tailscale patterns over new recovery.
    private func startActivation(recursionCount: UInt = 0) async throws {
        if recursionCount >= 8 {
            throw MoorlanError.vpnConfigurationFailed
        }
        guard let manager else {
            throw MoorlanError.tunnelFailed("No VPN profile loaded")
        }
        if !manager.isEnabled {
            manager.isEnabled = true
            try await manager.moorlan_saveToPreferences()
            try await startActivation(recursionCount: recursionCount + 1)
            return
        }
        do {
            try manager.connection.startVPNTunnel()
        } catch {
            let ns = error as NSError
            guard ns.domain == NEVPNErrorDomain,
                  let code = NEVPNError.Code(rawValue: ns.code),
                  code == .configurationInvalid || code == .configurationStale else {
                throw error
            }
            try await manager.moorlan_loadFromPreferences()
            try await startActivation(recursionCount: recursionCount + 1)
        }
    }

    private func makeProfile(_ server: PairedServer) -> TunnelProfile {
        TunnelProfile(server: server, policy: policy)
    }

    private func writeAppGroupProfiles() {
        guard let defaults = UserDefaults(suiteName: AppIdentity.appGroup) else { return }
        let encoder = JSONEncoder()
        for server in servers {
            if let data = try? encoder.encode(makeProfile(server)) {
                defaults.set(data, forKey: TunnelProfile.storageKey(server.id))
            }
        }
        defaults.removeObject(forKey: AppIdentity.configKey)
        defaults.removeObject(forKey: AppIdentity.serverNameKey)
    }

    private func syncOnDemandRules(for id: String) async {
        let offNames = policy.offSSIDNames
        guard let installed = try? await NETunnelProviderManager.moorlan_loadAllFromPreferences() else { return }
        for profile in installed {
            guard moorlanProfileID(profile) == id else { continue }
            applyOnDemandRules(to: profile, offSSIDNames: offNames, enabled: !offNames.isEmpty)
            try? await profile.moorlan_saveToPreferences()
            if selectedServerID == id {
                manager = profile
                try? await manager?.moorlan_loadFromPreferences()
            }
            return
        }
    }

    private func refreshProfileDescription(for server: PairedServer) async {
        do {
            let installed = try await NETunnelProviderManager.moorlan_loadAllFromPreferences()
            guard let profile = installed.first(where: { moorlanProfileID($0) == server.id }) else { return }
            let next = "Moorlan · \(server.displayName)"
            guard profile.localizedDescription != next else { return }
            profile.localizedDescription = next
            try await profile.moorlan_saveToPreferences()
            if selectedServerID == server.id {
                manager = profile
            }
        } catch {
            // Display name in-app already updated; VPN Settings label can catch up next configure.
        }
    }

    private func configureProfile(_ server: PairedServer, enableOnDemand: Bool) async throws -> NETunnelProviderManager {
        let identity = try identityStore.loadOrCreate()
        let profile = makeProfile(server)
        _ = try WireGuardProfileBuilder.build(profile, privateKey: identity.privateKey, fullTunnel: false)
        guard let defaults = UserDefaults(suiteName: AppIdentity.appGroup) else {
            throw MoorlanError.tunnelFailed("App Group unavailable")
        }
        defaults.set(try JSONEncoder().encode(profile), forKey: TunnelProfile.storageKey(server.id))
        let manager = try await loadOrCreateManager(server)
        manager.localizedDescription = "Moorlan · \(server.displayName)"
        manager.isEnabled = true
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = AppIdentity.tunnelBundleID
        proto.serverAddress = server.lease.endpoint
        proto.providerConfiguration = ["profileID": server.id]
        manager.protocolConfiguration = proto
        let offNames = policy.offSSIDNames
        if enableOnDemand, !offNames.isEmpty {
            applyOnDemandRules(to: manager, offSSIDNames: offNames, enabled: true)
        } else if onDemandActiveID == server.id {
            // Active default but no Off SSIDs yet — avoid reconnect loops.
            manager.isOnDemandEnabled = false
            manager.onDemandRules = []
        } else {
            manager.isOnDemandEnabled = false
            manager.onDemandRules = []
        }
        try await manager.moorlan_saveToPreferences()
        try await manager.moorlan_loadFromPreferences()
        defaults.removeObject(forKey: AppIdentity.configKey)
        defaults.removeObject(forKey: AppIdentity.serverNameKey)
        return manager
    }

    private func applyOnDemandRules(to manager: NETunnelProviderManager, offSSIDNames: [String], enabled: Bool) {
        guard enabled, !offSSIDNames.isEmpty else {
            manager.isOnDemandEnabled = false
            manager.onDemandRules = []
            return
        }
        let off = NEOnDemandRuleDisconnect()
        off.interfaceTypeMatch = .wiFi
        off.ssidMatch = offSSIDNames
        let away = NEOnDemandRuleConnect()
        away.interfaceTypeMatch = .any
        manager.onDemandRules = [off, away]
        manager.isOnDemandEnabled = true
    }

    private func disableOnDemandOnAllManagers() async {
        guard let installed = try? await NETunnelProviderManager.moorlan_loadAllFromPreferences() else { return }
        for profile in installed {
            guard moorlanProfileID(profile) != nil else { continue }
            profile.isOnDemandEnabled = false
            profile.onDemandRules = []
            try? await profile.moorlan_saveToPreferences()
        }
    }

    private func moorlanProfileID(_ manager: NETunnelProviderManager) -> String? {
        guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
              proto.providerBundleIdentifier == AppIdentity.tunnelBundleID else { return nil }
        return proto.providerConfiguration?["profileID"] as? String
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
        do {
            let existing = try await NETunnelProviderManager.moorlan_loadAllFromPreferences()
            manager = existing.first(where: { matches($0, server: server) })
            refreshStatus()
        } catch {
            present(mapConfigurationFailure(error))
            status = .invalid
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
            // UI only — Packet Tunnel applies durable policy while suspended / away.
            self?.objectWillChange.send()
        }.store(in: &cancellables)
    }

    private func refreshStatus() {
        let previous = status
        let wasIntentional = intentionalDisconnect
        switch manager?.connection.status {
        case .connected:
            networkExtensionConnected = true
            status = hasLiveHandshake ? .connected : .connecting
            if hasLiveHandshake {
                clearHandshakeWait()
            } else {
                beginHandshakeWaitIfNeeded()
            }
        case .connecting, .reasserting:
            networkExtensionConnected = false
            hasLiveHandshake = false
            clearHandshakeWait()
            status = .connecting
        case .disconnecting:
            networkExtensionConnected = false
            hasLiveHandshake = false
            clearHandshakeWait()
            status = .disconnecting
        case .invalid:
            networkExtensionConnected = false
            hasLiveHandshake = false
            clearHandshakeWait()
            status = .invalid
        default:
            networkExtensionConnected = false
            hasLiveHandshake = false
            clearHandshakeWait()
            status = .disconnected
        }
        if previous == .connected
            && status == .disconnected
            && userWantsTunnel
            && !wasIntentional
            && !isOffOnCurrentPath
            && isPathStable
            && selectedServer != nil {
            present(MoorlanError.tunnelStopped)
        }
        if status == .connected || status == .disconnected || status == .invalid {
            intentionalDisconnect = false
        }
        updateStatsPolling()
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
        if networkExtensionConnected {
            guard statsTask == nil else { return }
            statsTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refreshTunnelRuntime()
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

    private func refreshTunnelRuntime() async {
        guard networkExtensionConnected,
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

        let live = Self.hasLiveHandshake(in: uapi, now: Date(), freshFor: Self.handshakeFreshSeconds)
        if live != hasLiveHandshake {
            hasLiveHandshake = live
            if networkExtensionConnected {
                status = live ? .connected : .connecting
                if live {
                    clearHandshakeWait()
                } else {
                    beginHandshakeWaitIfNeeded()
                    transferRates = nil
                    transferRatesAccessibility = ""
                    lastRxBytes = nil
                    lastTxBytes = nil
                    lastStatsAt = nil
                }
            }
        } else if networkExtensionConnected, !live {
            beginHandshakeWaitIfNeeded()
        }
        guard live else { return }

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

    private func beginHandshakeWaitIfNeeded() {
        guard networkExtensionConnected, !hasLiveHandshake else { return }
        if handshakeWaitStartedAt == nil {
            handshakeWaitStartedAt = Date()
        }
        guard handshakeFailTask == nil else { return }
        handshakeFailTask = Task { [weak self] in
            let nanos = UInt64(Self.handshakeTimeoutSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            await self?.failHandshakeIfStillWaiting()
        }
    }

    private func clearHandshakeWait() {
        handshakeWaitStartedAt = nil
        handshakeFailTask?.cancel()
        handshakeFailTask = nil
    }

    private func failHandshakeIfStillWaiting() async {
        guard !Task.isCancelled else { return }
        guard networkExtensionConnected, !hasLiveHandshake, userWantsTunnel else {
            clearHandshakeWait()
            return
        }
        clearHandshakeWait()
        intentionalDisconnect = true
        userWantsTunnel = false
        present(MoorlanError.handshakeFailed)
        if onDemandActiveID != selectedServerID {
            manager?.isOnDemandEnabled = false
            try? await manager?.moorlan_saveToPreferences()
        }
        manager?.connection.stopVPNTunnel()
        refreshStatus()
    }

    private static func hasLiveHandshake(in uapi: String, now: Date, freshFor: TimeInterval) -> Bool {
        guard let handshake = parseLastHandshake(uapi) else { return false }
        return now.timeIntervalSince(handshake) <= freshFor
    }

    private static func parseLastHandshake(_ uapi: String) -> Date? {
        var latest: TimeInterval = 0
        for line in uapi.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("last_handshake_time_sec=") else { continue }
            guard let sec = TimeInterval(line.dropFirst("last_handshake_time_sec=".count)), sec > 0 else { continue }
            latest = max(latest, sec)
        }
        return latest > 0 ? Date(timeIntervalSince1970: latest) : nil
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
