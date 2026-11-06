import SwiftUI

/// Persists the prototype theme pick across launches.
@MainActor
final class ThemeStore: ObservableObject {
    @AppStorage("moorlan.prototypeThemeID") private var storedID: String = ThemeID.orbField.rawValue

    var selectedID: ThemeID {
        ThemeID(rawValue: storedID) ?? .orbField
    }

    var theme: MoorlanTheme {
        MoorlanTheme.theme(for: selectedID)
    }

    func select(_ id: ThemeID) {
        storedID = id.rawValue
        objectWillChange.send()
    }
}
