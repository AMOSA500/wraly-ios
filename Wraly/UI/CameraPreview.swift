import AVFoundation
import SwiftUI

/// Live camera preview. Uses aspect-fit inside a 3:4 container so the overlay's
/// normalised coordinates map 1:1 onto what the sensor (and Vision) sees.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        if let c = v.previewLayer.connection, c.isVideoRotationAngleSupported(90) {
            c.videoRotationAngle = 90
        }
        return v
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        if let c = uiView.previewLayer.connection, c.isVideoRotationAngleSupported(90), c.videoRotationAngle != 90 {
            c.videoRotationAngle = 90
        }
    }
}
