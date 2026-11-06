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
    /// After pair when another tunnel already exists — UI asks “Use as default?”
    @Published var pendingDefaultPromptServerID: String?
    @Published var presentedError: UserFacingError?
    @Published private(set) var isUnpairing = false
    @Published private(set) var transferRates: String?
    @Published private(set) var transferRatesAccessibility = ""

    /// Home-only temporary Off/Split/Full for the current path. Cleared on path change.
    @Published private(set) var temporaryRouting: (pathID: String, value: NetworkRouting)?

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
    private var networkExtensionConnected = false
    private var hasLiveHandshake = false
    private var handshakeWaitStartedAt: Date?
    private var handshakeFailTask: Task<Void, Never>?
    private var lastTemporaryPathID: String?

    private static let handshakeFreshSeconds: TimeInterval = 180
    private static let handshakeTimeoutSeconds: TimeInterval = 25

    var selectedServer: PairedServer? { servers.first { $0.id == selectedServerID } ?? servers.first }
    var pathKind: TunnelPolicy.PathKind { pathMonitor.snapshot.kind }
    var currentNetworkID: String? {
        guard let id = pathMonitor.snapshot.wifiNetworkID, id.hasPrefix("ssid:") else { return nil }
        return id
    }

    /// Path key for temporary routing (SSID id or cellular).
    var currentPathID: String? {
        switch pathKind {
        case .wifi(let id) where id.hasPrefix("ssid:") && id != "unidentified":
            return id
        case .cellular:
            return Self.cellularPathID
        default:
            return nil
        }
    }

    var wifiIdentityMissing: Bool {
        if case .wifi(let id) = pathKind {
            return !id.hasPrefix("ssid:") || id == "unidentified"
        }
        return false
    }

    /// Effective routing for the current path (temporary ?? permanent).
    var effectiveRouting: NetworkRouting? {
        guard let pathID = currentPathID else { return nil }
        if let temp = temporaryRouting, temp.pathID == pathID {
            return temp.value
        }
        if pathID == Self.cellularPathID {
            return policy.cellularRouting
        }
        return policy.permanentRouting(forNetworkID: pathID)
    }

    var isOffOnCurrentPath: Bool {
        effectiveRouting == .off
    }

    var effectiveFullTunnel: Bool {
        if case .connect(let full) = decideCurrent() { return full }
        return false
    }

    var statusHeadline: String {
        if wifiIdentityMissing { return "Waiting for Wi‑Fi name" }
        if isOffOnCurrentPath { return "Off on this network" }
        switch status {
        case .connected:
            return effectiveFullTunnel ? "Connected · Full" : "Connected · Split"
        case .connecting: return "Connecting…"
        case .disconnecting: return "Disconnecting…"
        case .invalid: return "Needs attention"
        case .disconnected:
            if statusReason == "Waiting for a network" { return "Waiting for a network" }
            if statusReason == "Wi‑Fi name unavailable" { return "Waiting for Wi‑Fi name" }
            return "Disconnected"
        }
    }

    var statusDetail: String {
        if wifiIdentityMissing || statusReason == "Wi‑Fi name unavailable" {
            return "Moorlan needs this network’s name before connecting."
        }
        if isOffOnCurrentPath {
            return "Tunnel stays off here. Change in Settings to save permanently."
        }
        switch status {
        case .connected:
            return effectiveFullTunnel
                ? "All traffic goes through home."
                : "Only home networks are reached through the tunnel."
        case .connecting:
            return networkExtensionConnected
                ? "Tunnel is up; waiting for a handshake with home…"
                : "Reaching your home…"
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
        Task {
            await reloadManager()
            if let id = onDemandActiveID {
                await setOnDemandActive(id)
            } else {
                await disableOnDemandOnAllManagers()
            }
            await applyDesiredState()
        }
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
        Task {
            if let id = onDemandActiveID {
                await setOnDemandActive(id)
            }
            await applyDesiredState()
        }
    }

    /// TEMP: bounce the tunnel so DNS override / AllowedIPs definitely re-apply.
    func savePolicyAndRestartTunnel() {
        do {
            try store.savePolicy(policy)
        } catch {
            present(error)
            return
        }
        lastProfile = nil
        Task {
            intentionalDisconnect = true
            manager?.connection.stopVPNTunnel()
            try? await Task.sleep(nanoseconds: 400_000_000)
            intentionalDisconnect = false
            userWantsTunnel = true
            if let id = onDemandActiveID {
                await setOnDemandActive(id)
            }
            await applyDesiredState()
        }
    }

    func identifyWiFi() { WiFiIdentity.requestAccess(into: pathMonitor) }

    /// Permanent routing for a Wi‑Fi id (Settings).
    func permanentRouting(forNetworkID id: String) -> NetworkRouting {
        policy.permanentRouting(forNetworkID: id)
    }

    /// Settings: save permanent Wi‑Fi routing.
    func setPermanentRouting(_ routing: NetworkRouting, forNetworkID id: String) {
        guard id.hasPrefix("ssid:") else { return }
        policy.networkRouting[id] = routing
        if let temp = temporaryRouting, temp.pathID == id {
            temporaryRouting = nil
        }
        savePolicy()
    }

    /// Settings: save permanent cellular routing.
    func setPermanentCellularRouting(_ routing: NetworkRouting) {
        policy.cellularRouting = routing
        if temporaryRouting?.pathID == Self.cellularPathID {
            temporaryRouting = nil
        }
        savePolicy()
    }

    /// Home: temporary Off/Split/Full until leaving this path.
    func setTemporaryRouting(_ routing: NetworkRouting) {
        guard let pathID = currentPathID else { return }
        temporaryRouting = (pathID, routing)
        userWantsTunnel = routing != .off
        lastProfile = nil
        Task { await applyDesiredState() }
    }

    /// Known SSIDs: current + any permanently stored.
    var knownNetworkIDs: [String] {
        var ids = Set(policy.networkRouting.keys)
        if let current = currentNetworkID { ids.insert(current) }
        return ids.sorted {
            displayNetworkName($0).localizedCaseInsensitiveCompare(displayNetworkName($1)) == .orderedAscending
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
        lastProfile = nil
        await applyDesiredState()
    }

    func clearPendingDefaultPrompt() {
        pendingDefaultPromptServerID = nil
    }

    /// Pair. Marks current Wi‑Fi permanently Off. Returns whether UI should ask to make default.
    @discardableResult
    func pair(card: QRCard) async throws -> Bool {
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
        if let id = currentNetworkID {
            policy.networkRouting[id] = .off
            if temporaryRouting?.pathID == id { temporaryRouting = nil }
            try store.savePolicy(policy)
        }
        try store.upsert(server)
        servers = try store.loadServers()
        await selectProfile(server.id)
        _ = try await configureProfile(server, enableOnDemand: false)
        let askDefault: Bool
        if !hadOtherTunnels {
            await setOnDemandActive(server.id)
            askDefault = false
        } else {
            askDefault = true
            pendingDefaultPromptServerID = server.id
        }
        await applyDesiredState()
        return askDefault
    }

    func acceptPendingAsDefault() async {
        guard let id = pendingDefaultPromptServerID else { return }
        pendingDefaultPromptServerID = nil
        await setOnDemandActive(id)
        await applyDesiredState()
    }

    func declinePendingAsDefault() {
        pendingDefaultPromptServerID = nil
    }

    /// Make this tunnel the sole on-demand-active profile.
    func setOnDemandActive(_ id: String) async {
        guard servers.contains(where: { $0.id == id }) else { return }
        onDemandActiveID = id
        UserDefaults.standard.set(id, forKey: Self.onDemandActiveKey)
        let offNames = policy.permanentOffSSIDNames
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
        lastProfile = nil
        userWantsTunnel = effectiveRouting != .off
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
            let offIDs = policy.permanentOffNetworkIDs
            if !offIDs.isEmpty {
                guard let id = currentNetworkID, offIDs.contains(id) else {
                    throw MoorlanError.unpairFailed("Join a Wi‑Fi marked Off for this house, then try again")
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
        if pendingDefaultPromptServerID == server.id {
            pendingDefaultPromptServerID = nil
        }
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

    private func decideCurrent() -> TunnelPolicy.Decision {
        let override: NetworkRouting?
        if let pathID = currentPathID, let temp = temporaryRouting, temp.pathID == pathID {
            override = temp.value
        } else {
            override = nil
        }
        return policy.decide(path: pathKind, override: override)
    }

    private func applyOnce() async {
        guard let server = selectedServer else { await disconnect(); return }
        guard !pathMonitor.snapshot.saturated else { statusReason = "Waiting for a network"; return }
        let decision = decideCurrent()
        do {
            let profile = makeProfile(server)
            let changed = profile != lastProfile
            if changed || manager == nil {
                manager = try await configureProfile(server, enableOnDemand: onDemandActiveID == server.id)
                lastProfile = profile
            }
            switch decision {
            case .disconnect(let reason):
                if reason == "Wi‑Fi name unavailable", statusReason != reason {
                    present(MoorlanError.wifiNameUnavailable)
                }
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
        let offNames = policy.permanentOffSSIDNames
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
        do { manager = try await loadOrCreateManager(server); refreshStatus() }
        catch {
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
            Task { @MainActor in
                guard let self else { return }
                self.clearTemporaryIfPathChanged()
                await self.applyDesiredState()
            }
        }.store(in: &cancellables)
    }

    private func clearTemporaryIfPathChanged() {
        let pathID = currentPathID
        if let temp = temporaryRouting, temp.pathID != pathID {
            temporaryRouting = nil
        }
        lastTemporaryPathID = pathID
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
            && !wifiIdentityMissing
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
