import SwiftUI
import AVFoundation
import UIKit
import PeerDoorCore

/// Scanner chrome inspired by
/// [Octopus Energy add device](https://mobbin.com/screens/05e22c38-688c-4d6b-bc8e-7b7ce1217cb6).
struct ScannerSheet: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = ScannerModel()
    @State private var phase: Phase = .camera
    @State private var errorText: String?
    @State private var pendingUnjoin: UnjoinCard?
    @State private var unjoinHostName = ""
    @State private var showUnjoinConfirmation = false
    @State private var progressText = "Pairing on the LAN…"
    @State private var completionText = "Paired"

    private enum Phase: Equatable {
        case camera
        case working
        case confirming
        case done
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                switch phase {
                case .camera:
                    cameraBody
                case .confirming:
                    Text("Confirm unjoining \(unjoinHostName)")
                        .foregroundStyle(.white)
                case .working:
                    ProgressView(progressText)
                        .tint(PeerDoorTheme.accent)
                        .foregroundStyle(.white)
                case .done:
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(PeerDoorTheme.connected)
                        Text(completionText)
                            .font(PeerDoorTheme.title)
                            .foregroundStyle(.white)
                    }
                }
            }
            .navigationTitle("Scan PeerDoor QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(phase == .working)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.toggleTorch()
                    } label: {
                        Image(systemName: model.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                    }
                    .disabled(!model.isRunning)
                }
            }
            .alert("Camera", isPresented: Binding(
                get: { model.cameraError != nil && errorText == nil },
                set: { if !$0 { model.clearCameraError() } }
            )) {
                Button("Open Settings") { openSettings() }
                Button("Cancel", role: .cancel) { dismiss() }
            } message: {
                Text(model.cameraError ?? "")
            }
            .alert("PeerDoor", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )) {
                Button("Open Settings") { openSettings() }
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
            .confirmationDialog("Unjoin \(unjoinHostName)?", isPresented: $showUnjoinConfirmation, titleVisibility: .visible) {
                Button("Unjoin", role: .destructive) {
                    Task { await performUnjoin() }
                }
                Button("Cancel", role: .cancel) {
                    Task { await resumeScanning() }
                }
            } message: {
                Text("Remove this device from the server and delete its local VPN configuration.")
            }
            .interactiveDismissDisabled(phase == .working)
            .task {
                await model.start()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, self.phase == .camera {
                    model.clearCameraError()
                    Task { await model.start() }
                }
            }
            .onDisappear {
                model.stop()
            }
            .onChange(of: model.scannedPayload) { _, payload in
                guard let payload else { return }
                Task { await handle(payload) }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var cameraBody: some View {
        VStack(spacing: 18) {
            ZStack {
                if model.isRunning {
                    CameraPreview(session: model.session)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(PeerDoorTheme.panel)
                        .overlay {
                            ProgressView()
                                .tint(PeerDoorTheme.accent)
                        }
                }
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(PeerDoorTheme.accent, lineWidth: 2)
                    .padding(1)
            }
            .padding(.horizontal, 20)
            .frame(maxHeight: 420)

            HStack(spacing: 12) {
                Image(systemName: "qrcode.viewfinder")
                Text("Scan on home Wi-Fi. Allow Camera and Local Network when asked.")
                    .font(PeerDoorTheme.body)
            }
            .foregroundStyle(PeerDoorTheme.mist)
            .padding(.horizontal, 24)

            Spacer()
        }
        .padding(.top, 12)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func handle(_ text: String) async {
        phase = .working
        progressText = "Reading QR…"
        do {
            switch try ScannedCode.parse(text) {
            case .unjoin(let card):
                let server = try card.pairedServer(in: tunnel.servers)
                pendingUnjoin = card
                unjoinHostName = server.displayName
                phase = .confirming
                showUnjoinConfirmation = true
            case .pair(let card):
                progressText = "Pairing on the LAN…"
                try await tunnel.pair(card: card)
                await finish("Paired")
            }
        } catch {
            errorText = error.localizedDescription
            await resumeScanning()
        }
    }

    private func performUnjoin() async {
        guard let card = pendingUnjoin else { return }
        phase = .working
        progressText = "Unjoining on the LAN…"
        if await tunnel.unjoin(scanned: card) {
            await finish("Unjoined")
        } else {
            errorText = tunnel.lastError ?? "Could not unjoin this host"
            await resumeScanning()
        }
    }

    private func finish(_ message: String) async {
        completionText = message
        pendingUnjoin = nil
        phase = .done
        try? await Task.sleep(nanoseconds: 700_000_000)
        dismiss()
    }

    private func resumeScanning() async {
        pendingUnjoin = nil
        phase = .camera
        model.resetScan()
        await model.start()
    }

}

@MainActor
final class ScannerModel: ObservableObject {
    let session: AVCaptureSession
    @Published var scannedPayload: String?
    @Published var torchOn = false
    @Published var isRunning = false
    @Published var cameraError: String?

    private let controller: CaptureController

    init() {
        let controller = CaptureController()
        self.controller = controller
        self.session = controller.session
        controller.onCode = { [weak self] value in
            Task { @MainActor in
                guard let self, self.scannedPayload == nil else { return }
                self.scannedPayload = value
                self.controller.stopRunning()
                self.isRunning = false
            }
        }
    }

    func clearCameraError() {
        cameraError = nil
    }

    func resetScan() {
        scannedPayload = nil
    }

    func start() async {
        cameraError = nil

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let granted: Bool
        switch status {
        case .authorized:
            granted = true
        case .notDetermined:
            granted = await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            granted = false
        @unknown default:
            granted = false
        }

        guard granted else {
            cameraError = "Camera access is required to scan the PeerDoor QR. Enable it in Settings → PeerDoor."
            return
        }

        do {
            try await controller.start()
            isRunning = true
        } catch {
            isRunning = false
            cameraError = error.localizedDescription
        }
    }

    func stop() {
        controller.stopRunning()
        isRunning = false
        torchOn = false
    }

    func toggleTorch() {
        controller.toggleTorch { [weak self] on in
            Task { @MainActor in
                self?.torchOn = on
            }
        }
    }
}

/// Owns all AVCaptureSession work on a dedicated queue. Never MainActor-isolated.
final class CaptureController: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    let session = AVCaptureSession()
    var onCode: ((String) -> Void)?

    private let queue = DispatchQueue(label: "peerdoor.scanner")
    private var configured = false

    func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.configureIfNeeded()
                    if !self.session.isRunning {
                        self.session.startRunning()
                    }
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func stopRunning() {
        queue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func toggleTorch(completion: @escaping (Bool) -> Void) {
        queue.async {
            guard let device = AVCaptureDevice.default(for: .video),
                  device.hasTorch else {
                completion(false)
                return
            }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                let on = device.torchMode != .on
                if on {
                    try device.setTorchModeOn(level: 1)
                } else {
                    device.torchMode = .off
                }
                completion(on)
            } catch {
                completion(false)
            }
        }
    }

    private func configureIfNeeded() throws {
        if configured { return }

        guard let device = AVCaptureDevice.default(for: .video) else {
            throw ScannerFailure.unavailable
        }
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()

        if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }

        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw ScannerFailure.unavailable
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw ScannerFailure.unavailable
        }
        session.addOutput(output)

        // Must commit before startRunning. Also: assigning unsupported metadata types crashes.
        let available = Set(output.availableMetadataObjectTypes)
        guard available.contains(.qr) else {
            session.commitConfiguration()
            throw ScannerFailure.qrUnsupported
        }
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        output.metadataObjectTypes = [.qr]

        session.commitConfiguration()
        configured = true
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue else { return }
        onCode?(value)
    }
}

private enum ScannerFailure: LocalizedError {
    case unavailable
    case qrUnsupported

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "No camera is available on this device."
        case .qrUnsupported:
            return "This camera cannot scan QR codes."
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
