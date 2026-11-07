import SwiftUI
import AVFoundation
import UIKit
import MoorlanCore

struct ScannerSheet: View {
    /// When set (Camera → Open / deep link), skip the in-app camera and run pair/unpair.
    var initialPayload: String? = nil

    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = ScannerModel()
    @State private var phase: Phase = .camera
    @State private var facingError: UserFacingError?
    @State private var pendingUnpair: UnpairCard?
    @State private var unpairHostName = ""
    @State private var progressText = MoorlanCopy.reachingServer
    @State private var completionText = MoorlanCopy.paired
    @State private var workTask: Task<Void, Never>?
    @State private var startedInitial = false

    private enum Phase: Equatable {
        case camera
        case working
        case confirming
        case done
    }

    private var usingInAppCamera: Bool { initialPayload == nil }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .camera:
                    cameraBody
                case .confirming:
                    unpairConfirmBody
                case .working:
                    ProgressView(progressText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .done:
                    PairSuccessView(title: completionText)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
            .navigationTitle(MoorlanCopy.scanTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase == .working ? "Cancel" : "Close") {
                        workTask?.cancel()
                        workTask = nil
                        dismiss()
                    }
                }
                if usingInAppCamera {
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
            }
            .alert(
                model.cameraFacingError?.title ?? "Camera",
                isPresented: Binding(
                    get: { model.cameraFacingError != nil && facingError == nil },
                    set: { if !$0 { model.clearCameraError() } }
                )
            ) {
                if model.cameraFacingError?.action == .openSettings {
                    Button("Open Settings") { openSettings() }
                }
                Button("Cancel", role: .cancel) { dismiss() }
            } message: {
                Text(model.cameraFacingError?.message ?? "")
            }
            .alert(
                facingError?.title ?? "Moorlan",
                isPresented: Binding(
                    get: { facingError != nil },
                    set: { if !$0 { facingError = nil } }
                )
            ) {
                if facingError?.action == .openSettings {
                    Button("Open Settings") { openSettings() }
                }
                if facingError?.action == .retry, usingInAppCamera {
                    Button("Retry") {
                        facingError = nil
                        Task { await resumeScanning() }
                    }
                }
                Button("OK", role: .cancel) {
                    facingError = nil
                    if !usingInAppCamera { dismiss() }
                }
            } message: {
                Text(facingError?.message ?? "")
            }
            .task {
                if let initialPayload, !startedInitial {
                    startedInitial = true
                    phase = .working
                    workTask = Task { await handle(initialPayload) }
                    return
                }
                guard usingInAppCamera else { return }
                await model.start()
            }
            .onChange(of: scenePhase) { _, phase in
                guard usingInAppCamera else { return }
                if phase == .active, self.phase == .camera {
                    model.clearCameraError()
                    Task { await model.start() }
                }
            }
            .onChange(of: model.scannedPayload) { _, payload in
                guard usingInAppCamera, let payload else { return }
                workTask?.cancel()
                workTask = Task { await handle(payload) }
            }
            .onDisappear {
                workTask?.cancel()
                workTask = nil
                if usingInAppCamera { model.stop() }
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

            Text(MoorlanCopy.scanBody)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Spacer(minLength: 0)
        }
        .padding(.top, 12)
    }

    /// Inline confirm — `confirmationDialog` often never appears over a sheet
    /// that just opened from Camera → Open / deep link.
    private var unpairConfirmBody: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            Text("\(MoorlanCopy.unpairConfirmTitlePrefix) \(unpairHostName)?")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(MoorlanCopy.unpairConfirmMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 12) {
                Button(role: .destructive) {
                    Task { await performUnpair() }
                } label: {
                    Text(MoorlanCopy.unpairConfirmButton)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    Task { await resumeScanning() }
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func handle(_ text: String) async {
        phase = .working
        progressText = MoorlanCopy.pairing
        do {
            try Task.checkCancellation()
            switch try ScannedCode.parse(text) {
            case .unpair(let card):
                let server = try card.pairedServer(in: tunnel.servers)
                pendingUnpair = card
                unpairHostName = server.displayName
                phase = .confirming
            case .pair(let card):
                progressText = MoorlanCopy.reachingServer
                try await tunnel.pair(card: card)
                try Task.checkCancellation()
                await finish(MoorlanCopy.paired)
            }
        } catch is CancellationError {
            await resumeScanning()
        } catch let urlError as URLError where urlError.code == .cancelled {
            await resumeScanning()
        } catch {
            facingError = UserFacingError.map(error)
            if usingInAppCamera {
                await resumeScanning()
            }
            // Deep link: keep sheet up so the error alert can show; OK dismisses.
        }
    }

    private func performUnpair() async {
        guard let card = pendingUnpair else { return }
        workTask?.cancel()
        workTask = Task {
            phase = .working
            progressText = MoorlanCopy.unpairing
            if await tunnel.unpair(scanned: card) {
                await finish(MoorlanCopy.unpaired)
            } else {
                facingError = tunnel.presentedError
                    ?? UserFacingError(
                        title: "Could not unpair",
                        message: "The host did not confirm removal. Local pairing was kept so you can retry.",
                        action: .retry
                    )
                tunnel.clearPresentedError()
                await resumeScanning()
            }
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
        guard usingInAppCamera else {
            // Deep-link / Camera-open path: leave after an error; user can scan again.
            phase = .done
            dismiss()
            return
        }
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
    @Published var cameraFacingError: UserFacingError?

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
        cameraFacingError = nil
    }

    func resetScan() {
        scannedPayload = nil
    }

    func start() async {
        cameraFacingError = nil

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
            cameraFacingError = UserFacingError(
                title: "Camera access needed",
                message: "Moorlan needs the camera to scan pair and unpair QR codes. Enable Camera in Settings, then try again.",
                action: .openSettings
            )
            return
        }

        do {
            try await controller.start()
            isRunning = true
        } catch {
            isRunning = false
            cameraFacingError = UserFacingError.mapScanner(error)
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

private enum ScannerFailure: Error {
    case unavailable
    case qrUnsupported
}

extension ScannerFailure: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "No camera is available on this device."
        case .qrUnsupported:
            return "This camera cannot scan QR codes."
        }
    }
}

// Map scanner failures into friendly UI errors without exposing AVFoundation strings.
extension UserFacingError {
    static func mapScanner(_ error: Error) -> UserFacingError {
        if let failure = error as? ScannerFailure {
            switch failure {
            case .unavailable:
                return UserFacingError(
                    title: "Camera unavailable",
                    message: "This device does not have a camera Moorlan can use for QR scanning.",
                    action: .ok
                )
            case .qrUnsupported:
                return UserFacingError(
                    title: "QR not supported",
                    message: "This camera cannot read QR codes. Try another device.",
                    action: .ok
                )
            }
        }
        return map(error)
    }
}

/// Native pair/unpair completion — system checkmark, no prototype theme wash.
private struct PairSuccessView: View {
    var title: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .scaleEffect(appeared ? 1 : 0.7)
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
                    appeared = true
                }
            }
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
