//
//  ProjectorScannerView.swift
//  BeadInventory
//
//  扫投影仪投在墙上那个二维码
//
//  只认 `beadprojector://` 开头的那一种。用户对着别的码扫不会有任何反应 ——
//  这一屏只有一个用途，认错了反而要解释「为什么扫到了却连不上」。
//

import AudioToolbox
import AVFoundation
import SwiftUI

struct ProjectorScannerView: View {
    let onFound: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScannerRepresentable(onFound: onFound)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("扫描二维码")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                }
        }
    }
}

private struct ScannerRepresentable: UIViewControllerRepresentable {
    let onFound: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onFound = onFound
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onFound: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    /// 认出来之后不再认第二次。投影出来的码停在墙上不动，一秒能触发几十次回调，
    /// 每次都建一条连接的话，前几条会互相顶掉。
    private var hasFound = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !session.isRunning else { return }
        // 开相机会占住主线程小一秒，这一屏是滑上来的，卡在半路上很显眼。
        Task.detached { [session] in session.startRunning() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !hasFound else { return }
        for object in metadataObjects {
            guard let readable = object as? AVMetadataMachineReadableCodeObject,
                  let value = readable.stringValue,
                  value.hasPrefix("beadprojector://") else { continue }
            hasFound = true
            AudioServicesPlaySystemSound(1057)
            onFound?(value)
            return
        }
    }
}
