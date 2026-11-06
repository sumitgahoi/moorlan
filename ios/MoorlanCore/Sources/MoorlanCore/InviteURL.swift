import Foundation

/// Shared parser for Camera-openable `moorlan://v1/{pair|unpair}?url=…&spk=…` invites.
enum InviteURL {
    enum Action: String {
        case pair
        case unpair
    }

    struct Parsed: Equatable {
        var action: Action
        var controlURL: URL
        var serverPublicKey: String
    }

    static func parse(_ text: String) throws -> Parsed {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "moorlan",
              url.host == "v1" else {
            throw MoorlanError.invalidCard(
                "This isn’t a Moorlan invite. Open Camera, scan the QR from sudo moorlan --pair / --unpair on the latest server, or use Scan in Moorlan."
            )
        }
        let actionPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let action = Action(rawValue: actionPath) else {
            throw MoorlanError.invalidCard("unsupported invite path")
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let control = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let spk = components.queryItems?.first(where: { $0.name == "spk" })?.value,
              let controlURL = URL(string: control), !spk.isEmpty else {
            throw MoorlanError.invalidCard("invite missing url or spk")
        }
        return Parsed(action: action, controlURL: controlURL, serverPublicKey: spk)
    }
}
