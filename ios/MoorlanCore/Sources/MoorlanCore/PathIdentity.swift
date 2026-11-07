import Foundation

/// Path identity for routing policy.
///
/// - **Stable** = named Wi‑Fi, or cellular with Wi‑Fi absent → real path policy.
/// - **Transitional** = anything else (incl. Wi‑Fi with no SSID) → **Full** until
///   stable. If never stable, remain Full. Missing SSID is not an error.
public enum PathIdentity: Equatable, Sendable {
    case stable(TunnelPolicy.PathKind)
    case transitional

    /// - Wi‑Fi + known SSID → stable Wi‑Fi
    /// - Cellular, no Wi‑Fi → stable cellular
    /// - Wi‑Fi present without SSID (dual-path or not) → transitional (Full)
    /// - No Wi‑Fi, no cellular → transitional (Full until a real path appears)
    public static func classify(
        hasWiFi: Bool,
        hasCellular: Bool,
        wifiNetworkID: String?
    ) -> PathIdentity {
        if hasWiFi {
            if let id = wifiNetworkID, isKnownSSID(id) {
                return .stable(.wifi(id: id))
            }
            return .transitional
        }
        if hasCellular {
            return .stable(.cellular)
        }
        return .transitional
    }

    public static func isKnownSSID(_ id: String) -> Bool {
        id.hasPrefix("ssid:") && id != "unidentified"
    }
}
