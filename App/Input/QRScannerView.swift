import SwiftUI
import UIKit
@preconcurrency import AVFoundation

struct QRScannerView: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                QRScannerRepresentable(onCode: { value in onCode(value); dismiss() }, onError: { error = $0 })
                    .ignoresSafeArea(edges: .bottom)
                VStack {
                    Text("Gateway のセットアップ QR を読み取ります")
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding()
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(.top, 20)
                    Spacer()
                    if let error {
                        Text(error)
                            .foregroundStyle(.white)
                            .padding(20)
                            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 16))
                            .padding()
                    }
                }
            }
            .navigationTitle("QR を読み取る")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
    }
}

private struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onError: (String) -> Void
    func makeUIViewController(context: Context) -> QRScannerController {
        QRScannerController(onCode: onCode, onError: onError)
    }
    func updateUIViewController(_ uiViewController: QRScannerController, context: Context) {}
    static func dismantleUIViewController(_ uiViewController: QRScannerController, coordinator: ()) { uiViewController.stop() }
}

/// Capture work runs on one private queue; UIKit and decoded results stay on the main actor.
private final class CaptureSessionBox: @unchecked Sendable {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "ai.ohmyopenclaw.qr")
}

@MainActor
private final class QRScannerController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    private let capture = CaptureSessionBox()
    private let onCode: (String) -> Void
    private let onError: (String) -> Void
    private var preview: AVCaptureVideoPreviewLayer?
    private var didRead = false
    private var active = true

    init(onCode: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        self.onCode = onCode; self.onError = onError
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        Task { @MainActor [weak self] in
            guard let self else { return }
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            guard self.active else { return }
            guard allowed else { self.onError("カメラを許可するか、セットアップコードを貼り付けてください。"); return }
            self.configure()
        }
    }

    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }

    private func configure() {
        guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera) else {
            onError("カメラを利用できません。セットアップコードを貼り付けて接続できます。")
            return
        }
        let output = AVCaptureMetadataOutput()
        let session = capture.session
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            onError("QR を読み取れません。セットアップコードを貼り付けてください。")
            return
        }
        session.addInput(input)
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        session.commitConfiguration()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
        layer.frame = view.bounds
        let box = capture
        box.queue.async { box.session.startRunning() }
    }

    func stop() { active = false; let box = capture; box.queue.async { if box.session.isRunning { box.session.stopRunning() } } }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !didRead, let code = metadataObjects.first as? AVMetadataMachineReadableCodeObject, let value = code.stringValue else { return }
        didRead = true
        stop()
        onCode(value)
    }
}
