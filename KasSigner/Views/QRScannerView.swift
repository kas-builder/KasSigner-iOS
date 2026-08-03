import AVFoundation
import Vision
import SwiftUI

enum QRScanFeedback {
    case idle
    case accepted
    case rejected
}

struct QRScannerView: View {
    let onScan: (String) -> Void
    let feedback: QRScanFeedback
    let progressText: String?

    init(
        feedback: QRScanFeedback = .idle,
        progressText: String? = nil,
        onScan: @escaping (String) -> Void
    ) {
        self.feedback = feedback
        self.progressText = progressText
        self.onScan = onScan
    }

    @Environment(\.dismiss) private var dismiss
    @State private var cameraPermissionDenied = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if cameraPermissionDenied {
                    ContentUnavailableView {
                        Label("Camera Access Required", systemImage: "camera.fill")
                    } description: {
                        Text("Allow camera access in Settings to scan the public wallet QR shown by your M5 KasSigner.")
                    }
                    .foregroundStyle(.white)
                } else {
                    QRScannerCameraView(
                        onScan: { value in
                            onScan(value)
                        },
                        onPermissionDenied: {
                            cameraPermissionDenied = true
                        }
                    )
                    .ignoresSafeArea()

                    VStack {
                        Spacer()

                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(scannerFrameColor, lineWidth: 4)
                            .frame(width: 270, height: 270)
                            .animation(
                                .easeInOut(duration: 0.16),
                                value: feedback
                            )
                            .overlay {
                                VStack(spacing: 5) {
                                    Text(
                                        progressText
                                            ?? "Align the QR inside the frame"
                                    )
                                    .font(.callout.weight(.semibold))

                                    if feedback == .accepted {
                                        Text("Frame accepted")
                                            .font(.caption.weight(.semibold))
                                    } else if feedback == .rejected {
                                        Text("Frame not accepted")
                                            .font(.caption.weight(.semibold))
                                    }
                                }
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)
                                .offset(y: 184)
                            }

                        Spacer()
                    }
                }
            }
            .navigationTitle("Scan Wallet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private var scannerFrameColor: Color {
        switch feedback {
        case .idle:
            return .white.opacity(0.9)
        case .accepted:
            return Color(
                red: 0.20,
                green: 0.82,
                blue: 0.66
            )
        case .rejected:
            return .red
        }
    }
}

private struct QRScannerCameraView: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onPermissionDenied: () -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onScan = onScan
        controller.onPermissionDenied = onPermissionDenied
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}


private final class BinaryQRVideoDecoder:
    NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    let queue = DispatchQueue(
        label: "KasSigner.BinaryQRVideoDecoder",
        qos: .userInitiated
    )

    var onPayload: (@Sendable (Data) -> Void)?

    private let lock = NSLock()
    private var enabledUntil: TimeInterval = 0
    private var lastPayload: Data?
    private var lastPayloadTime: TimeInterval = 0

    func enableBriefly() {
        lock.lock()
        enabledUntil = ProcessInfo.processInfo.systemUptime + 1.5
        lock.unlock()
    }

    private struct QRBitReader {
        let bytes: [UInt8]
        var bitIndex = 0

        mutating func readBits(_ count: Int) -> Int? {
            guard count >= 0,
                  bitIndex + count <= bytes.count * 8
            else {
                return nil
            }

            var value = 0

            for _ in 0..<count {
                let byteIndex = bitIndex / 8
                let bitOffset = 7 - (bitIndex % 8)
                let bit = (bytes[byteIndex] >> bitOffset) & 1

                value = (value << 1) | Int(bit)
                bitIndex += 1
            }

            return value
        }
    }

    private func extractQRByteModePayload(
        from observation: VNBarcodeObservation
    ) -> Data? {
        guard let descriptor =
                observation.barcodeDescriptor as? CIQRCodeDescriptor
        else {
            return nil
        }

        let codewords = [UInt8](descriptor.errorCorrectedPayload)
        var reader = QRBitReader(bytes: codewords)

        guard let mode = reader.readBits(4) else {
            return nil
        }

        // M5 QR encoder uses standard QR byte mode: 0100.
        guard mode == 0b0100 else {
            return nil
        }

        // M5 currently emits QR versions 1–6. Byte-mode character
        // count is therefore an 8-bit field.
        let countBitWidth = descriptor.symbolVersion <= 9 ? 8 : 16

        guard let byteCount = reader.readBits(countBitWidth),
              byteCount > 0
        else {
            return nil
        }

        var payload = Data()
        payload.reserveCapacity(byteCount)

        for _ in 0..<byteCount {
            guard let byte = reader.readBits(8) else {
                return nil
            }

            payload.append(UInt8(byte))
        }

        return payload
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        let enabled = now <= enabledUntil
        lock.unlock()

        guard enabled,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else {
            return
        }

        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]

        do {
            let handler = VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer,
                orientation: .right,
                options: [:]
            )

            try handler.perform([request])

            guard let observation = request.results?.first,
                  let payload = extractQRByteModePayload(
                    from: observation
                  ),
                  !payload.isEmpty
            else {
                return
            }

            lock.lock()

            let duplicate =
                payload == lastPayload &&
                now - lastPayloadTime < 0.75

            if !duplicate {
                lastPayload = payload
                lastPayloadTime = now
            }

            lock.unlock()

            guard !duplicate else {
                return
            }


            onPayload?(payload)
        } catch {
            // Ignore transient Vision decoding failures and continue scanning.
        }
    }
}

private final class QRScannerCaptureSession: @unchecked Sendable {
    let session = AVCaptureSession()

    private let queue = DispatchQueue(
        label: "org.kassigner.KasSigner.qr-capture-session",
        qos: .userInitiated
    )

    func start() {
        queue.async { [self] in
            guard !session.isRunning else { return }
            session.startRunning()
        }
    }

    func stop() {
        queue.async { [self] in
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }
}

@MainActor
private final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    var onPermissionDenied: (() -> Void)?

    private let captureSession = QRScannerCaptureSession()
    private let binaryQRDecoder = BinaryQRVideoDecoder()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    private var session: AVCaptureSession {
        captureSession.session
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        binaryQRDecoder.onPayload = { [weak self] payload in
            let hex = payload.map {
                String(format: "%02x", $0)
            }.joined()

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }


                self.onScan?("KSBIN:" + hex)
            }
        }

        requestCameraAndConfigure()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureSession.stop()
    }

    private func requestCameraAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    granted ? self.configureSession() : self.onPermissionDenied?()
                }
            }
        default:
            onPermissionDenied?()
        }
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            onPermissionDenied?()
            return
        }

        session.beginConfiguration()
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }

        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(
            binaryQRDecoder,
            queue: binaryQRDecoder.queue
        )

        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        session.commitConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer

        captureSession.start()
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {

        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject else {
            return
        }


        guard let value = object.stringValue else {

            Task { @MainActor [weak self] in
                self?.binaryQRDecoder.enableBriefly()
            }

            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onScan?(value)
        }
    }
}
