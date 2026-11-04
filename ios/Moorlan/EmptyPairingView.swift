import SwiftUI

struct EmptyPairingView: View {
    var onScan: () -> Void

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Pair with your WireGuard host", systemImage: "qrcode.viewfinder")
            } description: {
                Text("Run moorlan on the machine with your existing interface, then scan the QR on the same trusted LAN.")
            } actions: {
                Button {
                    onScan()
                } label: {
                    Text("Start QR Scan")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 48)
            }
            .navigationTitle("Moorlan")
        }
    }
}
