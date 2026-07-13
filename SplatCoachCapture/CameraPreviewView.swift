//
//  CameraPreviewView.swift
//  SplatCoachCapture
//
//  Created by Michael Carlino on 7/3/26.
//

import AVFoundation
import SwiftUI

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let orientation: AVCaptureVideoOrientation
    let onTapToFocus: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTapToFocus: onTapToFocus)
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.connection?.setOrientationIfSupported(orientation)
        let tapRecognizer = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.didTap(_:))
        )
        view.addGestureRecognizer(tapRecognizer)
        context.coordinator.previewView = view
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
        uiView.previewLayer.connection?.setOrientationIfSupported(orientation)
        context.coordinator.onTapToFocus = onTapToFocus
    }

    final class Coordinator: NSObject {
        weak var previewView: PreviewView?
        var onTapToFocus: (CGPoint) -> Void

        init(onTapToFocus: @escaping (CGPoint) -> Void) {
            self.onTapToFocus = onTapToFocus
        }

        @objc func didTap(_ recognizer: UITapGestureRecognizer) {
            guard let previewView else { return }
            let layerPoint = recognizer.location(in: previewView)
            let devicePoint = previewView.previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
            onTapToFocus(devicePoint)
        }
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

private extension AVCaptureConnection {
    func setOrientationIfSupported(_ orientation: AVCaptureVideoOrientation) {
        guard isVideoOrientationSupported else { return }
        videoOrientation = orientation
    }
}
