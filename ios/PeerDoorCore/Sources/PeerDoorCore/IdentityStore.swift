import Foundation
import Security
import CryptoKit

/// Stores the phone's long-lived WireGuard private key in the Keychain.
public struct IdentityStore: Sendable {
    public struct Identity: Equatable, Sendable {
        public var privateKey: String
        public var publicKey: String
    }

    private let service: String
    private let accessGroup: String?
    private let account = "wireguard-private-key"

    public init(service: String = "app.peerdoor.identity", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func loadOrCreate() throws -> Identity {
        if let existing = try load() {
            return existing
        }
        // Preserve the identity created before shared Keychain support.
        if accessGroup != nil, let legacy = try IdentityStore(service: service).load() {
            try save(privateKey: legacy.privateKey)
            return legacy
        }
        let privateKey = WireGuardKey.makePrivateKey()
        let identity = Identity(
            privateKey: WireGuardKey.base64PrivateKey(privateKey),
            publicKey: WireGuardKey.base64PublicKey(privateKey)
        )
        try save(privateKey: identity.privateKey)
        return identity
    }

    public func load() throws -> Identity? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data,
              let privateKey = String(data: data, encoding: .utf8),
              let raw = Data(base64Encoded: privateKey),
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) else {
            throw PeerDoorError.missingIdentity
        }
        return Identity(
            privateKey: privateKey,
            publicKey: WireGuardKey.base64PublicKey(key)
        )
    }

    private func save(privateKey: String) throws {
        let data = Data(privateKey.utf8)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw PeerDoorError.tunnelFailed("keychain save failed (\(status))")
        }
    }
}
