import SwiftUI
import AVFoundation
import UIKit
import MoorlanCore

struct ScannerSheet: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = ScannerModel()
    @State private var phase: Phase = .camera
    @State private var errorText: String?
    @State private var pendingUnpair: UnpairCard?
    @State private var unpairHostName = ""
    @State private var showUnpairConfirmation = false
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
            Group {
                switch phase {
                case .camera:
                    cameraBody
                case .confirming:
                    ProgressView("Confirm unpairing \(unpairHostName)")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .working:
                    ProgressView(progressText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .done:
                    ContentUnavailableView {
                        Label(completionText, systemImage: "checkmark.circle.fill")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
            .navigationTitle("Scan QR")
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
                    .disabled(!model.isRunning || phase != .camera)
                    .accessibilityLabel(model.torchOn ? "Turn flashlight off" : "Turn flashlight on")
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
            .alert("Moorlan", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )) {
                Button("Open Settings") { openSettings() }
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
            .confirmationDialog("Unpair \(unpairHostName)?", isPresented: $showUnpairConfirmation, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) {
                    Task { await performUnpair() }
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
    }

    private var cameraBody: some View {
        VStack(spacing: 16) {
            ZStack {
                if model.isRunning {
                    CameraPreview(session: model.session)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(.secondarySystemFill))
                        .overlay {
                            ProgressView()
                        }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: 420)
            .padding(.horizontal, 20)

            Text("Scan on home Wi‑Fi.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Spacer(minLength: 0)
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
            case .unpair(let card):
                let server = try card.pairedServer(in: tunnel.servers)
                pendingUnpair = card
                unpairHostName = server.displayName
                phase = .confirming
                showUnpairConfirmation = true
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

    private func performUnpair() async {
        guard let card = pendingUnpair else { return }
        phase = .working
        progressText = "Unpairing on the LAN…"
        if await tunnel.unpair(scanned: card) {
            await finish("Unpaired")
        } else {
            errorText = tunnel.lastError ?? "Could not unpair this host"
            await resumeScanning()
        }
    }

    private func finish(_ message: String) async {
        completionText = message
        pendingUnpair = nil
        phase = .done
        try? await Task.sleep(nanoseconds: 700_000_000)
        dismiss()
    }

    private func resumeScanning() async {
        pendingUnpair = nil
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
            cameraError = "Camera access is required to scan the Moorlan QR. Enable it in Settings → Moorlan."
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

    private let queue = DispatchQueue(label: "moorlan.scanner")
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
