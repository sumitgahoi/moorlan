import Foundation
import CryptoKit

public enum WireGuardKey {
    public static func isValidPublicKey(_ text: String) -> Bool {
        guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return data.count == 32 && data.contains(where: { $0 != 0 })
    }

    public static func makePrivateKey() -> Curve25519.KeyAgreement.PrivateKey {
        Curve25519.KeyAgreement.PrivateKey()
    }

    public static func base64PrivateKey(_ key: Curve25519.KeyAgreement.PrivateKey) -> String {
        key.rawRepresentation.base64EncodedString()
    }

    public static func base64PublicKey(_ key: Curve25519.KeyAgreement.PrivateKey) -> String {
        key.publicKey.rawRepresentation.base64EncodedString()
    }
}
