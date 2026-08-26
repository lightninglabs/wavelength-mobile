import AVFoundation
import SwiftUI
import UIKit
import WalletKit

struct PaymentQRCodeScannerView: View {
    @Environment(\.presentationMode) private var presentationMode
    @State private var authorization = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var cameraError: String?

    let onScan: (String) -> Void

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                scannerContent
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .foregroundStyle(.white)
                }
            }
            .task { await requestCameraAccessIfNeeded() }
        }
    }

    @ViewBuilder
    private var scannerContent: some View {
        switch authorization {
        case .authorized:
            if let cameraError {
                cameraUnavailable(message: cameraError)
            } else {
                ZStack {
                    QRCodeCameraPreview(
                        onCode: accept,
                        onError: { cameraError = $0.localizedDescription }
                    )
                    .ignoresSafeArea()

                    VStack(spacing: 22) {
                        Spacer()
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(.white, lineWidth: 3)
                            .frame(width: 260, height: 260)
                            .shadow(color: .black.opacity(0.45), radius: 5)
                            .accessibilityHidden(true)
                        Text("Position a Lightning invoice or Bitcoin payment QR code inside the frame.")
                            .font(.subheadline.weight(.medium))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 30)
                            .padding(.vertical, 12)
                            .background(.black.opacity(0.65), in: Capsule())
                            .padding(.horizontal, 24)
                        Spacer()
                    }
                }
            }

        case .notDetermined:
            ProgressView("Requesting camera access…")
                .tint(.white)
                .foregroundStyle(.white)

        case .denied, .restricted:
            VStack(spacing: 18) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 42))
                Text("Camera Access Needed")
                    .font(.title2.bold())
                Text("Allow camera access to scan payment QR codes. You can still cancel and paste an invoice instead.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if authorization == .denied {
                    Button("Open Settings") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .foregroundStyle(.white)
            .padding(32)

        @unknown default:
            cameraUnavailable(message: "Camera authorization is unavailable.")
        }
    }

    private func cameraUnavailable(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.metering.unknown")
                .font(.system(size: 42))
            Text("Camera Unavailable")
                .font(.title2.bold())
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("Cancel and use Paste from Clipboard to enter the payment request.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
        .padding(32)
    }

    @MainActor
    private func requestCameraAccessIfNeeded() async {
        guard authorization == .notDetermined else { return }
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        authorization = granted ? .authorized : .denied
    }

    private func accept(_ payload: String) {
        let destination = PaymentRequestParser.normalizedDestination(from: payload)
        guard !destination.isEmpty else {
            cameraError = "The QR code did not contain a payment request."
            return
        }

        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onScan(destination)
        presentationMode.wrappedValue.dismiss()
    }
}

private struct QRCodeCameraPreview: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onError: (Error) -> Void

    func makeUIViewController(context: Context) -> QRCodeScannerViewController {
        QRCodeScannerViewController(onCode: onCode, onError: onError)
    }

    func updateUIViewController(_ uiViewController: QRCodeScannerViewController, context: Context) {}
}

private final class QRCodeScannerViewController: UIViewController,
    AVCaptureMetadataOutputObjectsDelegate {

    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "engineering.lightning.wavelength.qr-camera")
    private let onCode: (String) -> Void
    private let onError: (Error) -> Void
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isConfigured = false
    private var didScan = false

    init(onCode: @escaping (String) -> Void, onError: @escaping (Error) -> Void) {
        self.onCode = onCode
        self.onError = onError
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard isConfigured else { return }
        sessionQueue.async { [captureSession] in
            if !captureSession.isRunning {
                captureSession.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [captureSession] in
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        if let connection = previewLayer?.connection,
           connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }

    private func configureSession() {
        guard let camera = AVCaptureDevice.default(for: .video) else {
            fail(QRCodeScannerError.cameraUnavailable)
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            guard captureSession.canAddInput(input) else {
                fail(QRCodeScannerError.inputUnavailable)
                return
            }
            captureSession.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard captureSession.canAddOutput(output) else {
                fail(QRCodeScannerError.outputUnavailable)
                return
            }
            captureSession.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            let preview = AVCaptureVideoPreviewLayer(session: captureSession)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.addSublayer(preview)
            previewLayer = preview
            isConfigured = true
        } catch {
            fail(error)
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didScan,
              let code = metadataObjects
                .compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
                .first(where: { $0.type == .qr })?.stringValue else {
            return
        }

        didScan = true
        sessionQueue.async { [captureSession] in
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
        onCode(code)
    }

    private func fail(_ error: Error) {
        DispatchQueue.main.async { [onError] in onError(error) }
    }
}

private enum QRCodeScannerError: LocalizedError {
    case cameraUnavailable
    case inputUnavailable
    case outputUnavailable

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            return "This device does not provide a camera. The iOS Simulator usually requires clipboard input."
        case .inputUnavailable:
            return "The camera could not be connected to the scanner."
        case .outputUnavailable:
            return "QR-code recognition is unavailable on this device."
        }
    }
}
