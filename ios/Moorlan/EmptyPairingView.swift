import SwiftUI

struct EmptyPairingView: View {
    var onScan: () -> Void

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(MoorlanCopy.emptyTitle, systemImage: "qrcode.viewfinder")
            } description: {
                Text(MoorlanCopy.emptyBody)
            } actions: {
                Button(MoorlanCopy.emptyButton, action: onScan)
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Uses Moorlan’s camera instead of the system Camera app")
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
