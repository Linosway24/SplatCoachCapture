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

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.connection?.setOrientationIfSupported(orientation)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
        uiView.previewLayer.connection?.setOrientationIfSupported(orientation)
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
