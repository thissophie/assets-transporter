import AVFoundation
import SwiftUI
import Vision
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// Camera QR scanning for configure links, on iOS and macOS.
//
// `QRCaptureController` owns the AVCaptureSession and runs it on its own
// queue. QR codes come from `AVCaptureMetadataOutput`; on macOS (where the
// metadata output's QR support is less proven) and wherever `.qr` is not
// offered, a throttled Vision barcode pass over the video frames runs as
// well. Whichever sees a code first wins — the model fires only once.
// `QRScannerModel` handles permission, the no-camera case and the
// fire-once rule; `QRScannerView` is the sheet.

/// AVFoundation side of the scanner. Not main-actor: every session call
/// happens on `sessionQueue`, every frame/metadata callback on `outputQueue`.
nonisolated final class QRCaptureController: NSObject, @unchecked Sendable,
    AVCaptureMetadataOutputObjectsDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {

    enum StartResult: Sendable, Equatable {
        case running
        case noCamera
        case failed(String)
        case cancelled
    }

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "QRCaptureController.session")
    private let outputQueue = DispatchQueue(label: "QRCaptureController.output")

    private let lock = NSLock()
    private var stopped = false
    private var onCode: (@Sendable (String) -> Void)?
    private var lastCode: String?
    private var lastCodeTime: CFAbsoluteTime = 0

    // outputQueue only.
    private var lastVisionPass: CFAbsoluteTime = 0
    private let barcodeRequest: VNDetectBarcodesRequest = {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        return request
    }()

    /// The camera the scanner would use, or nil when the device has none
    /// (Mac mini without a webcam, the iOS Simulator).
    static func preferredCamera() -> AVCaptureDevice? {
        #if os(iOS)
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video)
        #else
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video, position: .unspecified)
        return discovery.devices.first ?? AVCaptureDevice.default(for: .video)
        #endif
    }

    /// Configures (once) and starts the session. `onCode` receives every
    /// distinct decoded string, de-duplicated so one code held in front of
    /// the camera is reported about once a second rather than per frame.
    func start(onCode: @escaping @Sendable (String) -> Void) async -> StartResult {
        lock.withLock {
            self.onCode = onCode
            stopped = false
        }
        return await withCheckedContinuation { continuation in
            sessionQueue.async {
                continuation.resume(returning: self.configureAndRun())
            }
        }
    }

    /// Stops the session and drops the callback. Safe to call repeatedly,
    /// and before `start` has finished (the pending start then does nothing).
    func stop() {
        lock.withLock {
            stopped = true
            onCode = nil
        }
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    deinit {
        if session.isRunning { session.stopRunning() }
    }

    // sessionQueue only.
    private func configureAndRun() -> StartResult {
        if lock.withLock({ stopped }) { return .cancelled }
        if session.inputs.isEmpty {
            guard let camera = Self.preferredCamera() else { return .noCamera }
            let input: AVCaptureDeviceInput
            do {
                input = try AVCaptureDeviceInput(device: camera)
            } catch {
                return .failed(ErrorText.describe(error))
            }
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            guard session.canAddInput(input) else {
                return .failed("The camera could not be used.")
            }
            session.addInput(input)

            var usesMetadata = false
            let metadata = AVCaptureMetadataOutput()
            if session.canAddOutput(metadata) {
                session.addOutput(metadata)
                if metadata.availableMetadataObjectTypes.contains(.qr) {
                    metadata.metadataObjectTypes = [.qr]
                    metadata.setMetadataObjectsDelegate(self, queue: outputQueue)
                    usesMetadata = true
                }
            }
            #if os(macOS)
            let wantsVision = true
            #else
            let wantsVision = !usesMetadata
            #endif
            if wantsVision {
                let video = AVCaptureVideoDataOutput()
                video.alwaysDiscardsLateVideoFrames = true
                video.setSampleBufferDelegate(self, queue: outputQueue)
                if session.canAddOutput(video) {
                    session.addOutput(video)
                } else if !usesMetadata {
                    return .failed("This camera cannot read QR codes.")
                }
            }
        }
        if lock.withLock({ stopped }) { return .cancelled }
        session.startRunning()
        return session.isRunning ? .running : .failed("The camera did not start.")
    }

    // MARK: - Output (outputQueue)

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        for case let code as AVMetadataMachineReadableCodeObject in metadataObjects {
            if let string = code.stringValue { report(string) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastVisionPass >= 0.25 else { return }
        lastVisionPass = now
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up)
        guard (try? handler.perform([barcodeRequest])) != nil else { return }
        for observation in barcodeRequest.results ?? [] {
            if let string = observation.payloadStringValue { report(string) }
        }
    }

    private func report(_ string: String) {
        let now = CFAbsoluteTimeGetCurrent()
        let callback: (@Sendable (String) -> Void)? = lock.withLock {
            guard !stopped else { return nil }
            if string == lastCode, now - lastCodeTime < 1 { return nil }
            lastCode = string
            lastCodeTime = now
            return onCode
        }
        callback?(string)
    }
}

/// Main-actor state for the scanner sheet.
@Observable @MainActor final class QRScannerModel {
    enum Phase: Equatable {
        case starting
        case scanning
        case noCamera
        case denied
        case restricted
        case failed(String)
        case found
    }

    private(set) var phase: Phase = .starting
    /// Brief note shown over the preview after a QR code that isn't a
    /// configure link; scanning carries on.
    private(set) var hint: String?

