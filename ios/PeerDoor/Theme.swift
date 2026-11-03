import SwiftUI

/// Visual language drawn from Mobbin VPN / pairing references
/// (NordVPN status orb, Opera connect CTA, Octopus QR scanner) without the
/// default purple-gradient AI look.
enum PeerDoorTheme {
    static let ink = Color(red: 0.04, green: 0.07, blue: 0.12)
    static let panel = Color(red: 0.09, green: 0.13, blue: 0.20)
    static let panelStroke = Color.white.opacity(0.08)
    static let mist = Color.white.opacity(0.62)
    static let paper = Color(red: 0.95, green: 0.97, blue: 0.98)
    static let accent = Color(red: 0.18, green: 0.83, blue: 0.75) // teal
    static let warn = Color(red: 0.96, green: 0.62, blue: 0.28)
    static let danger = Color(red: 0.95, green: 0.35, blue: 0.38)
    static let connected = Color(red: 0.35, green: 0.88, blue: 0.55)

    static let display = Font.custom("AvenirNext-Bold", size: 34, relativeTo: .largeTitle)
    static let title = Font.custom("AvenirNext-DemiBold", size: 22, relativeTo: .title2)
    static let body = Font.custom("AvenirNext-Medium", size: 16, relativeTo: .body)
    static let caption = Font.custom("AvenirNext-Medium", size: 13, relativeTo: .caption)
}

struct InkBackground: View {
    var body: some View {
        ZStack {
            PeerDoorTheme.ink
            RadialGradient(
                colors: [
                    PeerDoorTheme.accent.opacity(0.18),
                    .clear
                ],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 420
            )
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.16, blue: 0.18).opacity(0.55),
                    .clear
                ],
                startPoint: .bottomLeading,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }
}

struct GlassPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(PeerDoorTheme.panel.opacity(0.92))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(PeerDoorTheme.panelStroke, lineWidth: 1)
                    )
            )
    }
}
