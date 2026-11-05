import SwiftUI

struct EmptyPairingView: View {
    var onScan: () -> Void

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Pair with your home", systemImage: "qrcode.viewfinder")
            } description: {
                Text("Scan the QR from your Moorlan host while on home Wi‑Fi.")
            } actions: {
                Button {
                    onScan()
                } label: {
                    Text("Scan QR")
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
