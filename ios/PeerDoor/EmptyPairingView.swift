import SwiftUI

/// Pairing empty state inspired by Mobbin references
/// [World App QR pairing](https://mobbin.com/screens/ac6632f3-1938-416d-ae0b-978a453a0f23) and
/// [Philips Hue ownership card](https://mobbin.com/screens/7ecd51b4-082e-4005-a505-3386320ed0ac).
struct EmptyPairingView: View {
    var onScan: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(PeerDoorTheme.panel)
                    .frame(width: 220, height: 280)
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(PeerDoorTheme.accent.opacity(0.45), lineWidth: 1.5)
                    )
                    .rotation3DEffect(.degrees(-8), axis: (x: 0.2, y: 1, z: 0))
                    .shadow(color: PeerDoorTheme.accent.opacity(0.2), radius: 30, y: 16)
                VStack(spacing: 16) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 72, weight: .medium))
                        .foregroundStyle(PeerDoorTheme.paper)
                    Text("peerdoor")
                        .font(PeerDoorTheme.caption)
                        .foregroundStyle(PeerDoorTheme.mist)
                        .tracking(2)
                }
            }
            VStack(spacing: 10) {
                Text("Pair with your WireGuard host")
                    .font(PeerDoorTheme.display)
                    .foregroundStyle(PeerDoorTheme.paper)
                    .multilineTextAlignment(.center)
                Text("Run peerdoor on the machine with your existing interface, then scan the QR on the same trusted LAN.")
                    .font(PeerDoorTheme.body)
                    .foregroundStyle(PeerDoorTheme.mist)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            Spacer()
            Button(action: onScan) {
                Text("Start QR scan")
                    .font(PeerDoorTheme.title)
                    .foregroundStyle(PeerDoorTheme.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(PeerDoorTheme.accent)
                    )
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 36)
        }
    }
}