    @ObservationIgnored let controller = QRCaptureController()
    @ObservationIgnored private var delivered = false
    @ObservationIgnored private var onFound: ((ConfigureLink) -> Void)?
    @ObservationIgnored private var hintTask: Task<Void, Never>?

    static let notALinkHint = "\(ConfigureError.notALink.message) Still scanning…"

    var session: AVCaptureSession { controller.session }

    func start(onFound: @escaping (ConfigureLink) -> Void) async {
        self.onFound = onFound
        guard QRCaptureController.preferredCamera() != nil else {
            phase = .noCamera
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                phase = .denied
                return
            }
        case .restricted:
            phase = .restricted
            return
        default:
            phase = .denied
            return
        }
        guard !delivered else { return }
        let result = await controller.start { [weak self] string in
            guard let self else { return }
            Task { @MainActor in self.handle(string) }
        }
        switch result {
        case .running: if phase == .starting { phase = .scanning }
        case .noCamera: phase = .noCamera
        case .failed(let message): phase = .failed(message)
        case .cancelled: break
        }
    }

    func stop() {
        hintTask?.cancel()
        controller.stop()
    }

    private func handle(_ string: String) {
        guard !delivered else { return }
        guard let link = ConfigureLink(scanned: string) else {
            hint = Self.notALinkHint
            hintTask?.cancel()
            hintTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                self?.hint = nil
            }
            return
        }
        delivered = true
        hint = nil
        phase = .found
        controller.stop()
        onFound?(link)
    }
}

/// Sheet: camera preview with a viewfinder, or an explanation (and a way
/// out to Paste Link) when the camera can't be used.
struct QRScannerView: View {
    /// Called once, with the first valid configure link seen.
    var onFound: (ConfigureLink) -> Void
    /// The user would rather paste the link.
    var onPasteInstead: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var model = QRScannerModel()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Scan QR Code")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        .task { await model.start(onFound: onFound) }
        .onDisappear { model.stop() }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 440)
        #endif
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .starting, .scanning, .found:
            scanner
        case .noCamera:
            ContentUnavailableView {
                Label("No Camera Available", systemImage: "video.slash")
            } description: {
                Text("This device has no camera the app can use. Copy the link shown by the service and use Paste Link instead.")
            } actions: {
                Button("Paste Link Instead", action: onPasteInstead)
            }
        case .denied:
            ContentUnavailableView {
                Label("Camera Access Is Off", systemImage: "video.slash")
            } description: {
                Text("Assets Transporter needs the camera to read the QR code. Turn it on in \(Self.settingsPath), or paste the link instead.")
            } actions: {
                if let url = Self.cameraSettingsURL {
                    Button("Open Settings") { openURL(url) }
                }
                Button("Paste Link Instead", action: onPasteInstead)
            }
        case .restricted:
            ContentUnavailableView {
                Label("Camera Access Is Restricted", systemImage: "video.slash")
            } description: {
                Text("Camera use is restricted on this device, for example by Screen Time or a management profile. Paste the link instead.")
            } actions: {
                Button("Paste Link Instead", action: onPasteInstead)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Camera Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Paste Link Instead", action: onPasteInstead)
            }
        }
    }

    private var scanner: some View {
        ZStack {
            CameraPreview(session: model.session)
                .ignoresSafeArea()
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(.white.opacity(0.9), lineWidth: 3)
                .frame(width: 220, height: 220)
                .shadow(radius: 4)
                .accessibilityHidden(true)
            VStack {
                Spacer()
                Text(model.hint ?? "Point the camera at the QR code shown by the Assets Transporter service.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
                    .padding()
                    .animation(.default, value: model.hint)
            }
            if model.phase == .starting {
                ProgressView()
            }
        }
        .background(.black)
    }

    #if os(iOS)
    private static let settingsPath = "Settings"
    private static var cameraSettingsURL: URL? { URL(string: UIApplication.openSettingsURLString) }
    #else
    private static let settingsPath = "System Settings › Privacy & Security › Camera"
    private static var cameraSettingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
    }
    #endif
}

// MARK: - Preview layer

#if os(iOS)
private struct CameraPreview: UIViewRepresentable {
    var session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.trackRotation()
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        private var coordinator: AVCaptureDevice.RotationCoordinator?
        private var observation: NSKeyValueObservation?

        /// Keeps the preview upright as the device rotates.
        func trackRotation() {
            guard let camera = QRCaptureController.preferredCamera() else { return }
            let coordinator = AVCaptureDevice.RotationCoordinator(device: camera,
                                                                  previewLayer: previewLayer)
            self.coordinator = coordinator
            apply(coordinator.videoRotationAngleForHorizonLevelPreview)
            observation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview,
                                              options: [.new]) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                guard let self else { return }
                Task { @MainActor in self.apply(angle) }
            }
        }

        private func apply(_ angle: CGFloat) {
            guard let connection = previewLayer.connection,
                  connection.isVideoRotationAngleSupported(angle) else { return }
            connection.videoRotationAngle = angle
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // The connection exists only once the session has an input.
            if let coordinator { apply(coordinator.videoRotationAngleForHorizonLevelPreview) }
        }
    }
}
#else
private struct CameraPreview: NSViewRepresentable {
    var session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        let view = NSView()
        view.layer = layer   // layer-hosting: set the layer before wantsLayer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
#endif
